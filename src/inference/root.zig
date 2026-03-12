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
pub const math = @import("math.zig");
pub const model = @import("model.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const ctm = @import("ctm.zig");

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
/// Continuous inference mode: the model keeps running forward passes between
/// requests, feeding its own output back as input. This keeps CTM sync
/// accumulators warm and evolving. When a query arrives, the model processes
/// it with its warm state, generates a response, then resumes thinking.
///
/// KV cache wraps at max_seq_length (position modular). CTM state never resets.
fn childMain(req_fd: posix.fd_t, resp_fd: posix.fd_t, model_path: []const u8) void {
    // Use page allocator in child (simple, no fragmentation concerns since we exit)
    const alloc = std.heap.page_allocator;

    // Load model
    var file = gguf.GGUFFile.open(model_path, alloc) catch {
        sendError(resp_fd);
        return;
    };

    var transformer = model.Transformer.initFromGGUF(&file, alloc) catch {
        sendError(resp_fd);
        return;
    };

    var state = model.State.init(alloc, transformer.config) catch {
        sendError(resp_fd);
        return;
    };

    var tok = tokenizer.Tokenizer.initFromGGUF(&file, alloc) catch {
        sendError(resp_fd);
        return;
    };

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
            state.ctm_state = ctm_state_ptr;
            state.ctm_scratch = alloc.alloc(f32, ctm.CTMBlock.scratchSize(blk.config)) catch {
                sendError(resp_fd);
                return;
            };
            break;
        }
    }

    // Set request pipe to non-blocking for continuous inference polling
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = 2048;
    const cur_flags = posix.fcntl(req_fd, F_GETFL, 0) catch 0;
    _ = posix.fcntl(req_fd, F_SETFL, cur_flags | O_NONBLOCK) catch {};

    // Continuous inference state
    var pos: usize = 0;
    var current_tok: tokenizer.Token = tok.bos_id;

    // Ring buffer for recent tokens (repetition penalty lookback)
    var recent_ring: [64]tokenizer.Token = [_]tokenizer.Token{-1} ** 64;
    var recent_count: usize = 0;

    const think_params = SampleParams{
        .temperature = 0.7,
        .top_k = 40,
        .repetition_penalty = 1.1,
    };

    // ── Continuous inference loop ──
    while (true) {
        // Check for incoming request (non-blocking)
        if (pollRequest(req_fd)) |req| {
            // Process query with warm state
            const response = handleRequest(
                &transformer,
                &state,
                &tok,
                req.prompt,
                req.max_tokens,
                req.temperature,
                &pos,
                &recent_ring,
                &recent_count,
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

            // Continue with last generated token
            continue;
        }

        // No request — run one thinking step (self-feeding forward pass)
        _ = transformer.forward(&state, current_tok, pos);
        pos += 1;

        // Track for repetition penalty
        recent_ring[recent_count % 64] = current_tok;
        recent_count += 1;

        // Sample next thinking token
        const lookback = @min(recent_count, 64);
        current_tok = sampleToken(state.output, think_params, recent_ring[0..lookback]);

        // Don't spin too fast — yield between thinking steps
        // (forward pass already takes ~10-100ms depending on model size)
        if (current_tok == tok.eos_id) {
            // Restart thinking from BOS
            current_tok = tok.bos_id;
        }
    }
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
    // Tokenize prompt
    const tokens = try tok_.encode(prompt, false, alloc); // no BOS — continuing context
    defer alloc.free(tokens);

    // Prefill prompt tokens into the warm context
    for (tokens) |t| {
        _ = transformer.forward(state, t, pos.*);
        pos.* += 1;
        recent_ring[recent_count.* % 64] = t;
        recent_count.* += 1;
    }

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
    // Tokenize
    const tokens = try tok.encode(prompt, true, alloc);
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

    /// Load a GGUF model file for inference.
    pub fn load(path: []const u8, alloc: Allocator) !InferenceContext {
        var file = try gguf.GGUFFile.open(path, alloc);
        errdefer file.deinit();

        var transformer = try model.Transformer.initFromGGUF(&file, alloc);
        errdefer transformer.deinit();

        var state = try model.State.init(alloc, transformer.config);
        errdefer state.deinit();

        var tok = try tokenizer.Tokenizer.initFromGGUF(&file, alloc);
        errdefer tok.deinit();

        // Initialize CTM state if model has CTM blocks
        for (0..transformer.config.n_layers) |i| {
            if (transformer.layers[i].ctm_block) |blk| {
                const ctm_state_ptr = try alloc.create(ctm.CTMState);
                ctm_state_ptr.* = try ctm.CTMState.init(alloc, transformer.config.n_layers, blk.config.n_synch);
                state.ctm_state = ctm_state_ptr;
                state.ctm_scratch = try alloc.alloc(f32, ctm.CTMBlock.scratchSize(blk.config));
                break;
            }
        }

        return .{
            .file = file,
            .transformer = transformer,
            .state = state,
            .tok = tok,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *InferenceContext) void {
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
