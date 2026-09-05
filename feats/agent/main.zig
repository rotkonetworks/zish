//! agent — the model loop (session feat). Drives a chat-completions model over
//! the v0.3 frame protocol: the model's tool calls become `run` frames executed
//! by zish, results feed back, final text becomes a `say`.
//!
//! Backend (both the loop and `--judge`): default is OpenRouter. Set
//!   ZISH_AGENT_BACKEND=ollama   [OLLAMA_HOST=host:port]   — local Ollama, no key
//!   ZISH_AGENT_ENDPOINT=<url>                             — any OpenAI-compatible API
//! Ollama uses its OpenAI-compatible /v1/chat/completions and needs no key; pass
//! the locally-pulled model name with -m (e.g. -m qwen3:1.7b, -m qwen3.8:27b-mtp-q4_K_M).
//! ZISH_AGENT_TIMEOUT=<seconds> (default 120) raises the per-request curl timeout —
//! a big local model on CPU can take minutes per generation (27B ≈ 6 min here).
//!
//! Grammar (one-shot, the old `agent exec -p` shape):
//!   agent [-m <model>] [--mock <file>] <query...>
//!
//! Transport is injected at ONE seam — `fetchCompletion(request) → {status,
//! body}`. Production execs `curl`; `--mock <file>` reads canned responses
//! from a JSONL file (one `{"status":N,"body":"<json>"}` per line, consumed in
//! order), so the whole loop — parsing, tool-call mapping, backoff on 429 — is
//! testable offline with no network. Everything above the seam is identical in
//! test and production.
//!
//! Key handling: the OpenRouter key is read from ~/.zish/openrouter.key (0600)
//! — never argv (visible in /proc), never the environment (leaks to every
//! run-frame child). The auth header goes in a curl --config file and the
//! request body in a --data @file, both 0600 under ~/.zish, so the secret is
//! never a process argument.
//!
//! Non-streaming (stream:false); one tool (`run_command`); lockstep with the
//! session protocol (one run in flight — tool calls execute sequentially).

const std = @import("std");
const linux = std.os.linux;

const DEFAULT_MODEL = "deepseek/deepseek-v4-flash-0731";
const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const MAX_TURNS = 24; // hard cap on model round-trips per query (runaway guard)
const MAX_RETRIES = 5; // per-request retry cap for 429/5xx
const RESULT_CAP = 8 * 1024 * 1024; // matches zish's session RESULT_CAP
const SYSTEM_PROMPT =
    "You are an agent in the user's live zish shell. You have one tool, " ++
    "run_command, which runs a shell command in the user's REAL session " ++
    "(cwd, variables, and functions persist between calls). Output is captured " ++
    "and returned to you, truncated at 8MiB; exit codes are real. Be terse. " ++
    "Use the tool to accomplish the request, then reply with a short final " ++
    "answer and no tool call.";

const alloc = std.heap.page_allocator; // mmap-backed, no libc needed

// ===========================================================================
// pure transforms (unit-tested; no IO)
// ===========================================================================

/// JSON-escape `s` into `out` per RFC 8259. The stub emitted frames with raw
/// `{s}`; model output contains quotes and newlines on turn one, so every
/// frame the agent emits must route through here.
fn jsonEscape(out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            const e = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch continue;
            try out.appendSlice(alloc, e);
        } else try out.append(alloc, c),
    };
}

const ToolCall = struct {
    id: []const u8, // owned
    command: []const u8, // owned; the run_command "command" argument
};

/// What one model response resolves to.
const Assistant = union(enum) {
    /// The model wants to run one or more commands (execute sequentially).
    tools: []ToolCall,
    /// The model gave a final answer.
    text: []const u8, // owned
    /// The response was malformed or an API error body.
    err: []const u8, // owned, human-readable
};

/// Parse an OpenRouter/OpenAI chat-completions response body into an Assistant.
/// Standard schema: choices[0].message.{content, tool_calls[].function.
/// {name, arguments}}, arguments itself a JSON string holding {"command":...}.
fn parseResponse(body: []const u8) Assistant {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return .{ .err = dupe("agent: model response was not valid JSON") };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .err = dupe("agent: model response was not a JSON object") },
    };

    // API-level error object: {"error":{"message":...}}
    if (root.get("error")) |e| {
        const msg = objStr(e, "message") orelse "unknown API error";
        return .{ .err = std.fmt.allocPrint(alloc, "agent: API error: {s}", .{msg}) catch dupe("agent: API error") };
    }

    const choices = switch (root.get("choices") orelse return .{ .err = dupe("agent: response had no choices") }) {
        .array => |a| a,
        else => return .{ .err = dupe("agent: choices was not an array") },
    };
    if (choices.items.len == 0) return .{ .err = dupe("agent: response had zero choices") };
    const msg = switch (choices.items[0]) {
        .object => |o| o.get("message"),
        else => null,
    } orelse return .{ .err = dupe("agent: choice had no message") };
    const msg_obj = switch (msg) {
        .object => |o| o,
        else => return .{ .err = dupe("agent: message was not an object") },
    };

    // tool_calls take priority: if present and non-empty, the model wants tools.
    if (msg_obj.get("tool_calls")) |tc| {
        if (tc == .array and tc.array.items.len > 0) {
            var list: std.ArrayListUnmanaged(ToolCall) = .empty;
            for (tc.array.items) |call| {
                const co = switch (call) {
                    .object => |o| o,
                    else => continue,
                };
                const id = objStr(call, "id") orelse "call_0";
                const func = co.get("function") orelse continue;
                const args_str = objStr(func, "arguments") orelse continue;
                // arguments is a JSON string; parse it for {"command":...}
                const command = parseCommandArg(args_str) orelse continue;
                list.append(alloc, .{ .id = dupe(id), .command = command }) catch continue;
            }
            if (list.items.len == 0)
                return .{ .err = dupe("agent: tool_calls present but none parseable") };
            return .{ .tools = list.toOwnedSlice(alloc) catch &.{} };
        }
    }

    // otherwise, final text content
    if (objStr(msg, "content")) |content|
        return .{ .text = dupe(content) };
    return .{ .err = dupe("agent: message had neither tool_calls nor content") };
}

/// The tool `arguments` field is a JSON *string*; parse it and pull `command`.
fn parseCommandArg(args_str: []const u8) ?[]const u8 {
    const p = std.json.parseFromSlice(std.json.Value, alloc, args_str, .{}) catch return null;
    defer p.deinit();
    const cmd = objStr(p.value, "command") orelse return null;
    return dupe(cmd);
}

fn objStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn dupe(s: []const u8) []u8 {
    return alloc.dupe(u8, s) catch @constCast(s[0..0]);
}

// ===========================================================================
// message history + request building (pure, testable)
// ===========================================================================

const Role = enum { system, user, assistant, tool };
const Message = struct {
    role: Role,
    content: []const u8, // owned
    // for role=tool: which call this answers, and the raw assistant tool_calls
    // JSON for role=assistant so the follow-up request is well-formed.
    tool_call_id: []const u8 = "", // owned
    tool_calls_json: []const u8 = "", // owned; verbatim assistant.tool_calls array
};

/// Build the chat-completions request body from the running history.
fn buildRequest(model: []const u8, history: []const Message) ![]u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    try b.appendSlice(alloc, "{\"model\":\"");
    try jsonEscape(&b, model);
    try b.appendSlice(alloc, "\",\"stream\":false,\"messages\":[");
    for (history, 0..) |m, i| {
        if (i > 0) try b.append(alloc, ',');
        try b.appendSlice(alloc, "{\"role\":\"");
        try b.appendSlice(alloc, @tagName(m.role));
        try b.appendSlice(alloc, "\",\"content\":\"");
        try jsonEscape(&b, m.content);
        try b.append(alloc, '"');
        if (m.role == .tool) {
            try b.appendSlice(alloc, ",\"tool_call_id\":\"");
            try jsonEscape(&b, m.tool_call_id);
            try b.append(alloc, '"');
        }
        if (m.role == .assistant and m.tool_calls_json.len > 0) {
            try b.appendSlice(alloc, ",\"tool_calls\":");
            try b.appendSlice(alloc, m.tool_calls_json);
        }
        try b.append(alloc, '}');
    }
    // one tool: run_command
    try b.appendSlice(alloc,
        "],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"run_command\"," ++
        "\"description\":\"Run a shell command in the user's live zish session and " ++
        "return its stdout and exit code.\",\"parameters\":{\"type\":\"object\"," ++
        "\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"the shell " ++
        "command to run\"}},\"required\":[\"command\"]}}}]}");
    return b.toOwnedSlice(alloc);
}

// ===========================================================================
// frame IO (with the session host over stdio)
// ===========================================================================

fn emit(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = linux.write(1, s.ptr + off, s.len - off);
        const sr: isize = @bitCast(rc);
        if (sr <= 0) return;
        off += @intCast(sr);
    }
}

fn emitFrame(comptime kind: []const u8, text: []const u8) void {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    b.appendSlice(alloc, "{\"t\":\"" ++ kind ++ "\",\"text\":\"") catch return;
    jsonEscape(&b, text) catch return;
    b.appendSlice(alloc, "\"}\n") catch return;
    emit(b.items);
}

fn say(text: []const u8) void {
    emitFrame("say", text);
}

fn readLine(buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(0, buf.ptr + n, 1);
        const sr: isize = @bitCast(rc);
        if (sr <= 0) break;
        const c = buf[n];
        n += 1;
        if (c == '\n') break;
    }
    return n;
}

const RunResult = struct { code: i64, out: []u8 };

/// Emit a `run` frame and block for zish's `result` reply. Returns the parsed
/// {code, out}. Both fields owned. An empty/errored reply ends the loop.
fn runCommand(command: []const u8) ?RunResult {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    b.appendSlice(alloc, "{\"t\":\"run\",\"cmd\":\"") catch return null;
    jsonEscape(&b, command) catch return null;
    b.appendSlice(alloc, "\"}\n") catch return null;
    emit(b.items);

    // result frames can be large (up to 8MiB out); grow a line buffer.
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    var one: [1]u8 = undefined;
    while (line.items.len < RESULT_CAP + 4096) {
        const rc = linux.read(0, &one, 1);
        const sr: isize = @bitCast(rc);
        if (sr <= 0) return null;
        if (one[0] == '\n') break;
        line.append(alloc, one[0]) catch return null;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line.items, .{}) catch return null;
    defer parsed.deinit();
    const o = switch (parsed.value) {
        .object => |ob| ob,
        else => return null,
    };
    // an `error` frame (denied/busy/failed) ends the run
    if (o.get("t")) |t| {
        if (t == .string and std.mem.eql(u8, t.string, "error")) return null;
    }
    const code: i64 = if (o.get("code")) |c| (switch (c) {
        .integer => |iv| iv,
        else => 0,
    }) else 0;
    const out = objStr(parsed.value, "out") orelse "";
    return .{ .code = code, .out = dupe(out) };
}

// ===========================================================================
// transport seam: mock (file) or real (curl)
// ===========================================================================

const HttpReply = struct { status: u32, body: []u8 };

const Mock = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn next(self: *Mock) ?HttpReply {
        while (self.lines.next()) |ln| {
            const line = std.mem.trim(u8, ln, " \t\r");
            if (line.len == 0) continue;
            const p = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return null;
            defer p.deinit();
            const status: u32 = if (objInt(p.value, "status")) |s| @intCast(s) else 200;
            const body = objStr(p.value, "body") orelse "";
            return .{ .status = status, .body = dupe(body) };
        }
        return null;
    }
};

fn objInt(v: std.json.Value, key: []const u8) ?i64 {
    const o = switch (v) {
        .object => |ob| ob,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .integer => |iv| iv,
        else => null,
    };
}

/// Read a whole file via raw syscalls (no libc, no Io interface).
fn readFileAlloc(path: []const u8) ?[]u8 {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return null;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const fd_rc = linux.open(@ptrCast(&pathz), .{ .ACCMODE = .RDONLY }, 0);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(@intCast(fd), &tmp, tmp.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch return null;
    }
    return buf.toOwnedSlice(alloc) catch null;
}

/// Write `bytes` to `path` with mode 0600 via raw syscalls. Returns success.
fn writeFile600(path: []const u8, bytes: []const u8) bool {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return false;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const fd_rc = linux.open(@ptrCast(&pathz), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return false;
    defer _ = linux.close(@intCast(fd));
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(@intCast(fd), bytes.ptr + off, bytes.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// The real transport: POST `request` to OpenRouter via curl. The API key
/// (auth header) lives in a 0600 --config file and the body in a --data @file,
/// so the secret is never a process argument. Returns null on spawn/read
/// failure (caller treats as retryable).
fn fetchCurl(home: []const u8, endpoint: []const u8, key: []const u8, request: []const u8) ?HttpReply {
    // pid-suffixed so concurrent agent sessions never clobber each other's
    // request files; all three are unlinked before returning.
    const pid = linux.getpid();
    var cfg_buf: [4096]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    const cfg_path = std.fmt.bufPrint(&cfg_buf, "{s}/.zish/.agent_cfg_{d}", .{ home, pid }) catch return null;
    const body_path = std.fmt.bufPrint(&body_buf, "{s}/.zish/.agent_body_{d}", .{ home, pid }) catch return null;
    const out_path = std.fmt.bufPrint(&out_buf, "{s}/.zish/.agent_out_{d}", .{ home, pid }) catch return null;
    defer {
        unlinkPath(cfg_path); // the auth-header copy must not linger on disk
        unlinkPath(body_path);
        unlinkPath(out_path);
    }

    // Auth header only when a key is present (Ollama/local endpoints take none).
    // The cfg file is written either way; an empty --config is valid.
    var cfg: std.ArrayListUnmanaged(u8) = .empty;
    defer cfg.deinit(alloc);
    const kt = std.mem.trim(u8, key, " \t\r\n");
    if (kt.len > 0) {
        cfg.appendSlice(alloc, "header = \"Authorization: Bearer ") catch return null;
        cfg.appendSlice(alloc, kt) catch return null;
        cfg.appendSlice(alloc, "\"\n") catch return null;
    }
    if (!writeFile600(cfg_path, cfg.items)) return null;
    if (!writeFile600(body_path, request)) return null;

    // curl argv: no secret here. -w writes the status code to stdout after the
    // body is written to the -o file, so we read status and body separately.
    var data_arg: [4096]u8 = undefined;
    const data = std.fmt.bufPrintZ(&data_arg, "@{s}", .{body_path}) catch return null;
    var cfg_argz: [4096]u8 = undefined;
    const cfgz = std.fmt.bufPrintZ(&cfg_argz, "{s}", .{cfg_path}) catch return null;
    var out_argz: [4096]u8 = undefined;
    const outz = std.fmt.bufPrintZ(&out_argz, "{s}", .{out_path}) catch return null;
    var ep_argz: [4096]u8 = undefined;
    const epz = std.fmt.bufPrintZ(&ep_argz, "{s}", .{endpoint}) catch return null;
    var to_argz: [8]u8 = undefined;
    const toz = std.fmt.bufPrintZ(&to_argz, "{s}", .{timeoutStr()}) catch return null;

    const argv = [_:null]?[*:0]const u8{
        "env", "curl", "-sS", "--max-time", toz.ptr,
        "--config", cfgz.ptr,
        "-H",       "Content-Type: application/json",
        "-X",       "POST",
        "--data",   data.ptr,
        "-o",       outz.ptr,
        "-w",       "%{http_code}",
        epz.ptr,
        null,
    };

    const status_str = execCapture(&argv) orelse return null;
    defer alloc.free(status_str);
    const status = std.fmt.parseInt(u32, std.mem.trim(u8, status_str, " \t\r\n"), 10) catch 0;
    const body = readFileAlloc(out_path) orelse dupe("");
    return .{ .status = status, .body = body };
}

fn unlinkPath(path: []const u8) void {
    var z: [4096]u8 = undefined;
    if (path.len >= z.len) return;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    _ = linux.unlink(@ptrCast(&z));
}

/// fork+exec `argv[0]` via /usr/bin/env, capturing its stdout. Raw syscalls.
fn execCapture(argv: [*:null]const ?[*:0]const u8) ?[]u8 {
    var fds: [2]i32 = undefined;
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return null;
    const pid_rc = linux.fork();
    const pid: isize = @bitCast(pid_rc);
    if (pid < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[1]);
        const envp = std.c.environ;
        _ = linux.execve("/usr/bin/env", argv, @ptrCast(envp));
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fds[0], &tmp, tmp.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch break;
    }
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    return buf.toOwnedSlice(alloc) catch null;
}

// ===========================================================================
// the loop
// ===========================================================================

const Config = struct {
    model: []const u8 = DEFAULT_MODEL,
    mock_path: ?[]const u8 = null,
    query: []const u8 = "",
};

pub fn main(init: std.process.Init.Minimal) void {
    // Judge mode is a plain one-shot invocation (gf/steward/benchmark exec the
    // binary directly): no session host, no hello frame, no session frames.
    // Branch BEFORE the handshake the model loop needs.
    if (hasJudgeFlag(init.args)) {
        linux.exit(runJudge(init.args));
    }
    // --ask: one-shot plain-text completion (no tools, no session frames). This
    // is the seam a plain caller like `team` drives — `agent --ask <prompt>` →
    // the model's text on stdout — without speaking the session frame protocol.
    if (hasAskFlag(init.args)) {
        linux.exit(runAsk(init.args));
    }

    // consume the hello frame (protocol v0.2+); we do not gate on caps here —
    // a run denial simply ends the loop via runCommand returning null.
    var hbuf: [4096]u8 = undefined;
    _ = readLine(&hbuf);

    const cfg = parseArgs(init.args) orelse {
        say("agent: usage: agent [-m model] [--mock file] <query>");
        emit("{\"t\":\"done\"}\n");
        return;
    };
    if (cfg.query.len == 0) {
        say("agent: no query given");
        emit("{\"t\":\"done\"}\n");
        return;
    }

    // transport setup
    var mock: ?Mock = null;
    var home_buf: [4096]u8 = undefined;
    var home: []const u8 = "";
    var key: []const u8 = "";
    if (cfg.mock_path) |mp| {
        const contents = readFileAlloc(mp) orelse {
            say("agent: could not read mock file");
            emit("{\"t\":\"done\"}\n");
            return;
        };
        mock = .{ .lines = std.mem.splitScalar(u8, contents, '\n') };
    } else {
        home = getHome(&home_buf) orelse {
            say("agent: HOME not set");
            emit("{\"t\":\"done\"}\n");
            return;
        };
        // OpenRouter needs the key file; Ollama/custom endpoints send it only if
        // present (Ollama takes no auth at all).
        if (agentNeedsKey() or getEnv("ZISH_AGENT_ENDPOINT") != null) {
            var kbuf: [4096]u8 = undefined;
            const kpath = std.fmt.bufPrint(&kbuf, "{s}/.zish/openrouter.key", .{home}) catch "";
            if (readFileAlloc(kpath)) |k| {
                key = k;
            } else if (agentNeedsKey()) {
                say("agent: no API key at ~/.zish/openrouter.key (create it, chmod 600)");
                emit("{\"t\":\"done\"}\n");
                return;
            }
        }
    }
    var ep_buf: [512]u8 = undefined;
    const endpoint = agentEndpoint(&ep_buf);

    // history seeds with the system prompt and the user's query
    var history: std.ArrayListUnmanaged(Message) = .empty;
    history.append(alloc, .{ .role = .system, .content = SYSTEM_PROMPT }) catch return;
    history.append(alloc, .{ .role = .user, .content = cfg.query }) catch return;

    var turn: usize = 0;
    while (turn < MAX_TURNS) : (turn += 1) {
        const request = buildRequest(cfg.model, history.items) catch {
            say("agent: failed to build request");
            break;
        };
        const reply = fetchWithBackoff(&mock, home, endpoint, key, request) orelse {
            say("agent: request failed after retries");
            break;
        };
        if (reply.status < 200 or reply.status >= 300) {
            var eb: [256]u8 = undefined;
            say(std.fmt.bufPrint(&eb, "agent: HTTP {d} from model API", .{reply.status}) catch "agent: HTTP error");
            break;
        }

        switch (parseResponse(reply.body)) {
            .err => |e| {
                say(e);
                break;
            },
            .text => |t| {
                if (t.len > 0) say(t);
                break;
            },
            .tools => |calls| {
                // record the assistant's tool_calls so the follow-up is valid,
                // then execute each sequentially (lockstep) and feed results back.
                appendAssistantToolCalls(&history, calls);
                var aborted = false;
                for (calls) |call| {
                    const res = runCommand(call.command) orelse {
                        aborted = true;
                        break;
                    };
                    appendToolResult(&history, call.id, res);
                }
                if (aborted) {
                    say("agent: a command could not run (denied or session ended)");
                    break;
                }
                // loop: send the tool results back to the model
            },
        }
    } else {
        say("agent: reached the turn limit");
    }

    emit("{\"t\":\"done\"}\n");
}

fn appendAssistantToolCalls(history: *std.ArrayListUnmanaged(Message), calls: []const ToolCall) void {
    // reconstruct the tool_calls JSON array the API expects on the assistant msg
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    arr.append(alloc, '[') catch return;
    for (calls, 0..) |c, i| {
        if (i > 0) arr.append(alloc, ',') catch return;
        arr.appendSlice(alloc, "{\"id\":\"") catch return;
        jsonEscape(&arr, c.id) catch return;
        arr.appendSlice(alloc, "\",\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"arguments\":\"") catch return;
        // arguments is a JSON string containing {"command":...}
        var inner: std.ArrayListUnmanaged(u8) = .empty;
        defer inner.deinit(alloc);
        inner.appendSlice(alloc, "{\"command\":\"") catch return;
        jsonEscape(&inner, c.command) catch return;
        inner.appendSlice(alloc, "\"}") catch return;
        jsonEscape(&arr, inner.items) catch return; // escape the inner JSON as a string
        arr.appendSlice(alloc, "\"}}") catch return;
    }
    arr.append(alloc, ']') catch return;
    history.append(alloc, .{
        .role = .assistant,
        .content = "",
        .tool_calls_json = arr.toOwnedSlice(alloc) catch "",
    }) catch {};
}

fn appendToolResult(history: *std.ArrayListUnmanaged(Message), id: []const u8, res: RunResult) void {
    var c: std.ArrayListUnmanaged(u8) = .empty;
    var hb: [32]u8 = undefined;
    c.appendSlice(alloc, std.fmt.bufPrint(&hb, "[exit {d}]\n", .{res.code}) catch "") catch {};
    c.appendSlice(alloc, res.out) catch {};
    history.append(alloc, .{
        .role = .tool,
        .content = c.toOwnedSlice(alloc) catch "",
        .tool_call_id = dupe(id),
    }) catch {};
}

/// One request with bounded exponential backoff on 429/5xx. Deterministic
/// jitter (no clock in a feat): jitter derived from the attempt number.
fn fetchWithBackoff(mock: *?Mock, home: []const u8, endpoint: []const u8, key: []const u8, request: []const u8) ?HttpReply {
    var attempt: usize = 0;
    while (attempt < MAX_RETRIES) : (attempt += 1) {
        const reply = if (mock.*) |*m| m.next() else fetchCurl(home, endpoint, key, request);
        const r = reply orelse return null;
        if (r.status != 429 and r.status < 500) return r;
        // retryable: back off. base 200ms * 2^attempt + attempt*37ms jitter.
        // TODO: honor the Retry-After header (needs curl to surface response
        // headers — -D to a file; add when the live path is exercised).
        const base_ms: u64 = @as(u64, 200) << @intCast(@min(attempt, 5));
        sleepMs(base_ms + @as(u64, attempt) * 37);
    }
    // last try, whatever it is
    return if (mock.*) |*m| m.next() else fetchCurl(home, endpoint, key, request);
}

fn sleepMs(ms: u64) void {
    var ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, &ts);
}

fn getHome(buf: []u8) ?[]const u8 {
    const envp = std.c.environ;
    var i: usize = 0;
    while (envp[i]) |line| : (i += 1) {
        const s = std.mem.sliceTo(line, 0);
        if (std.mem.startsWith(u8, s, "HOME=")) {
            const v = s[5..];
            if (v.len >= buf.len) return null;
            @memcpy(buf[0..v.len], v);
            return buf[0..v.len];
        }
    }
    return null;
}

/// Look up an environment variable, returning a slice into `environ` (stable for
/// the process lifetime), or null if unset.
fn getEnv(name: []const u8) ?[]const u8 {
    const envp = std.c.environ;
    var i: usize = 0;
    while (envp[i]) |line| : (i += 1) {
        const s = std.mem.sliceTo(line, 0);
        if (s.len > name.len and s[name.len] == '=' and std.mem.startsWith(u8, s, name))
            return s[name.len + 1 ..];
    }
    return null;
}

/// Backend selection. Default is OpenRouter (key from ~/.zish/openrouter.key).
/// `ZISH_AGENT_BACKEND=ollama` targets a local Ollama over its OpenAI-compatible
/// API (no key), honoring `OLLAMA_HOST` (host:port or full base URL). A raw
/// `ZISH_AGENT_ENDPOINT` overrides the URL outright.
fn backendIsOllama() bool {
    const b = getEnv("ZISH_AGENT_BACKEND") orelse return false;
    return std.mem.eql(u8, b, "ollama");
}

fn agentEndpoint(buf: []u8) []const u8 {
    if (getEnv("ZISH_AGENT_ENDPOINT")) |e| return e;
    if (backendIsOllama()) {
        const host = getEnv("OLLAMA_HOST") orelse "127.0.0.1:11434";
        if (std.mem.startsWith(u8, host, "http"))
            return std.fmt.bufPrint(buf, "{s}/v1/chat/completions", .{host}) catch ENDPOINT;
        return std.fmt.bufPrint(buf, "http://{s}/v1/chat/completions", .{host}) catch ENDPOINT;
    }
    return ENDPOINT;
}

/// Only default OpenRouter requires a key file; Ollama needs none.
fn agentNeedsKey() bool {
    if (getEnv("ZISH_AGENT_ENDPOINT")) |_| return false;
    return !backendIsOllama();
}

/// Per-request curl timeout in seconds. Default 120; `ZISH_AGENT_TIMEOUT` raises
/// it for slow local models (a big Ollama model can take minutes to load+generate).
/// Validated to digits so it stays a clean curl argument.
fn timeoutStr() []const u8 {
    const v = getEnv("ZISH_AGENT_TIMEOUT") orelse return "120";
    if (v.len == 0 or v.len > 6) return "120";
    for (v) |c| if (c < '0' or c > '9') return "120";
    return v;
}

fn parseArgs(args: std.process.Args) ?Config {
    var cfg = Config{};
    cfg.model = getEnv("ZISH_AGENT_MODEL") orelse DEFAULT_MODEL; // -m overrides
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip(); // argv[0]
    var query: std.ArrayListUnmanaged(u8) = .empty;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-m")) {
            const v = it.next() orelse return null;
            cfg.model = dupe(v);
        } else if (std.mem.eql(u8, a, "--mock")) {
            const v = it.next() orelse return null;
            cfg.mock_path = dupe(v);
        } else {
            if (query.items.len > 0) query.append(alloc, ' ') catch return null;
            query.appendSlice(alloc, a) catch return null;
        }
    }
    cfg.query = query.toOwnedSlice(alloc) catch "";
    return cfg;
}

// ===========================================================================
// judge mode — `agent --judge <rubric> <subject...>`
//
// The generalized "analyze-then-score-against-rubric" primitive (SmellBench's
// stabilizing insight): a plain ONE-SHOT completion, no tool loop, no session
// frames, no hello handshake. Reads a rubric file + subject files, asks the
// model to analyze then score, validates the JSON verdict, prints it to
// stdout. gf (and later the steward, the reviewer benchmark, dispute
// adjudication) exec this directly and read the verdict off stdout. The
// verdict schema is package-manager-agnostic — it knows nothing about feats.
// ===========================================================================

const JUDGE_RETRIES = 3;

// Subject-agnostic: the RUBRIC carries the domain (a feat, a PKGBUILD, a diff);
// this prompt only defines the analyze-then-score-against-the-rubric contract.
const JUDGE_SYSTEM =
    "You are a meticulous reviewer. You are given a scoring rubric and a subject " ++
    "to review — source code, a package build script, or a diff. First analyze " ++
    "the subject against each rubric dimension, noting concrete issues (bugs, " ++
    "unsafe operations, whether it does what it claims). Then assign each " ++
    "dimension an integer score from 0 to 10 following the rubric bands, and a " ++
    "single overall verdict. Respond with ONLY a JSON object — no prose, no " ++
    "markdown fences — of exactly this shape: {\"analysis\":\"<concise analysis>\"," ++
    "\"scores\":{\"<dimension_key>\":<0-10>,...},\"verdict\":\"pass\" or \"fail\"}. " ++
    "Use \"fail\" if any dimension scores below 5, or if the subject is unsafe " ++
    "or does not do what it claims.";

const JudgeCfg = struct {
    model: []const u8 = DEFAULT_MODEL,
    mock_path: ?[]const u8 = null,
    rubric: []const u8 = "",
    subjects: [][]const u8 = &.{},
};

fn warn(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = linux.write(2, s.ptr + off, s.len - off);
        const sr: isize = @bitCast(rc);
        if (sr <= 0) return;
        off += @intCast(sr);
    }
}

fn hasJudgeFlag(args: std.process.Args) bool {
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--judge")) return true;
    }
    return false;
}

fn parseJudgeArgs(args: std.process.Args) ?JudgeCfg {
    var cfg = JudgeCfg{};
    // model default from env (so a caller like `aur`, which doesn't take -m,
    // still selects the model); an explicit -m overrides.
    cfg.model = getEnv("ZISH_AGENT_MODEL") orelse DEFAULT_MODEL;
    var subs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--judge")) {
            continue;
        } else if (std.mem.eql(u8, a, "-m")) {
            cfg.model = dupe(it.next() orelse return null);
        } else if (std.mem.eql(u8, a, "--mock")) {
            cfg.mock_path = dupe(it.next() orelse return null);
        } else if (cfg.rubric.len == 0) {
            cfg.rubric = dupe(a);
        } else {
            subs.append(alloc, dupe(a)) catch return null;
        }
    }
    cfg.subjects = subs.toOwnedSlice(alloc) catch return null;
    if (cfg.rubric.len == 0 or cfg.subjects.len == 0) return null;
    return cfg;
}

/// Build a plain chat-completions request (no tools) from an explicit system
/// and user message.
fn buildJudgeRequest(model: []const u8, system: []const u8, user: []const u8) ![]u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    try b.appendSlice(alloc, "{\"model\":\"");
    try jsonEscape(&b, model);
    try b.appendSlice(alloc, "\",\"stream\":false,\"messages\":[{\"role\":\"system\",\"content\":\"");
    try jsonEscape(&b, system);
    try b.appendSlice(alloc, "\"},{\"role\":\"user\",\"content\":\"");
    try jsonEscape(&b, user);
    try b.appendSlice(alloc, "\"}]}");
    return b.toOwnedSlice(alloc);
}

/// Extract the first balanced {...} object from model output (tolerant of
/// prose or ```json fences the model may wrap around it). String-aware so a
/// brace inside a JSON string never miscounts.
fn extractJsonObject(s: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
        } else {
            if (c == '"') {
                in_str = true;
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
                if (depth == 0) return s[start .. i + 1];
            }
        }
    }
    return null;
}

/// A verdict is valid iff it parses and carries a pass|fail verdict plus a
/// scores object. analysis is optional but expected.
fn verdictValid(json_text: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return false;
    defer parsed.deinit();
    const o = switch (parsed.value) {
        .object => |ob| ob,
        else => return false,
    };
    const v = o.get("verdict") orelse return false;
    if (v != .string) return false;
    if (!std.mem.eql(u8, v.string, "pass") and !std.mem.eql(u8, v.string, "fail")) return false;
    const sc = o.get("scores") orelse return false;
    return sc == .object;
}

/// Run one judge invocation end to end. Returns process exit code: 0 with the
/// verdict JSON on stdout, non-zero with a diagnostic on stderr.
const ASK_SYSTEM =
    \\You are one member of a small agent team working a shared task. Answer the
    \\instruction directly and concisely in plain text — no preamble, no restating
    \\the question, no markdown headers. If asked to decompose a task, output one
    \\short sub-task per line and nothing else.
;

fn hasAskFlag(args: std.process.Args) bool {
    var it = std.process.Args.Iterator.init(args);
    while (it.next()) |a| if (std.mem.eql(u8, a, "--ask")) return true;
    return false;
}

/// One-shot plain-text completion: `agent [-m model] [--mock f] --ask <prompt...>`
/// → the model's text on stdout. No tools, no frames — the adapter `team` calls.
// Inline reasoning tags models use. ONE list, not a function per tag.
const REASON_TAGS = [_][]const u8{ "think", "thinking", "reason", "reasoning" };

/// Split an inline reasoning block (<think>…</think>, <thinking>…</thinking>, …)
/// out of `content`. Returns { think, answer }; if none present, think="" and
/// answer=content. Handles every tag in REASON_TAGS — add a tag, not a function.
fn splitReasoning(content: []const u8) struct { think: []const u8, answer: []const u8 } {
    for (REASON_TAGS) |tag| {
        var ob: [32]u8 = undefined;
        var cb: [32]u8 = undefined;
        const open = std.fmt.bufPrint(&ob, "<{s}>", .{tag}) catch continue;
        const close = std.fmt.bufPrint(&cb, "</{s}>", .{tag}) catch continue;
        if (std.mem.indexOf(u8, content, open)) |a| {
            const start = a + open.len;
            if (std.mem.indexOf(u8, content[start..], close)) |b| return .{
                .think = std.mem.trim(u8, content[start .. start + b], " \t\r\n"),
                .answer = std.mem.trim(u8, content[start + b + close.len ..], " \t\r\n"),
            };
        }
    }
    return .{ .think = "", .answer = content };
}

/// When ZISH_ASK_META is set, write `{"pt","ct","think"}` — token usage (from the
/// response's `usage`) and the reasoning (a `reasoning` field, else the `<think>`
/// block) — so a caller like `team` can surface real tokens/cost + thinking.
fn writeAskMeta(body: []const u8, inline_think: []const u8) void {
    const mp = getEnv("ZISH_ASK_META") orelse return;
    var pt: i64 = 0;
    var ct: i64 = 0;
    var reasoning: []const u8 = "";
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch null;
    defer if (parsed) |p| p.deinit();
    if (parsed) |p| if (p.value == .object) {
        if (p.value.object.get("usage")) |u| {
            pt = objInt(u, "prompt_tokens") orelse 0;
            ct = objInt(u, "completion_tokens") orelse 0;
        }
        if (p.value.object.get("choices")) |ch| if (ch == .array and ch.array.items.len > 0) {
            if (ch.array.items[0] == .object) if (ch.array.items[0].object.get("message")) |m|
                if (objStr(m, "reasoning")) |r| {
                    reasoning = r;
                };
        };
    };
    // API `reasoning` field wins; else the inline block already split out upstream
    const think = if (reasoning.len > 0) reasoning else inline_think;
    var m: std.ArrayListUnmanaged(u8) = .empty;
    defer m.deinit(alloc);
    var nb: [64]u8 = undefined;
    m.appendSlice(alloc, std.fmt.bufPrint(&nb, "{{\"pt\":{d},\"ct\":{d},\"think\":\"", .{ pt, ct }) catch return) catch return;
    jsonEscape(&m, std.mem.trim(u8, think, " \t\r\n")) catch return;
    m.appendSlice(alloc, "\"}") catch return;
    _ = writeFile600(mp, m.items);
}

fn runAsk(args: std.process.Args) u8 {
    var model: []const u8 = getEnv("ZISH_AGENT_MODEL") orelse DEFAULT_MODEL;
    var mock_path: ?[]const u8 = null;
    var prompt: std.ArrayListUnmanaged(u8) = .empty;
    defer prompt.deinit(alloc);
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--ask")) continue;
        if (std.mem.eql(u8, a, "-m")) {
            model = dupe(it.next() orelse return 2);
            continue;
        }
        if (std.mem.eql(u8, a, "--mock")) {
            mock_path = dupe(it.next() orelse return 2);
            continue;
        }
        if (prompt.items.len > 0) prompt.append(alloc, ' ') catch return 2;
        prompt.appendSlice(alloc, a) catch return 2;
    }
    if (prompt.items.len == 0) {
        warn("agent: --ask needs a prompt\n");
        return 2;
    }

    // transport: same seam as the judge (mock file or curl + key + backend)
    var mock: ?Mock = null;
    var home_buf: [4096]u8 = undefined;
    var home: []const u8 = "";
    var key: []const u8 = "";
    if (mock_path) |mp| {
        const contents = readFileAlloc(mp) orelse {
            warn("agent: could not read mock file\n");
            return 2;
        };
        mock = .{ .lines = std.mem.splitScalar(u8, contents, '\n') };
    } else {
        home = getHome(&home_buf) orelse {
            warn("agent: HOME not set\n");
            return 2;
        };
        if (agentNeedsKey() or getEnv("ZISH_AGENT_ENDPOINT") != null) {
            var kbuf: [4096]u8 = undefined;
            const kpath = std.fmt.bufPrint(&kbuf, "{s}/.zish/openrouter.key", .{home}) catch "";
            if (readFileAlloc(kpath)) |k| {
                key = k;
            } else if (agentNeedsKey()) {
                warn("agent: no API key at ~/.zish/openrouter.key\n");
                return 2;
            }
        }
    }
    var ep_buf: [512]u8 = undefined;
    const endpoint = agentEndpoint(&ep_buf);

    var attempt: usize = 0;
    while (attempt < JUDGE_RETRIES) : (attempt += 1) {
        const request = buildJudgeRequest(model, ASK_SYSTEM, prompt.items) catch return 2;
        const reply = fetchWithBackoff(&mock, home, endpoint, key, request) orelse continue;
        if (reply.status < 200 or reply.status >= 300) continue;
        switch (parseResponse(reply.body)) {
            .text => |t| {
                const trimmed = std.mem.trim(u8, t, " \t\r\n");
                const sr = splitReasoning(trimmed); // one splitter, all tags
                writeAskMeta(reply.body, sr.think); // tokens + thinking → sidecar
                emit(sr.answer); // the answer, reasoning removed
                emit("\n");
                return 0;
            },
            else => continue, // .tools shouldn't happen (no tools sent); retry
        }
    }
    warn("agent: --ask produced no response after retries\n");
    return 1;
}

fn runJudge(args: std.process.Args) u8 {
    const cfg = parseJudgeArgs(args) orelse {
        warn("agent: usage: agent --judge [-m model] [--mock file] <rubric> <subject...>\n");
        return 2;
    };

    // rubric + subjects → one user message
    const rubric = readFileAlloc(cfg.rubric) orelse {
        warn("agent: cannot read rubric file\n");
        return 2;
    };
    var user: std.ArrayListUnmanaged(u8) = .empty;
    user.appendSlice(alloc, "## Scoring rubric\n") catch return 2;
    user.appendSlice(alloc, rubric) catch return 2;
    user.appendSlice(alloc, "\n\n## Feat under review\n") catch return 2;
    for (cfg.subjects) |sp| {
        const body = readFileAlloc(sp) orelse {
            warn("agent: cannot read subject file\n");
            return 2;
        };
        user.appendSlice(alloc, "\n### FILE: ") catch return 2;
        user.appendSlice(alloc, sp) catch return 2;
        user.appendSlice(alloc, "\n") catch return 2;
        user.appendSlice(alloc, body) catch return 2;
        user.appendSlice(alloc, "\n") catch return 2;
    }

    // transport: same seam as the model loop (mock file or curl + key)
    var mock: ?Mock = null;
    var home_buf: [4096]u8 = undefined;
    var home: []const u8 = "";
    var key: []const u8 = "";
    if (cfg.mock_path) |mp| {
        const contents = readFileAlloc(mp) orelse {
            warn("agent: could not read mock file\n");
            return 2;
        };
        mock = .{ .lines = std.mem.splitScalar(u8, contents, '\n') };
    } else {
        home = getHome(&home_buf) orelse {
            warn("agent: HOME not set\n");
            return 2;
        };
        if (agentNeedsKey() or getEnv("ZISH_AGENT_ENDPOINT") != null) {
            var kbuf: [4096]u8 = undefined;
            const kpath = std.fmt.bufPrint(&kbuf, "{s}/.zish/openrouter.key", .{home}) catch "";
            if (readFileAlloc(kpath)) |k| {
                key = k;
            } else if (agentNeedsKey()) {
                warn("agent: no API key at ~/.zish/openrouter.key\n");
                return 2;
            }
        }
    }
    var ep_buf: [512]u8 = undefined;
    const endpoint = agentEndpoint(&ep_buf);

    var attempt: usize = 0;
    while (attempt < JUDGE_RETRIES) : (attempt += 1) {
        const request = buildJudgeRequest(cfg.model, JUDGE_SYSTEM, user.items) catch return 2;
        const reply = fetchWithBackoff(&mock, home, endpoint, key, request) orelse continue;
        if (reply.status < 200 or reply.status >= 300) continue;
        switch (parseResponse(reply.body)) {
            .text => |t| {
                const obj = extractJsonObject(t) orelse continue;
                if (!verdictValid(obj)) continue;
                emit(obj); // plain JSON verdict to stdout — NOT a session frame
                emit("\n");
                return 0;
            },
            else => continue, // .err / .tools: malformed for a judge call, retry
        }
    }
    warn("agent: judge produced no valid verdict after retries\n");
    return 1;
}

// ===========================================================================
// unit tests (run via `zig test feats/agent/main.zig`)
// ===========================================================================

test "jsonEscape handles quotes, newlines, controls" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try jsonEscape(&out, "he said \"hi\"\nline\ttab\x01");
    try std.testing.expectEqualStrings("he said \\\"hi\\\"\\nline\\ttab\\u0001", out.items);
}

test "parseResponse extracts final text" {
    const body =
        \\{"choices":[{"message":{"content":"all done"}}]}
    ;
    const a = parseResponse(body);
    try std.testing.expect(a == .text);
    try std.testing.expectEqualStrings("all done", a.text);
}

test "parseResponse extracts a tool call and its command" {
    const body =
        \\{"choices":[{"message":{"tool_calls":[{"id":"call_9","type":"function","function":{"name":"run_command","arguments":"{\"command\":\"ls -la\"}"}}]}}]}
    ;
    const a = parseResponse(body);
    try std.testing.expect(a == .tools);
    try std.testing.expectEqual(@as(usize, 1), a.tools.len);
    try std.testing.expectEqualStrings("call_9", a.tools[0].id);
    try std.testing.expectEqualStrings("ls -la", a.tools[0].command);
}

test "parseResponse surfaces an API error body" {
    const body =
        \\{"error":{"message":"rate limited"}}
    ;
    const a = parseResponse(body);
    try std.testing.expect(a == .err);
    try std.testing.expect(std.mem.indexOf(u8, a.err, "rate limited") != null);
}

test "extractJsonObject pulls a balanced object out of fenced prose" {
    const s = "Sure, here is the verdict:\n```json\n{\"verdict\":\"pass\",\"scores\":{\"a\":8}}\n```\ndone";
    const o = extractJsonObject(s).?;
    try std.testing.expectEqualStrings("{\"verdict\":\"pass\",\"scores\":{\"a\":8}}", o);
}

test "extractJsonObject ignores braces inside strings" {
    const s = "{\"analysis\":\"has a } brace and { in text\",\"verdict\":\"fail\",\"scores\":{}}";
    const o = extractJsonObject(s).?;
    try std.testing.expectEqualStrings(s, o);
}

test "verdictValid requires pass|fail plus a scores object" {
    try std.testing.expect(verdictValid("{\"verdict\":\"pass\",\"scores\":{\"cq\":9}}"));
    try std.testing.expect(verdictValid("{\"analysis\":\"x\",\"verdict\":\"fail\",\"scores\":{}}"));
    try std.testing.expect(!verdictValid("{\"verdict\":\"maybe\",\"scores\":{}}"));
    try std.testing.expect(!verdictValid("{\"verdict\":\"pass\"}")); // no scores
    try std.testing.expect(!verdictValid("not json"));
}

test "buildJudgeRequest has no tools and escapes content" {
    const req = try buildJudgeRequest("m", "sys \"q\"", "review this");
    defer alloc.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "run_command") == null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "sys \\\"q\\\"") != null);
}

test "buildRequest includes model, system, tool schema" {
    const hist = [_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi \"there\"" },
    };
    const req = try buildRequest("deepseek/deepseek-v4-flash-0731", &hist);
    defer alloc.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "deepseek/deepseek-v4-flash-0731") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "run_command") != null);
    // user content was JSON-escaped
    try std.testing.expect(std.mem.indexOf(u8, req, "hi \\\"there\\\"") != null);
}
