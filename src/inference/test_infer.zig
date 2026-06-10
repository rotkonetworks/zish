// Standalone inference test — exercises model loading and generation.
// Build: zig build-exe src/inference/test_infer.zig -O ReleaseFast
// Run: ./test_infer [model_path] [prompt]

const std = @import("std");
const compat = @import("../compat.zig");
const gguf = @import("gguf.zig");
const model = @import("model.zig");
const tokenizer = @import("tokenizer.zig");
const math = @import("math.zig");
const ctm = @import("ctm.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    const args = try init.args.toSlice(alloc);
    const model_path = if (args.len > 1) args[1] else "/home/alice/.zish/models/qwen25_ctm_k32.gguf";
    const prompt = if (args.len > 2) args[2] else "ls -la";

    std.debug.print("=== Inference Test ===\n", .{});
    std.debug.print("Model: {s}\n", .{model_path});
    std.debug.print("Prompt: \"{s}\"\n\n", .{prompt});

    // 1. Open GGUF
    std.debug.print("[1/5] Opening GGUF file...\n", .{});
    var file = try gguf.GGUFFile.open(model_path, alloc);
    defer file.deinit();

    std.debug.print("  Version: {d}, Tensors: {d}\n", .{ file.header.version, file.header.tensor_count });

    // Dump key metadata
    std.debug.print("  Metadata:\n", .{});
    const keys = [_][]const u8{
        "general.architecture",
        "general.name",
        "qwen2.embedding_length",
        "qwen2.block_count",
        "qwen2.attention.head_count",
        "qwen2.attention.head_count_kv",
        "qwen2.feed_forward_length",
        "qwen2.context_length",
        "qwen2.rope.freq_base",
        "qwen2.ctm.enabled",
        "qwen2.ctm.iterations",
    };
    for (&keys) |key| {
        if (file.getString(key)) |v| {
            std.debug.print("    {s} = {s}\n", .{ key, v });
        } else if (file.getU32(key)) |v| {
            std.debug.print("    {s} = {d}\n", .{ key, v });
        } else if (file.getF32(key)) |v| {
            std.debug.print("    {s} = {d:.2}\n", .{ key, v });
        }
    }

    // List tensor types
    std.debug.print("\n  Tensor type summary:\n", .{});
    var type_counts: [32]u32 = [_]u32{0} ** 32;
    for (file.tensor_info) |ti| {
        const idx: usize = @intFromEnum(ti.ggml_type);
        if (idx < 32) type_counts[idx] += 1;
    }
    const type_names = [_][]const u8{ "F32", "F16", "Q4_0", "Q4_1", "", "", "Q5_0", "Q5_1", "Q8_0", "Q8_1", "Q2_K", "Q3_K", "Q4_K", "Q5_K", "Q6_K", "Q8_K" };
    for (0..16) |i| {
        if (type_counts[i] > 0) {
            std.debug.print("    {s}: {d} tensors\n", .{ type_names[i], type_counts[i] });
        }
    }

    // Show first few tensor names and types
    std.debug.print("\n  First 10 tensors:\n", .{});
    for (file.tensor_info[0..@min(10, file.tensor_info.len)]) |ti| {
        std.debug.print("    {s}: type={s} dims=[", .{ ti.name.str, @tagName(ti.ggml_type) });
        for (ti.dimensions, 0..) |d, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{d}", .{d});
        }
        std.debug.print("] elems={d}\n", .{ti.numElements()});
    }

    // 2. Load transformer config
    std.debug.print("\n[2/5] Loading transformer config...\n", .{});
    const config = model.Config.fromGGUF(&file);
    std.debug.print("  arch={s} dim={d} hidden={d} layers={d} heads={d}/{d} vocab={d} ctx={d}\n", .{
        config.arch,    config.dim,          config.hidden_dim,
        config.n_layers, config.n_heads,      config.n_kv_heads,
        config.vocab_size, config.max_seq_length,
    });
    std.debug.print("  rope_theta={d:.1} rms_eps={e} sliding_window={d}\n", .{
        config.rope_theta, config.rms_norm_eps, config.sliding_window,
    });

    // 3. Load transformer weights
    std.debug.print("\n[3/5] Loading transformer weights...\n", .{});
    var transformer = try model.Transformer.initFromGGUF(&file, alloc);
    defer transformer.deinit();
    std.debug.print("  OK — {d} layers loaded\n", .{transformer.config.n_layers});

    // Check for CTM
    var has_ctm = false;
    for (0..transformer.config.n_layers) |i| {
        if (transformer.layers[i].ctm_block) |blk| {
            std.debug.print("  CTM block at layer {d}: K={d} n_synch={d} mem={d}\n", .{
                i, blk.config.iterations, blk.config.n_synch, blk.config.memory_length,
            });
            has_ctm = true;
        }
    }
    if (!has_ctm) std.debug.print("  No CTM blocks\n", .{});

    // 4. Initialize state
    std.debug.print("\n[4/5] Initializing state...\n", .{});
    var state = try model.State.init(alloc, transformer.config);
    defer state.deinit();

    // Init CTM state if needed
    if (has_ctm) {
        for (0..transformer.config.n_layers) |i| {
            if (transformer.layers[i].ctm_block) |blk| {
                const ctm_state_ptr = try alloc.create(ctm.CTMState);
                ctm_state_ptr.* = try ctm.CTMState.init(alloc, transformer.config.n_layers, blk.config.n_synch);
                state.ctm_state = ctm_state_ptr;
                state.ctm_scratch = try alloc.alloc(f32, ctm.CTMBlock.scratchSize(blk.config));
                break;
            }
        }
    }

    const kv_dim = config.dim * config.n_kv_heads / config.n_heads;
    const kv_cache_mb = (config.n_layers * config.max_seq_length * kv_dim * 4 * 2) / (1024 * 1024);
    std.debug.print("  KV cache: {d} MB\n", .{kv_cache_mb});
    std.debug.print("  Threads: {d}\n", .{state.n_threads});

    // 5. Tokenize and run
    std.debug.print("\n[5/5] Tokenizing and generating...\n", .{});
    var tok = try tokenizer.Tokenizer.initFromGGUF(&file, alloc);
    defer tok.deinit();
    std.debug.print("  Vocab: {d} tokens, BOS={d} EOS={d}\n", .{ tok.vocab_size, tok.bos_id, tok.eos_id });

    const tokens = try tok.encode(prompt, true, alloc);
    defer alloc.free(tokens);
    std.debug.print("  Encoded \"{s}\" -> {d} tokens: ", .{ prompt, tokens.len });
    for (tokens) |t| std.debug.print("{d} ", .{t});
    std.debug.print("\n", .{});

    // Decode back to verify
    const decoded = try tok.decodeAll(tokens, alloc);
    defer alloc.free(decoded);
    std.debug.print("  Decoded back: \"{s}\"\n", .{decoded});

    // Run forward passes
    std.debug.print("\n  Running forward pass...\n", .{});
    ctm.CTMBlock.debug_ctm = false;
    var timer = try compat.Timer.start();

    var pos: usize = 0;
    for (tokens) |t| {
        _ = transformer.forward(&state, t, pos);
        pos += 1;
    }

    const prefill_ns = timer.read();
    std.debug.print("  Prefill: {d} tokens in {d}ms\n", .{ tokens.len, prefill_ns / 1_000_000 });

    // Show top-5 logits
    std.debug.print("  Top-5 logits after prefill:\n", .{});
    var top5_vals: [5]f32 = .{ -std.math.inf(f32) } ** 5;
    var top5_idx: [5]usize = .{0} ** 5;
    for (state.output, 0..) |v, i| {
        // Find minimum in top5
        var min_pos: usize = 0;
        for (1..5) |j| {
            if (top5_vals[j] < top5_vals[min_pos]) min_pos = j;
        }
        if (v > top5_vals[min_pos]) {
            top5_vals[min_pos] = v;
            top5_idx[min_pos] = i;
        }
    }
    for (0..5) |i| {
        const tok_str = tok.decode(@intCast(top5_idx[i])) orelse "?";
        std.debug.print("    [{d}] logit={d:.4} \"{s}\"\n", .{ top5_idx[i], top5_vals[i], tok_str });
    }

    // Generate some tokens
    std.debug.print("\n  Generating (greedy, max 20 tokens):\n  > ", .{});
    timer.reset();

    var gen_count: usize = 0;
    for (0..20) |_| {
        // Argmax
        var best_idx: usize = 0;
        var best_val: f32 = state.output[0];
        for (1..state.output.len) |i| {
            if (state.output[i] > best_val) {
                best_val = state.output[i];
                best_idx = i;
            }
        }

        const next_tok: i64 = @intCast(best_idx);
        if (next_tok == tok.eos_id) {
            std.debug.print("<EOS>", .{});
            break;
        }

        const tok_str = tok.decode(@intCast(best_idx)) orelse "?";
        std.debug.print("{s}", .{tok_str});

        _ = transformer.forward(&state, next_tok, pos);
        pos += 1;
        gen_count += 1;
    }

    const gen_ns = timer.read();
    std.debug.print("\n  Generated {d} tokens in {d}ms", .{ gen_count, gen_ns / 1_000_000 });
    if (gen_count > 0) {
        std.debug.print(" ({d:.1} tok/s)", .{@as(f64, @floatFromInt(gen_count)) * 1_000_000_000.0 / @as(f64, @floatFromInt(gen_ns))});
    }
    std.debug.print("\n\n=== Done ===\n", .{});
}
