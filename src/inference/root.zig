// Inference engine for GGUF models
// Provides a simple API for loading a model and generating tokens.
// Designed for the router/secretary pattern: classify queries with a small local model.
//
// Architecture: Fork-based process isolation (inspired by llamafile).
// On first inference request, the shell forks a child process that:
//   1. Loads the GGUF model (mmap + parse weights)
//   2. Enters a request/response loop reading prompts from a pipe
//   3. Runs forward passes and writes back generated text
//   4. Exits when the parent closes the pipe (OS frees all memory)
//
// Benefits over in-process inference:
//   - Shell stays responsive if inference crashes or OOMs
//   - Model memory (often hundreds of MB) freed by OS on child exit
//   - No complex teardown — just close pipes or send SIGTERM
//   - GPU resources (future) isolated in child address space

const std = @import("std");
const posix = std.posix;

pub const gguf = @import("gguf.zig");
pub const gpu_mod = @import("gpu.zig");
pub const math = @import("math.zig");
pub const model = @import("model.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const ctm = @import("ctm.zig");
pub const autonomic = @import("autonomic.zig");
pub const mel = @import("mel.zig");
pub const pipe = @import("pipe.zig");
pub const encoder = @import("encoder.zig");
pub const whisper = @import("whisper.zig");

const Allocator = std.mem.Allocator;
const Token = tokenizer.Token;

// ============================================================
// Wire protocol (parent <-> child over pipes)
// ============================================================
// Request:  [u32 prompt_len] [u8 * prompt_len] [u16 max_tokens] [f32 temperature]
// Response: [u32 response_len] [u8 * response_len]
//           response_len == 0xFFFFFFFF means error
// Shutdown: parent closes request pipe -> child sees EOF -> exits

const PROTO_ERROR: u32 = 0xFFFFFFFF;

/// Fork-based inference server.
/// Parent side handle — communicates with the forked child process.
pub const ForkServer = struct {
    child_pid: posix.pid_t,
    /// Pipe to send requests to child (parent writes, child reads)
    req_write: posix.fd_t,
    /// Pipe to read responses from child (child writes, parent reads)
    resp_read: posix.fd_t,
    alive: bool = true,

    /// Spawn a forked inference server for the given model.
    /// The child process loads the model and enters a request loop.
    /// Returns the parent-side handle for sending queries.
    pub fn spawn(model_path: []const u8) !ForkServer {
        // Create two pipes: request (parent->child) and response (child->parent)
        const req_pipe = try posix.pipe();
        const resp_pipe = try posix.pipe();

        const pid = try posix.fork();

        if (pid == 0) {
            // === CHILD PROCESS ===
            // Close parent ends
            posix.close(req_pipe[1]); // parent's write end
            posix.close(resp_pipe[0]); // parent's read end

            // Redirect stdout/stderr to /dev/null so inference noise
            // doesn't corrupt the terminal
            const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch posix.exit(1);
            posix.dup2(devnull, 1) catch {}; // stdout
            posix.dup2(devnull, 2) catch {}; // stderr
            posix.close(devnull);

            // Run the inference loop (never returns on success)
            childMain(req_pipe[0], resp_pipe[1], model_path);

            // If childMain returns, it means an error occurred during setup
            posix.exit(1);
        }

        // === PARENT PROCESS ===
        // Close child ends
        posix.close(req_pipe[0]); // child's read end
        posix.close(resp_pipe[1]); // child's write end

        return .{
            .child_pid = pid,
            .req_write = req_pipe[1],
            .resp_read = resp_pipe[0],
        };
    }

    /// Send a generation request and read the response.
    /// Returns generated text (caller owns via allocator).
    pub fn generate(
        self: *ForkServer,
        prompt: []const u8,
        max_tokens: u16,
        temperature: f32,
        alloc: Allocator,
    ) ![]u8 {
        if (!self.alive) return error.ServerDead;

        // Write request: [u32 len] [prompt bytes] [u16 max_tokens] [f32 temperature]
        const prompt_len: u32 = @intCast(prompt.len);
        writeAll(self.req_write, std.mem.asBytes(&prompt_len)) catch |e| {
            self.alive = false;
            return e;
        };
        writeAll(self.req_write, prompt) catch |e| {
            self.alive = false;
            return e;
        };
        writeAll(self.req_write, std.mem.asBytes(&max_tokens)) catch |e| {
            self.alive = false;
            return e;
        };
        writeAll(self.req_write, std.mem.asBytes(&temperature)) catch |e| {
            self.alive = false;
            return e;
        };

        // Read response: [u32 len] [response bytes]
        var resp_len_buf: [4]u8 = undefined;
        readExact(self.resp_read, &resp_len_buf) catch |e| {
            self.alive = false;
            return e;
        };
        const resp_len: u32 = @bitCast(resp_len_buf);

        if (resp_len == PROTO_ERROR) return error.InferenceError;
        if (resp_len == 0) return alloc.dupe(u8, "") catch return error.OutOfMemory;
        if (resp_len > 1024 * 1024) {
            self.alive = false;
            return error.ProtocolError;
        }

        const buf = try alloc.alloc(u8, resp_len);
        errdefer alloc.free(buf);

        readExact(self.resp_read, buf) catch |e| {
            self.alive = false;
            return e;
        };

        return buf;
    }

    /// Check if the child process is still alive.
    pub fn isAlive(self: *ForkServer) bool {
        if (!self.alive) return false;
        // Non-blocking waitpid to check if child exited
        const result = posix.waitpid(self.child_pid, std.os.linux.W.NOHANG);
        if (result.pid != 0) {
            // Child exited
            self.alive = false;
            return false;
        }
        return true;
    }

    /// Shut down the inference server.
    /// Closes pipes (child sees EOF and exits), then reaps the child.
    pub fn shutdown(self: *ForkServer) void {
        if (!self.alive) return;
        self.alive = false;

        // Close our pipe ends — child will get EOF/SIGPIPE and exit
        posix.close(self.req_write);
        posix.close(self.resp_read);

        // Reap child (non-blocking first, then SIGTERM if needed)
        const result = posix.waitpid(self.child_pid, std.os.linux.W.NOHANG);
        if (result.pid == 0) {
            // Still running, send SIGTERM
            posix.kill(self.child_pid, std.os.linux.SIG.TERM) catch {};
            // Wait with timeout — use blocking waitpid
            _ = posix.waitpid(self.child_pid, 0);
        }
    }
};

// ============================================================
// Child process — inference loop
// ============================================================

/// Child process entry point. Loads model, serves requests. Never returns.
///
/// Breathing architecture:
///   INHALE (awake — processing input):
///     - Forward pass on queries, track per-token dopamine (surprise signal)
///     - Build sync traces in CTMState
///     - Store high-surprise experiences in replay buffer
///
///   EXHALE (idle — consolidating):
///     - Self-feeding forward passes (thinking / dreaming)
///     - compactMemory: Hebbian weight updates from sync patterns
///     - Prune replay buffer, decay old memories
///     - Periodically persist weights + sync state to disk
///
/// KV cache wraps at max_seq_length (position modular). CTM state never resets.
/// Sync accumulators carry across all tokens — the model's continuous memory.
fn childMain(req_fd: posix.fd_t, resp_fd: posix.fd_t, model_path: []const u8) void {
    // Use page allocator in child (simple, no fragmentation concerns since we exit)
    const alloc = std.heap.page_allocator;

    // Debug log for diagnosing model load failures
    const dbg = std.fs.createFileAbsolute("/tmp/zish_inference.log", .{ .truncate = true }) catch null;
    defer if (dbg) |f| f.close();

    const logMsg = struct {
        fn write(f: ?std.fs.File, msg: []const u8) void {
            if (f) |file| file.writeAll(msg) catch {};
        }
    }.write;

    logMsg(dbg, "Loading model: ");
    logMsg(dbg, model_path);
    logMsg(dbg, "\n");

    // Load model
    var file = gguf.GGUFFile.open(model_path, alloc) catch |err| {
        logMsg(dbg, "FAIL: gguf open: ");
        logMsg(dbg, @errorName(err));
        logMsg(dbg, "\n");
        sendError(resp_fd);
        return;
    };
    logMsg(dbg, "GGUF OK\n");

    var transformer = model.Transformer.initFromGGUF(&file, alloc) catch {
        logMsg(dbg, "FAIL: transformer init\n");
        sendError(resp_fd);
        return;
    };
    logMsg(dbg, "Transformer OK\n");

    var state = model.State.init(alloc, transformer.config) catch {
        logMsg(dbg, "FAIL: state init\n");
        sendError(resp_fd);
        return;
    };
    logMsg(dbg, "State OK\n");

    var tok = tokenizer.Tokenizer.initFromGGUF(&file, alloc) catch {
        logMsg(dbg, "FAIL: tokenizer init\n");
        sendError(resp_fd);
        return;
    };
    logMsg(dbg, "Tokenizer OK\n");
    logMsg(dbg, "CTM init...\n");

    var ctm_layer_idx: usize = 0;

    // Initialize CTM state if model has CTM blocks
    for (0..transformer.config.n_layers) |i| {
        if (transformer.layers[i].ctm_block) |blk| {
            const ctm_state_ptr = alloc.create(ctm.CTMState) catch {
                sendError(resp_fd);
                return;
            };
            ctm_state_ptr.* = ctm.CTMState.init(alloc, transformer.config.n_layers, blk.config.n_synch) catch {
                sendError(resp_fd);
                return;
            };
            ctm_state_ptr.last_state = alloc.alloc(f32, blk.config.dim) catch null;
            state.ctm_state = ctm_state_ptr;
            state.ctm_scratch = alloc.alloc(f32, ctm.CTMBlock.scratchSize(blk.config)) catch {
                sendError(resp_fd);
                return;
            };
            ctm_layer_idx = i;

            // Make weights plastic (mutable copies for learning)
            @constCast(blk).makePlastic(alloc) catch {};
            break;
        }
    }

    // ── Initialize autonomic controller ──
    // "Your Server as a Function": the breathing loop IS the server.
    // inhale = perceive >> dopamine >> replay
    // exhale = consolidate >> dream >> persist
    // controller = route(has_input?, inhale, exhale)
    var controller = autonomic.Controller.init(
        &transformer,
        &state,
        &tok,
        model_path,
        ctm_layer_idx,
    );
    controller.restore(); // load persisted state from previous sessions

    logMsg(dbg, "Controller OK\n");

    // ── Initialize GPU compute (graceful fallback to CPU) ──
    logMsg(dbg, "GPU init...\n");
    {
        const td_base = file.tensorData();
        const td_size = file.file_size - file.tensor_data_offset;
        if (gpu_mod.GpuContext.init(alloc, false)) |g| {
            const gp = alloc.create(gpu_mod.GpuContext) catch null;
            if (gp) |p| {
                p.* = g;
                if (p.vram_bytes >= td_size) {
                    if (p.uploadWeights(td_base[0..td_size])) {
                        transformer.setGpu(p, td_base);
                        logMsg(dbg, "GPU OK\n");
                    } else {
                        logMsg(dbg, "GPU upload failed\n");
                        p.deinit();
                        alloc.destroy(p);
                    }
                } else {
                    logMsg(dbg, "GPU VRAM too small\n");
                    p.deinit();
                    alloc.destroy(p);
                }
            } else {
                var g2 = g;
                g2.deinit();
            }
        } else {
            logMsg(dbg, "GPU init failed (no Vulkan?)\n");
        }
    }

    // Set request pipe to non-blocking for continuous inference polling
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = 2048;
    const cur_flags = posix.fcntl(req_fd, F_GETFL, 0) catch 0;
    _ = posix.fcntl(req_fd, F_SETFL, cur_flags | O_NONBLOCK) catch {};

    // ── Continuous breathing loop ──
    // The autonomic controller routes between inhale (input) and exhale (idle).
    // Each tick is one breath. The model thinks, learns, persists — autonomously.
    while (true) {
        // ════════════════════════════════════
        // INHALE: check for incoming request
        // ════════════════════════════════════
        if (pollRequest(req_fd)) |req| {
            // Process query through inhale pipeline with warm state
            const response = handleRequestWithDopamine(
                &transformer,
                &state,
                &tok,
                req.prompt,
                req.max_tokens,
                req.temperature,
                &controller.ctx.pos,
                &controller.ctx.recent_ring,
                &controller.ctx.recent_count,
                &controller.ctx.replay_buf,
                controller.ctx.config.surprise_threshold,
                alloc,
            ) catch {
                sendError(resp_fd);
                alloc.free(req.prompt);
                continue;
            };
            alloc.free(req.prompt);
            defer alloc.free(response);

            // Send response
            const resp_len: u32 = @intCast(response.len);
            writeAll(resp_fd, std.mem.asBytes(&resp_len)) catch return;
            writeAll(resp_fd, response) catch return;

            controller.ctx.total_inhales += 1;
            controller.ctx.exhale_counter = 0;
            continue;
        }

        // ════════════════════════════════════
        // EXHALE: idle — think and consolidate
        // ════════════════════════════════════
        _ = controller.tick();
    }
}

/// Compute surprise = -log(p(token)) from logits.
fn computeSurprise(logits: []f32, token: tokenizer.Token) f32 {
    if (token < 0 or @as(usize, @intCast(token)) >= logits.len) return 0;

    // Compute log-softmax for the target token
    // First find max for numerical stability
    var max_logit: f32 = logits[0];
    for (logits[1..]) |l| {
        if (l > max_logit) max_logit = l;
    }

    var sum_exp: f32 = 0;
    for (logits) |l| {
        sum_exp += std.math.exp(l - max_logit);
    }

    const target_logit = logits[@intCast(token)];
    const log_prob = (target_logit - max_logit) - @log(sum_exp);

    return -log_prob; // surprise = -log(p)
}

/// Handle request with dopamine tracking and replay buffer.
fn handleRequestWithDopamine(
    transformer: *const model.Transformer,
    state: *model.State,
    tok_: *const tokenizer.Tokenizer,
    prompt: []const u8,
    max_tokens: u16,
    _temperature: f32,
    pos: *usize,
    recent_ring: *[64]tokenizer.Token,
    recent_count: *usize,
    replay_buf: *ctm.ReplayBuffer,
    surprise_threshold: f32,
    alloc: std.mem.Allocator,
) ![]u8 {
    _ = _temperature; // temperatures are fixed per-candidate now

    // Tokenize prompt
    const tokens = try tok_.encode(prompt, false, alloc);
    defer alloc.free(tokens);

    // Batch prefill — process all prompt tokens in one pass (no per-token GPU dispatch)
    var prefill_timer = std.time.Timer.start() catch null;
    var total_surprise: f32 = 0;

    // Reset position for fresh context
    pos.* = 0;
    recent_count.* = 0;

    if (tokens.len > 1) {
        // Batch prefill: all tokens at once through transformer
        var batch_ok = true;
        _ = transformer.prefillBatch(state, tokens, alloc) catch {
            // Fallback to sequential prefill
            batch_ok = false;
            for (tokens) |t| {
                _ = transformer.forward(state, t, pos.*);
                pos.* += 1;
                recent_ring[recent_count.* % 64] = t;
                recent_count.* += 1;
            }
        };
        if (batch_ok) {
            pos.* = tokens.len;
            for (tokens) |t| {
                recent_ring[recent_count.* % 64] = t;
                recent_count.* += 1;
            }
        }
    } else {
        // Single token — use regular forward
        for (tokens) |t| {
            _ = transformer.forward(state, t, pos.*);
            pos.* += 1;
            recent_ring[recent_count.* % 64] = t;
            recent_count.* += 1;
        }
    }

    const prefill_ns = if (prefill_timer) |*t| t.read() else 0;

    // Save KV cache state after prefill for multi-candidate generation
    const saved_pos = pos.*;
    const saved_recent_count = recent_count.*;
    const dim = transformer.config.dim;
    const saved_input = try alloc.alloc(f32, dim);
    defer alloc.free(saved_input);
    @memcpy(saved_input, state.input[0..dim]);
    // Save logits (output from last prefill token — needed for first sample)
    const vocab_size = transformer.config.vocab_size;
    const saved_output = try alloc.alloc(f32, vocab_size);
    defer alloc.free(saved_output);
    @memcpy(saved_output, state.output[0..vocab_size]);

    // Generate N candidates with different temperatures, keep highest log-prob
    const kv_dim = (dim * transformer.config.n_kv_heads) / transformer.config.n_heads;
    const kv_save_len = @as(usize, max_tokens) * kv_dim * transformer.config.n_layers;
    const kv_save_k = alloc.alloc(f32, kv_save_len) catch null;
    const kv_save_v = alloc.alloc(f32, kv_save_len) catch null;
    defer if (kv_save_k) |s| alloc.free(s);
    defer if (kv_save_v) |s| alloc.free(s);

    // Fall back to single candidate if KV cache save failed (can't restore between candidates)
    const N_CAND: usize = if (kv_save_k != null and kv_save_v != null) 4 else 1;
    const all_temps = [4]f32{ 0.0, 0.3, 0.5, 0.8 };
    const temps = all_temps[0..N_CAND];

    var best_tokens: std.ArrayList(tokenizer.Token) = .{};
    defer best_tokens.deinit(alloc);
    var best_score: f32 = -std.math.inf(f32);

    // Snapshot the KV cache entries that generation will overwrite
    if (kv_save_k != null and kv_save_v != null) {
        for (0..transformer.config.n_layers) |li| {
            const layer_off = li * transformer.config.max_seq_length * kv_dim;
            const save_off = li * @as(usize, max_tokens) * kv_dim;
            for (0..@as(usize, max_tokens)) |ti| {
                const cache_pos = (saved_pos + ti) % transformer.config.max_seq_length;
                const src = layer_off + cache_pos * kv_dim;
                const dst = save_off + ti * kv_dim;
                @memcpy(kv_save_k.?[dst..][0..kv_dim], state.k_cache[src..][0..kv_dim]);
                @memcpy(kv_save_v.?[dst..][0..kv_dim], state.v_cache[src..][0..kv_dim]);
            }
        }
    }

    for (0..N_CAND) |ci| {
        // Restore state to post-prefill
        pos.* = saved_pos;
        recent_count.* = saved_recent_count;
        @memcpy(state.input[0..dim], saved_input);
        @memcpy(state.output[0..vocab_size], saved_output);

        // Restore KV cache for generation region
        if (kv_save_k != null and kv_save_v != null) {
            for (0..transformer.config.n_layers) |li| {
                const layer_off = li * transformer.config.max_seq_length * kv_dim;
                const save_off = li * @as(usize, max_tokens) * kv_dim;
                for (0..@as(usize, max_tokens)) |ti| {
                    const cache_pos = (saved_pos + ti) % transformer.config.max_seq_length;
                    const src = save_off + ti * kv_dim;
                    const dst = layer_off + cache_pos * kv_dim;
                    @memcpy(state.k_cache[dst..][0..kv_dim], kv_save_k.?[src..][0..kv_dim]);
                    @memcpy(state.v_cache[dst..][0..kv_dim], kv_save_v.?[src..][0..kv_dim]);
                }
            }
        }

        const t_val = temps[ci];
        const params = SampleParams{
            .temperature = t_val,
            .top_k = if (t_val > 0) 40 else 0,
            .repetition_penalty = if (t_val > 0) 1.1 else 1.0,
        };

        var next_tok: tokenizer.Token = sampleToken(state.output, params, recent_ring[0..@min(recent_count.*, 64)]);

        var cand: std.ArrayList(tokenizer.Token) = .{};
        var total_logprob: f32 = 0;

        for (0..max_tokens) |_| {
            if (next_tok == tok_.eos_id) break;
            cand.append(alloc, next_tok) catch break;

            recent_ring[recent_count.* % 64] = next_tok;
            recent_count.* += 1;

            _ = transformer.forward(state, next_tok, pos.*);
            pos.* += 1;

            // Compute log-probability of this token
            var max_logit: f32 = -std.math.inf(f32);
            for (state.output[0..vocab_size]) |l| if (l > max_logit) { max_logit = l; };
            var sum_exp: f32 = 0;
            for (state.output[0..vocab_size]) |l| sum_exp += std.math.exp(l - max_logit);
            const tok_logprob = state.output[@intCast(next_tok)] - max_logit - @log(sum_exp);
            total_logprob += tok_logprob;

            // Early termination (greedy candidate only): stop when uncertain.
            // Sampled candidates (t>0) naturally have lower per-token log-prob,
            // so early stopping would kill them immediately.
            if (t_val == 0) {
                const byte: u8 = @intCast(next_tok & 0xFF);
                const at_boundary = (byte == ' ' or byte == '"' or byte == '\'' or byte == '/' or byte == '|' or byte == ';');
                if (tok_logprob < -2.0 and at_boundary) break;
                if (tok_logprob < -4.0) break;
            }

            if (state.ctm_state) |cs| {
                const surprise = computeSurprise(state.output, next_tok);
                cs.updateDopamine(surprise);
                total_surprise += surprise;
            }

            const lb = @min(recent_count.*, 64);
            next_tok = sampleToken(state.output, params, recent_ring[0..lb]);
        }

        // Score by average log-prob per token (normalizes for length)
        // This prefers shorter confident completions over longer uncertain ones
        const n_cand_tok: f32 = @floatFromInt(@max(cand.items.len, 1));
        const avg_score = total_logprob / n_cand_tok;

        if (cand.items.len > 0 and avg_score > best_score) {
            best_score = avg_score;
            best_tokens.clearRetainingCapacity();
            best_tokens.appendSlice(alloc, cand.items) catch {};
        }
        cand.deinit(alloc);
    }

    const total_ns = if (prefill_timer) |*t| t.read() else 0;

    // Log timing
    {
        const dbg = std.fs.openFileAbsolute("/tmp/zish_inference.log", .{ .mode = .write_only }) catch null;
        if (dbg) |f| {
            defer f.close();
            f.seekFromEnd(0) catch {};
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "timing: prefill={d}ms/{d}tok gen={d}ms/{d}tok x{d}\n", .{
                prefill_ns / std.time.ns_per_ms,
                tokens.len,
                (total_ns - prefill_ns) / std.time.ns_per_ms,
                best_tokens.items.len,
                N_CAND,
            }) catch "?";
            f.writeAll(msg) catch {};
        }
    }

    // Store in replay buffer if surprising enough
    const n_total = tokens.len + best_tokens.items.len;
    if (n_total > 0) {
        const mean_surprise = total_surprise / @as(f32, @floatFromInt(n_total));
        replay_buf.push(tokens, mean_surprise, surprise_threshold);
    }

    return tok_.decodeAll(best_tokens.items, alloc);
}

/// Derive a sibling path by replacing extension.
/// e.g., "/path/model.gguf" + ".ctmstate" -> "/path/model.ctmstate"
fn derivePath(buf: *[512]u8, base: []const u8, suffix: []const u8) ?[]const u8 {
    // Find last '.'
    var dot: usize = base.len;
    var i: usize = base.len;
    while (i > 0) {
        i -= 1;
        if (base[i] == '.') {
            dot = i;
            break;
        }
        if (base[i] == '/') break;
    }

    if (dot + suffix.len > 512) return null;
    @memcpy(buf[0..dot], base[0..dot]);
    @memcpy(buf[dot..][0..suffix.len], suffix);
    return buf[0 .. dot + suffix.len];
}

/// Poll for a request on the non-blocking pipe. Returns null if no request.
fn pollRequest(req_fd: posix.fd_t) ?struct { prompt: []u8, max_tokens: u16, temperature: f32 } {
    const alloc = std.heap.page_allocator;

    // Try non-blocking read of prompt length
    var prompt_len_buf: [4]u8 = undefined;
    var read_total: usize = 0;
    while (read_total < 4) {
        const n = posix.read(req_fd, prompt_len_buf[read_total..]) catch |e| switch (e) {
            error.WouldBlock => {
                if (read_total == 0) return null; // no data yet
                continue; // partial read, wait for rest
            },
            else => return null, // pipe closed or error
        };
        if (n == 0) {
            // EOF — parent closed pipe, exit
            posix.exit(0);
        }
        read_total += n;
    }
    const prompt_len: u32 = @bitCast(prompt_len_buf);
    if (prompt_len > 1024 * 1024) {
        posix.exit(1);
    }

    // Once we've started reading a request, switch to blocking for the rest
    const prompt = alloc.alloc(u8, prompt_len) catch return null;
    readExact(req_fd, prompt) catch {
        alloc.free(prompt);
        return null;
    };

    var max_tokens_buf: [2]u8 = undefined;
    readExact(req_fd, &max_tokens_buf) catch {
        alloc.free(prompt);
        return null;
    };
    const max_tokens: u16 = @bitCast(max_tokens_buf);

    var temp_buf: [4]u8 = undefined;
    readExact(req_fd, &temp_buf) catch {
        alloc.free(prompt);
        return null;
    };
    const temperature: f32 = @bitCast(temp_buf);

    return .{ .prompt = prompt, .max_tokens = max_tokens, .temperature = temperature };
}

/// Handle a query request using the model's warm state (no KV cache reset).
/// Prefills the prompt tokens, generates response, returns decoded text.
fn handleRequest(
    transformer: *const model.Transformer,
    state: *model.State,
    tok_: *const tokenizer.Tokenizer,
    prompt: []const u8,
    max_tokens: u16,
    temperature: f32,
    pos: *usize,
    recent_ring: *[64]tokenizer.Token,
    recent_count: *usize,
    alloc: std.mem.Allocator,
) ![]u8 {
    // Tokenize prompt — skip BOS for byte-level models (vocab_size <= 256)
    const add_bos = tok_.vocab_size > 256;
    const tokens = try tok_.encode(prompt, add_bos, alloc);
    defer alloc.free(tokens);

    // Reset position for each completion request (independent contexts)
    pos.* = 0;
    recent_count.* = 0;

    var timer = std.time.Timer.start() catch null;

    // Prefill prompt tokens
    for (tokens) |t| {
        _ = transformer.forward(state, t, pos.*);
        pos.* += 1;
        recent_ring[recent_count.* % 64] = t;
        recent_count.* += 1;
    }

    const prefill_ns = if (timer) |*t| t.read() else 0;

    const params = SampleParams{
        .temperature = temperature,
        .top_k = if (temperature > 0) 40 else 0,
        .repetition_penalty = if (temperature > 0) 1.1 else 1.0,
    };

    // Sample first response token
    const lookback = @min(recent_count.*, 64);
    var next_tok: tokenizer.Token = sampleToken(state.output, params, recent_ring[0..lookback]);

    // Generate response tokens
    var output_tokens: std.ArrayList(tokenizer.Token) = .{};
    defer output_tokens.deinit(alloc);

    for (0..max_tokens) |_| {
        if (next_tok == tok_.eos_id) break;
        output_tokens.append(alloc, next_tok) catch return error.OutOfMemory;

        recent_ring[recent_count.* % 64] = next_tok;
        recent_count.* += 1;

        _ = transformer.forward(state, next_tok, pos.*);
        pos.* += 1;

        const lb = @min(recent_count.*, 64);
        next_tok = sampleToken(state.output, params, recent_ring[0..lb]);
    }

    const total_ns = if (timer) |*t| t.read() else 0;

    // Log timing
    {
        const dbg = std.fs.openFileAbsolute("/tmp/zish_inference.log", .{ .mode = .write_only }) catch null;
        if (dbg) |f| {
            defer f.close();
            f.seekFromEnd(0) catch {};
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "timing: prefill={d}ms ({d} toks) gen={d}ms ({d} toks)\n", .{
                prefill_ns / std.time.ns_per_ms,
                tokens.len,
                (total_ns - prefill_ns) / std.time.ns_per_ms,
                output_tokens.items.len,
            }) catch "?";
            f.writeAll(msg) catch {};
        }
    }

    return tok_.decodeAll(output_tokens.items, alloc);
}

fn sendError(fd: posix.fd_t) void {
    const err_marker: u32 = PROTO_ERROR;
    writeAll(fd, std.mem.asBytes(&err_marker)) catch {};
}

/// Core generation logic (used by both in-process and forked modes).
fn generateTokens(
    transformer: *const model.Transformer,
    state: *model.State,
    tok: *const tokenizer.Tokenizer,
    prompt: []const u8,
    max_tokens: u16,
    temperature: f32,
    alloc: Allocator,
) ![]u8 {
    // Tokenize — skip BOS for byte-level models
    const add_bos = tok.vocab_size > 256;
    const tokens = try tok.encode(prompt, add_bos, alloc);
    defer alloc.free(tokens);

    // Prefill
    var pos: usize = 0;
    for (tokens) |t| {
        _ = transformer.forward(state, t, pos);
        pos += 1;
    }

    const params = SampleParams{
        .temperature = temperature,
        .top_k = if (temperature > 0) 40 else 0,
        .repetition_penalty = if (temperature > 0) 1.1 else 1.0,
    };

    // Sample first token (no recent tokens for penalty yet)
    var next_tok: Token = sampleToken(state.output, params, &.{});

    // Generate with repetition penalty lookback
    var output_tokens: std.ArrayList(Token) = .{};
    defer output_tokens.deinit(alloc);

    // Ring buffer for recent tokens (lookback 64, adapted from nanochat)
    var recent_ring: [64]Token = [_]Token{-1} ** 64;
    var recent_count: usize = 0;

    for (0..max_tokens) |_| {
        if (next_tok == tok.eos_id) break;
        output_tokens.append(alloc, next_tok) catch return error.OutOfMemory;

        // Track recent tokens for repetition penalty
        recent_ring[recent_count % 64] = next_tok;
        recent_count += 1;

        _ = transformer.forward(state, next_tok, pos);
        pos += 1;

        const lookback = @min(recent_count, 64);
        next_tok = sampleToken(state.output, params, recent_ring[0..lookback]);
    }

    return tok.decodeAll(output_tokens.items, alloc);
}

// ============================================================
// Pipe I/O helpers
// ============================================================

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = posix.write(fd, data[written..]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        if (n == 0) return error.BrokenPipe;
        written += n;
    }
}

fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var read_total: usize = 0;
    while (read_total < buf.len) {
        const n = posix.read(fd, buf[read_total..]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        if (n == 0) return error.EndOfStream;
        read_total += n;
    }
}

// ============================================================
// In-process inference (kept for direct use without fork)
// ============================================================

/// High-level inference context. Load once, generate many times.
/// For process-isolated inference, use ForkServer instead.
pub const InferenceContext = struct {
    file: gguf.GGUFFile,
    transformer: model.Transformer,
    state: model.State,
    tok: tokenizer.Tokenizer,
    alloc: Allocator,
    n_generated: usize = 0,
    ctm_layer_idx: usize = 0,
    model_path: []const u8 = "",
    replay_buf: ctm.ReplayBuffer = .{},
    gpu_ctx: ?*gpu_mod.GpuContext = null,

    /// Load a GGUF model file for inference with plasticity support.
    pub fn load(path: []const u8, alloc: Allocator) !InferenceContext {
        var file = try gguf.GGUFFile.open(path, alloc);
        errdefer file.deinit();

        var transformer = try model.Transformer.initFromGGUF(&file, alloc);
        errdefer transformer.deinit();

        var state = try model.State.init(alloc, transformer.config);
        errdefer state.deinit();

        var tok = try tokenizer.Tokenizer.initFromGGUF(&file, alloc);
        errdefer tok.deinit();

        var ctm_idx: usize = 0;

        // Initialize CTM state if model has CTM blocks
        for (0..transformer.config.n_layers) |i| {
            if (transformer.layers[i].ctm_block) |blk| {
                const ctm_state_ptr = try alloc.create(ctm.CTMState);
                ctm_state_ptr.* = try ctm.CTMState.init(alloc, transformer.config.n_layers, blk.config.n_synch);
                ctm_state_ptr.last_state = try alloc.alloc(f32, blk.config.dim);
                state.ctm_state = ctm_state_ptr;
                state.ctm_scratch = try alloc.alloc(f32, ctm.CTMBlock.scratchSize(blk.config));
                ctm_idx = i;

                // Make weights plastic
                const mutable_blk = @constCast(blk);
                try mutable_blk.makePlastic(alloc);

                // Load persisted state
                var sp_buf: [512]u8 = undefined;
                var wp_buf: [512]u8 = undefined;
                if (derivePath(&sp_buf, path, ".ctmstate")) |sp| _ = ctm_state_ptr.load(sp);
                if (derivePath(&wp_buf, path, ".plastic")) |wp| _ = mutable_blk.loadPlasticWeights(wp);

                break;
            }
        }

        // Try to initialize GPU compute (graceful fallback to CPU)
        var gpu_ptr: ?*gpu_mod.GpuContext = null;
        const td_base = file.tensorData();
        const td_size = file.file_size - file.tensor_data_offset;
        if (gpu_mod.GpuContext.init(alloc, false)) |g| {
            const gp = alloc.create(gpu_mod.GpuContext) catch null;
            if (gp) |p| {
                p.* = g;
                if (p.vram_bytes >= td_size) {
                    if (p.uploadWeights(td_base[0..td_size])) {
                        gpu_ptr = p;
                        transformer.setGpu(p, td_base);
                        const name_len = std.mem.indexOfScalar(u8, &p.device_name, 0) orelse p.device_name.len;
                        std.debug.print("[gpu] {s}: {}MB VRAM, {}MB weights uploaded\n", .{
                            p.device_name[0..name_len],
                            p.vram_bytes / (1024 * 1024),
                            td_size / (1024 * 1024),
                        });
                    } else {
                        p.deinit();
                        alloc.destroy(p);
                    }
                } else {
                    p.deinit();
                    alloc.destroy(p);
                }
            } else {
                var g2 = g;
                g2.deinit();
            }
        }

        return .{
            .file = file,
            .transformer = transformer,
            .state = state,
            .tok = tok,
            .alloc = alloc,
            .ctm_layer_idx = ctm_idx,
            .model_path = path,
            .gpu_ctx = gpu_ptr,
        };
    }

    pub fn deinit(self: *InferenceContext) void {
        if (self.gpu_ctx) |g| {
            g.deinit();
            self.alloc.destroy(g);
        }
        self.tok.deinit();
        self.state.deinit();
        self.transformer.deinit();
        self.file.deinit();
    }

    /// Generate text given a prompt. Returns generated text (caller owns).
    pub fn generate(
        self: *InferenceContext,
        prompt: []const u8,
        max_tokens: usize,
        temperature: f32,
    ) ![]u8 {
        return generateTokens(
            &self.transformer,
            &self.state,
            &self.tok,
            prompt,
            @intCast(@min(max_tokens, std.math.maxInt(u16))),
            temperature,
            self.alloc,
        );
    }

    /// Reset state for a new generation (clears KV cache).
    pub fn reset(self: *InferenceContext) void {
        @memset(self.state.k_cache, 0);
        @memset(self.state.v_cache, 0);
        self.n_generated = 0;
    }

    /// Get model info for display.
    pub fn modelInfo(self: *const InferenceContext) struct { arch: []const u8, dim: usize, layers: usize, vocab: usize } {
        const c = self.transformer.config;
        return .{ .arch = c.arch, .dim = c.dim, .layers = c.n_layers, .vocab = c.vocab_size };
    }

    /// EXHALE: run one consolidation step (compact memory from sync patterns).
    /// Call this during idle time. Returns plasticity stats.
    pub fn breathe(self: *InferenceContext, lr: f32) ctm.PlasticityStats {
        const cs = self.state.ctm_state orelse return .{};
        const blk = self.transformer.layers[self.ctm_layer_idx].ctm_block orelse return .{};
        return @constCast(blk).compactMemoryFull(cs, self.ctm_layer_idx, lr);
    }

    /// Benchmark: run N forward passes and report tokens/sec.
    /// Returns {prefill_tps, generate_tps, gpu_active}.
    pub fn bench(self: *InferenceContext, n_tokens: usize) struct { prefill_tps: f64, generate_tps: f64, gpu: bool } {
        const prompt = "The quick brown fox jumps over the lazy dog and then";
        const tokens = self.tok.encode(prompt, true, self.alloc) catch return .{ .prefill_tps = 0, .generate_tps = 0, .gpu = self.gpu_ctx != null };
        defer self.alloc.free(tokens);

        // Reset KV cache
        self.reset();

        // Prefill benchmark
        var timer = std.time.Timer.start() catch return .{ .prefill_tps = 0, .generate_tps = 0, .gpu = self.gpu_ctx != null };
        for (tokens, 0..) |t, i| {
            _ = self.transformer.forward(&self.state, t, i);
            if (i == 0) {
                const first_ns = timer.read();
                std.debug.print("[bench] first token: {d:.1}ms\n", .{@as(f64, @floatFromInt(first_ns)) / 1e6});
            }
        }
        const prefill_ns = timer.read();
        const prefill_tps = if (prefill_ns > 0) @as(f64, @floatFromInt(tokens.len)) * 1e9 / @as(f64, @floatFromInt(prefill_ns)) else 0;
        std.debug.print("[bench] prefill {d} tokens in {d:.1}ms\n", .{ tokens.len, @as(f64, @floatFromInt(prefill_ns)) / 1e6 });

        // Generation benchmark
        var pos = tokens.len;
        var next_tok = sampleToken(self.state.output, .{ .temperature = 0.0, .top_k = 0, .repetition_penalty = 1.0 }, &.{});

        timer.reset();
        for (0..n_tokens) |gen_i| {
            if (next_tok == self.tok.eos_id) break;
            _ = self.transformer.forward(&self.state, next_tok, pos);
            pos += 1;
            next_tok = sampleToken(self.state.output, .{ .temperature = 0.0, .top_k = 0, .repetition_penalty = 1.0 }, &.{});
            if (gen_i == 0) {
                const t1 = timer.read();
                std.debug.print("[bench] gen token 1: {d:.1}ms\n", .{@as(f64, @floatFromInt(t1)) / 1e6});
            }
        }
        const gen_ns = timer.read();
        const actual_gen = pos - tokens.len;
        const gen_tps = if (gen_ns > 0 and actual_gen > 0) @as(f64, @floatFromInt(actual_gen)) * 1e9 / @as(f64, @floatFromInt(gen_ns)) else 0;

        return .{
            .prefill_tps = prefill_tps,
            .generate_tps = gen_tps,
            .gpu = self.gpu_ctx != null,
        };
    }

    /// Run dream diagnostics on current state. Returns per-tick convergence deltas.
    pub fn dream(self: *InferenceContext, x: []const f32, deltas: []f32) void {
        const cs = self.state.ctm_state orelse return;
        const blk = self.transformer.layers[self.ctm_layer_idx].ctm_block orelse return;
        blk.dream(x, cs, self.ctm_layer_idx, self.state.ctm_scratch, deltas);
    }

    /// Update dopamine from prediction surprise after sampling a token.
    pub fn updateDopamine(self: *InferenceContext, surprise: f32) void {
        if (self.state.ctm_state) |cs| cs.updateDopamine(surprise);
    }

    /// Persist all plastic state to disk (sync + weights + replay buffer).
    pub fn persist(self: *InferenceContext) void {
        var sp_buf: [512]u8 = undefined;
        var wp_buf: [512]u8 = undefined;
        var rp_buf: [512]u8 = undefined;

        if (self.state.ctm_state) |cs| {
            if (derivePath(&sp_buf, self.model_path, ".ctmstate")) |sp|
                cs.save(sp) catch {};
        }
        if (self.transformer.layers[self.ctm_layer_idx].ctm_block) |blk| {
            if (derivePath(&wp_buf, self.model_path, ".plastic")) |wp|
                blk.savePlasticWeights(wp) catch {};
        }
        if (derivePath(&rp_buf, self.model_path, ".replay")) |rp|
            self.replay_buf.save(rp) catch {};
    }

    /// Check if this model has CTM plasticity enabled.
    pub fn hasPlasticity(self: *const InferenceContext) bool {
        return self.state.ctm_state != null and
            self.transformer.layers[self.ctm_layer_idx].ctm_block != null;
    }
};

/// Sampling parameters.
const SampleParams = struct {
    temperature: f32 = 0,
    top_k: u16 = 0, // 0 = disabled
    repetition_penalty: f32 = 1.0, // 1.0 = disabled
};

/// Apply repetition penalty to logits based on recently generated tokens.
/// Adapted from nanochat/engine.py: asymmetric penalty (divide positive, multiply negative).
fn applyRepetitionPenalty(logits: []f32, recent_tokens: []const Token, penalty: f32) void {
    if (penalty == 1.0) return;
    for (recent_tokens) |tok| {
        const idx: usize = @intCast(tok);
        if (idx >= logits.len) continue;
        if (logits[idx] > 0) {
            logits[idx] /= penalty;
        } else {
            logits[idx] *= penalty;
        }
    }
}

/// Sample next token from logits with top-k, temperature, and repetition penalty.
/// Adapted from nanochat/engine.py sampling logic.
fn sampleToken(logits: []f32, params: SampleParams, recent_tokens: []const Token) Token {
    // Apply repetition penalty
    applyRepetitionPenalty(logits, recent_tokens, params.repetition_penalty);

    if (params.temperature <= 0) {
        // Greedy: argmax
        var best_idx: usize = 0;
        var best_val: f32 = logits[0];
        for (1..logits.len) |i| {
            if (logits[i] > best_val) {
                best_val = logits[i];
                best_idx = i;
            }
        }
        return @intCast(best_idx);
    }

    var rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));

    if (params.top_k > 0 and params.top_k < logits.len) {
        // Top-k sampling: find k largest logits, sample from those only
        return sampleTopK(logits, params.top_k, params.temperature, &rng);
    }

    // Full-vocabulary temperature sampling
    for (logits) |*l| l.* /= params.temperature;
    math.softMax(logits);

    return multinomial(logits, &rng);
}

/// Top-k sampling: select top k logits, temperature-scale, softmax, sample.
/// Uses partial selection (O(n*k)) — fine for k << vocab_size.
fn sampleTopK(logits: []f32, k: u16, temperature: f32, rng: *std.Random.DefaultPrng) Token {
    // Find top-k indices and values using a min-heap of size k
    var top_vals: [256]f32 = undefined;
    var top_idx: [256]u32 = undefined;
    const actual_k: usize = @min(k, 256);

    // Initialize with first k elements
    for (0..actual_k) |i| {
        top_vals[i] = logits[i];
        top_idx[i] = @intCast(i);
    }

    // Find minimum in current top-k
    var min_pos: usize = 0;
    var min_val: f32 = top_vals[0];
    for (1..actual_k) |i| {
        if (top_vals[i] < min_val) {
            min_val = top_vals[i];
            min_pos = i;
        }
    }

    // Scan rest, replacing minimum when we find something larger
    for (actual_k..logits.len) |i| {
        if (logits[i] > min_val) {
            top_vals[min_pos] = logits[i];
            top_idx[min_pos] = @intCast(i);
            // Find new minimum
            min_val = top_vals[0];
            min_pos = 0;
            for (1..actual_k) |j| {
                if (top_vals[j] < min_val) {
                    min_val = top_vals[j];
                    min_pos = j;
                }
            }
        }
    }

    // Temperature scale and softmax over top-k only
    for (top_vals[0..actual_k]) |*v| v.* /= temperature;
    math.softMax(top_vals[0..actual_k]);

    // Multinomial from top-k
    const r = rng.random().float(f32);
    var cumulative: f32 = 0;
    for (0..actual_k) |i| {
        cumulative += top_vals[i];
        if (cumulative >= r) return @intCast(top_idx[i]);
    }
    return @intCast(top_idx[actual_k - 1]);
}

/// Safe multinomial sampling with NaN/inf fallback.
fn multinomial(probs: []f32, rng: *std.Random.DefaultPrng) Token {
    const r = rng.random().float(f32);
    var cumulative: f32 = 0;
    for (0..probs.len) |i| {
        const p = probs[i];
        if (std.math.isNan(p) or std.math.isInf(p)) continue;
        cumulative += p;
        if (cumulative >= r) return @intCast(i);
    }
    // Fallback: return last token (shouldn't happen with valid softmax)
    return @intCast(probs.len - 1);
}
