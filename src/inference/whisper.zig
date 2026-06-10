// Whisper ASR: local speech-to-text inference.
//
// Complete encoder-decoder transformer for speech recognition.
// Loads whisper.cpp's GGML format. Runs as ForkServer child:
// parent pipes audio in, child pipes text out. Model stays warm.
//
// Encoder: Conv1D stem → transformer (full attention, GELU)
// Decoder: token embed → transformer (causal self-attn + cross-attn to encoder) → logits
//
// Special tokens: SOT=50257, EOT=50256, EN=50259, TRANSCRIBE=50358, NOTIMESTAMPS=50362

const std = @import("std");
const compat = @import("../compat.zig");
const math = @import("math.zig");
const posix = compat.posix;

const Allocator = std.mem.Allocator;

// Whisper special tokens (English-only model)
const SOT: u32 = 50257; // start of transcript
const EOT: u32 = 50256; // end of transcript
const LANG_EN: u32 = 50259;
const TRANSCRIBE: u32 = 50358;
const NO_TIMESTAMPS: u32 = 50362;
const MAX_TOKENS: usize = 224; // max generated tokens per chunk

pub const WhisperConfig = struct {
    n_vocab: u32,
    n_audio_ctx: u32, // 1500
    n_audio_state: u32, // 384/512/768
    n_audio_head: u32, // 6/8/12
    n_audio_layer: u32, // 4/6/12
    n_text_ctx: u32, // 448
    n_text_state: u32,
    n_text_head: u32,
    n_text_layer: u32,
    n_mels: u32, // 80
    ftype: u32,
};

// ── Layer weights ──

const EncLayer = struct {
    attn_ln_w: []const f32,
    attn_ln_b: []const f32,
    attn_q_w: []const f16,
    attn_q_b: []const f32,
    attn_k_w: []const f16,
    attn_v_w: []const f16,
    attn_v_b: []const f32,
    attn_out_w: []const f16,
    attn_out_b: []const f32,
    mlp_ln_w: []const f32,
    mlp_ln_b: []const f32,
    mlp_0_w: []const f16,
    mlp_0_b: []const f32,
    mlp_2_w: []const f16,
    mlp_2_b: []const f32,
};

const DecLayer = struct {
    // Self-attention (causal)
    attn_ln_w: []const f32,
    attn_ln_b: []const f32,
    attn_q_w: []const f16,
    attn_q_b: []const f32,
    attn_k_w: []const f16,
    attn_v_w: []const f16,
    attn_v_b: []const f32,
    attn_out_w: []const f16,
    attn_out_b: []const f32,
    // Cross-attention (to encoder)
    cross_attn_ln_w: []const f32,
    cross_attn_ln_b: []const f32,
    cross_q_w: []const f16,
    cross_q_b: []const f32,
    cross_k_w: []const f16,
    cross_v_w: []const f16,
    cross_v_b: []const f32,
    cross_out_w: []const f16,
    cross_out_b: []const f32,
    // MLP
    mlp_ln_w: []const f32,
    mlp_ln_b: []const f32,
    mlp_0_w: []const f16,
    mlp_0_b: []const f32,
    mlp_2_w: []const f16,
    mlp_2_b: []const f32,
};

// ── Model ──

pub const WhisperModel = struct {
    config: WhisperConfig,
    // Encoder
    enc_conv1_w: []const f16,
    enc_conv1_b: []const f32,
    enc_conv2_w: []const f16,
    enc_conv2_b: []const f32,
    enc_pos_emb: []const f32, // [d, 1500]
    enc_layers: []EncLayer,
    enc_ln_w: []const f32,
    enc_ln_b: []const f32,
    // Decoder
    dec_token_emb: []const f16, // [d, n_vocab]
    dec_pos_emb: []const f32, // [d, 448]
    dec_layers: []DecLayer,
    dec_ln_w: []const f32,
    dec_ln_b: []const f32,
    // Mel filterbank (stored in file)
    mel_filters: []const f32,
    mel_n: u32,
    mel_f: u32,
    // Vocab
    vocab: [][]const u8,

    pub fn load(path: []const u8, alloc: Allocator) !WhisperModel {
        const file = try std.Io.Dir.cwd().openFile(compat.io(), path, .{});
        defer file.close(compat.io());

        const magic = try readU32(file);
        if (magic != 0x67676d6c) return error.BadFormat;

        const config = WhisperConfig{
            .n_vocab = try readU32(file),
            .n_audio_ctx = try readU32(file),
            .n_audio_state = try readU32(file),
            .n_audio_head = try readU32(file),
            .n_audio_layer = try readU32(file),
            .n_text_ctx = try readU32(file),
            .n_text_state = try readU32(file),
            .n_text_head = try readU32(file),
            .n_text_layer = try readU32(file),
            .n_mels = try readU32(file),
            .ftype = try readU32(file),
        };

        // Mel filters
        const mel_n = try readU32(file);
        const mel_f = try readU32(file);
        const mel_filters = try alloc.alloc(f32, mel_n * mel_f);
        try readExact(file, std.mem.sliceAsBytes(mel_filters));

        // Vocab
        const n_vocab_tok = try readU32(file);
        const vocab = try alloc.alloc([]const u8, n_vocab_tok);
        for (0..n_vocab_tok) |i| {
            const tok_len = try readU32(file);
            const tok = try alloc.alloc(u8, tok_len);
            try readExact(file, tok);
            vocab[i] = tok;
        }

        // Read all tensors into map
        var tensors = std.StringHashMap(TensorData).init(alloc);
        while (true) {
            const n_dims = readU32(file) catch break;
            if (n_dims == 0 or n_dims > 4) break;
            const name_len = try readU32(file);
            const dtype = try readU32(file);
            var n_elems: usize = 1;
            for (0..n_dims) |_| {
                const dim = try readU32(file);
                n_elems *= dim;
            }
            const name_buf = try alloc.alloc(u8, name_len);
            try readExact(file, name_buf);
            const bpe: usize = if (dtype == 0) 4 else 2;
            const data = try alloc.alloc(u8, n_elems * bpe);
            try readExact(file, data);
            try tensors.put(name_buf, .{ .data = data, .n_elems = n_elems, .dtype = dtype });
        }

        // Build encoder layers
        var enc_layers = try alloc.alloc(EncLayer, config.n_audio_layer);
        var nb: [80]u8 = undefined;
        for (0..config.n_audio_layer) |i| {
            enc_layers[i] = .{
                .attn_ln_w = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.attn_ln.weight", .{i})),
                .attn_ln_b = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.attn_ln.bias", .{i})),
                .attn_q_w = f16T(&tensors, nf(&nb, "encoder.blocks.{d}.attn.query.weight", .{i})),
                .attn_q_b = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.attn.query.bias", .{i})),
                .attn_k_w = f16T(&tensors, nf(&nb, "encoder.blocks.{d}.attn.key.weight", .{i})),
                .attn_v_w = f16T(&tensors, nf(&nb, "encoder.blocks.{d}.attn.value.weight", .{i})),
                .attn_v_b = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.attn.value.bias", .{i})),
                .attn_out_w = f16T(&tensors, nf(&nb, "encoder.blocks.{d}.attn.out.weight", .{i})),
                .attn_out_b = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.attn.out.bias", .{i})),
                .mlp_ln_w = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.mlp_ln.weight", .{i})),
                .mlp_ln_b = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.mlp_ln.bias", .{i})),
                .mlp_0_w = f16T(&tensors, nf(&nb, "encoder.blocks.{d}.mlp.0.weight", .{i})),
                .mlp_0_b = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.mlp.0.bias", .{i})),
                .mlp_2_w = f16T(&tensors, nf(&nb, "encoder.blocks.{d}.mlp.2.weight", .{i})),
                .mlp_2_b = f32T(&tensors, nf(&nb, "encoder.blocks.{d}.mlp.2.bias", .{i})),
            };
        }

        // Build decoder layers
        var dec_layers = try alloc.alloc(DecLayer, config.n_text_layer);
        for (0..config.n_text_layer) |i| {
            dec_layers[i] = .{
                .attn_ln_w = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.attn_ln.weight", .{i})),
                .attn_ln_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.attn_ln.bias", .{i})),
                .attn_q_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.attn.query.weight", .{i})),
                .attn_q_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.attn.query.bias", .{i})),
                .attn_k_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.attn.key.weight", .{i})),
                .attn_v_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.attn.value.weight", .{i})),
                .attn_v_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.attn.value.bias", .{i})),
                .attn_out_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.attn.out.weight", .{i})),
                .attn_out_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.attn.out.bias", .{i})),
                .cross_attn_ln_w = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn_ln.weight", .{i})),
                .cross_attn_ln_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn_ln.bias", .{i})),
                .cross_q_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn.query.weight", .{i})),
                .cross_q_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn.query.bias", .{i})),
                .cross_k_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn.key.weight", .{i})),
                .cross_v_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn.value.weight", .{i})),
                .cross_v_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn.value.bias", .{i})),
                .cross_out_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn.out.weight", .{i})),
                .cross_out_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.cross_attn.out.bias", .{i})),
                .mlp_ln_w = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.mlp_ln.weight", .{i})),
                .mlp_ln_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.mlp_ln.bias", .{i})),
                .mlp_0_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.mlp.0.weight", .{i})),
                .mlp_0_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.mlp.0.bias", .{i})),
                .mlp_2_w = f16T(&tensors, nf(&nb, "decoder.blocks.{d}.mlp.2.weight", .{i})),
                .mlp_2_b = f32T(&tensors, nf(&nb, "decoder.blocks.{d}.mlp.2.bias", .{i})),
            };
        }

        return .{
            .config = config,
            .enc_conv1_w = f16T(&tensors, "encoder.conv1.weight"),
            .enc_conv1_b = f32T(&tensors, "encoder.conv1.bias"),
            .enc_conv2_w = f16T(&tensors, "encoder.conv2.weight"),
            .enc_conv2_b = f32T(&tensors, "encoder.conv2.bias"),
            .enc_pos_emb = f32T(&tensors, "encoder.positional_embedding"),
            .enc_layers = enc_layers,
            .enc_ln_w = f32T(&tensors, "encoder.ln_post.weight"),
            .enc_ln_b = f32T(&tensors, "encoder.ln_post.bias"),
            .dec_token_emb = f16T(&tensors, "decoder.token_embedding.weight"),
            .dec_pos_emb = f32T(&tensors, "decoder.positional_embedding"),
            .dec_layers = dec_layers,
            .dec_ln_w = f32T(&tensors, "decoder.ln.weight"),
            .dec_ln_b = f32T(&tensors, "decoder.ln.bias"),
            .mel_filters = mel_filters,
            .mel_n = mel_n,
            .mel_f = mel_f,
            .vocab = vocab,
        };
    }

    /// Full ASR: raw PCM samples → transcribed text.
    /// Caller owns returned slice.
    pub fn transcribe(self: *const WhisperModel, alloc: Allocator, samples: []const i16) ![]u8 {
        const d = self.config.n_audio_state;

        // 1. Mel spectrogram using model's own filterbank
        const mel = try self.computeMel(alloc, samples);
        defer alloc.free(mel.frames);
        const n_frames = mel.n_frames;

        // 2. Encoder forward pass
        const enc_out = try self.runEncoder(alloc, mel.frames, n_frames);
        defer alloc.free(enc_out); // decoder needs it until generation is done

        const enc_seq_len = @min((n_frames + 1) / 2, 1500);

        // 3. Pre-compute cross-attention K/V (once per audio)
        const cross_kv = try self.precomputeCrossKV(alloc, enc_out, enc_seq_len);
        defer alloc.free(cross_kv.k);
        defer alloc.free(cross_kv.v);

        // 4. Decoder: greedy autoregressive generation
        var tokens: [MAX_TOKENS + 4]u32 = undefined;
        tokens[0] = SOT;
        tokens[1] = LANG_EN;
        tokens[2] = TRANSCRIBE;
        tokens[3] = NO_TIMESTAMPS;
        var n_tokens: usize = 4;

        // KV cache for self-attention
        const n_layers = self.config.n_text_layer;
        const self_k_cache = try alloc.alloc(f32, n_layers * 448 * d);
        defer alloc.free(self_k_cache);
        const self_v_cache = try alloc.alloc(f32, n_layers * 448 * d);
        defer alloc.free(self_v_cache);
        @memset(self_k_cache, 0);
        @memset(self_v_cache, 0);

        // Scratch buffers
        const x = try alloc.alloc(f32, d);
        defer alloc.free(x);
        const work = try alloc.alloc(f32, d);
        defer alloc.free(work);
        const q = try alloc.alloc(f32, d);
        defer alloc.free(q);
        const ffn_buf = try alloc.alloc(f32, d * 4);
        defer alloc.free(ffn_buf);
        const logits = try alloc.alloc(f32, self.config.n_vocab);
        defer alloc.free(logits);

        // Prefill prompt tokens (SOT, EN, TRANSCRIBE, NOTIMESTAMPS)
        for (0..4) |ti| {
            self.decoderStep(x, work, q, ffn_buf, &tokens, ti, n_tokens,
                self_k_cache, self_v_cache, cross_kv, enc_seq_len);
        }

        // Generate
        while (n_tokens < MAX_TOKENS + 4) {
            self.decoderStep(x, work, q, ffn_buf, &tokens, n_tokens - 1, n_tokens,
                self_k_cache, self_v_cache, cross_kv, enc_seq_len);

            // Logits: x @ token_emb^T (tied weights)
            // token_emb is [d, n_vocab] in whisper GGML = each column is a token
            for (0..self.config.n_vocab) |v| {
                logits[v] = math.dotF16(self.dec_token_emb[v * d ..][0..d], x);
            }

            // Greedy argmax
            var best: u32 = 0;
            var best_val: f32 = logits[0];
            for (1..self.config.n_vocab) |v| {
                if (logits[v] > best_val) {
                    best_val = logits[v];
                    best = @intCast(v);
                }
            }

            tokens[n_tokens] = best;
            n_tokens += 1;
            if (best == EOT) break;
        }

        // Decode tokens to text
        var text: std.ArrayList(u8) = .empty;
        for (tokens[4..n_tokens]) |tok| {
            if (tok == EOT) break;
            if (tok >= self.vocab.len) continue;
            const word = self.vocab[tok];
            text.appendSlice(alloc, word) catch break;
        }
        return text.toOwnedSlice(alloc) catch return error.OutOfMemory;
    }

    /// One decoder step at position `pos`.
    fn decoderStep(
        self: *const WhisperModel,
        x: []f32,
        work: []f32,
        q_buf: []f32,
        ffn_buf: []f32,
        tokens: []const u32,
        pos: usize,
        n_tokens: usize,
        self_k_cache: []f32,
        self_v_cache: []f32,
        cross_kv: CrossKV,
        enc_seq_len: usize,
    ) void {
        const d = self.config.n_audio_state;
        const n_heads = self.config.n_text_head;
        const head_dim = d / n_heads;
        const ffn_dim = d * 4;
        const n_layers = self.config.n_text_layer;
        _ = n_tokens;

        // Token embedding + positional embedding
        const tok = tokens[pos];
        // dec_token_emb: [d, n_vocab] — column-major in GGML
        for (0..d) |j| {
            x[j] = @as(f32, @floatCast(self.dec_token_emb[tok * d + j])) +
                self.dec_pos_emb[j * 448 + pos];
        }

        for (0..n_layers) |li| {
            const layer = &self.dec_layers[li];
            const cache_off = li * 448 * d;

            // ── Self-attention (causal) ──
            math.layerNorm(work, x, layer.attn_ln_w, layer.attn_ln_b, 1e-5);

            // Q for current position
            mv16(q_buf, layer.attn_q_w, work, d, d);
            addBias(q_buf, layer.attn_q_b);

            // K, V for current position → cache
            mv16(self_k_cache[cache_off + pos * d ..][0..d], layer.attn_k_w, work, d, d);
            mv16(self_v_cache[cache_off + pos * d ..][0..d], layer.attn_v_w, work, d, d);
            addBias(self_v_cache[cache_off + pos * d ..][0..d], layer.attn_v_b);

            // Attend to positions 0..pos+1 (causal)
            const scale = 1.0 / std.math.sqrt(@as(f32, @floatFromInt(head_dim)));
            for (0..n_heads) |h| {
                var attn: [448]f32 = undefined;
                for (0..pos + 1) |kj| {
                    var dot: f32 = 0;
                    for (0..head_dim) |hd| {
                        dot += q_buf[h * head_dim + hd] *
                            self_k_cache[cache_off + kj * d + h * head_dim + hd];
                    }
                    attn[kj] = dot * scale;
                }
                math.softMax(attn[0 .. pos + 1]);
                for (0..head_dim) |hd| {
                    var sum: f32 = 0;
                    for (0..pos + 1) |vj| {
                        sum += attn[vj] * self_v_cache[cache_off + vj * d + h * head_dim + hd];
                    }
                    work[h * head_dim + hd] = sum;
                }
            }

            // Output projection + residual
            mv16(q_buf, layer.attn_out_w, work, d, d);
            addBias(q_buf, layer.attn_out_b);
            for (0..d) |j| x[j] += q_buf[j];

            // ── Cross-attention (to encoder) ──
            math.layerNorm(work, x, layer.cross_attn_ln_w, layer.cross_attn_ln_b, 1e-5);

            // Q from decoder state
            mv16(q_buf, layer.cross_q_w, work, d, d);
            addBias(q_buf, layer.cross_q_b);

            // K, V pre-computed from encoder output
            const cross_k = cross_kv.k[li * enc_seq_len * d ..];
            const cross_v = cross_kv.v[li * enc_seq_len * d ..];

            for (0..n_heads) |h| {
                var attn: [1500]f32 = undefined;
                for (0..enc_seq_len) |kj| {
                    var dot: f32 = 0;
                    for (0..head_dim) |hd| {
                        dot += q_buf[h * head_dim + hd] *
                            cross_k[kj * d + h * head_dim + hd];
                    }
                    attn[kj] = dot * scale;
                }
                math.softMax(attn[0..enc_seq_len]);
                for (0..head_dim) |hd| {
                    var sum: f32 = 0;
                    for (0..enc_seq_len) |vj| {
                        sum += attn[vj] * cross_v[vj * d + h * head_dim + hd];
                    }
                    work[h * head_dim + hd] = sum;
                }
            }

            mv16(q_buf, layer.cross_out_w, work, d, d);
            addBias(q_buf, layer.cross_out_b);
            for (0..d) |j| x[j] += q_buf[j];

            // ── MLP ──
            math.layerNorm(work, x, layer.mlp_ln_w, layer.mlp_ln_b, 1e-5);
            mv16(ffn_buf[0..ffn_dim], layer.mlp_0_w, work, ffn_dim, d);
            addBias(ffn_buf[0..ffn_dim], layer.mlp_0_b);
            math.gelu(ffn_buf[0..ffn_dim]);
            mv16(work, layer.mlp_2_w, ffn_buf[0..ffn_dim], d, ffn_dim);
            addBias(work, layer.mlp_2_b);
            for (0..d) |j| x[j] += work[j];
        }

        // Final LayerNorm
        math.layerNorm(x, x, self.dec_ln_w, self.dec_ln_b, 1e-5);
    }

    /// Pre-compute cross-attention K/V from encoder output (once per audio).
    fn precomputeCrossKV(self: *const WhisperModel, alloc: Allocator, enc_out: []const f32, enc_seq_len: usize) !CrossKV {
        const d = self.config.n_audio_state;
        const n_layers = self.config.n_text_layer;
        const k = try alloc.alloc(f32, n_layers * enc_seq_len * d);
        const v = try alloc.alloc(f32, n_layers * enc_seq_len * d);

        for (0..n_layers) |li| {
            const layer = &self.dec_layers[li];
            for (0..enc_seq_len) |t| {
                const src = enc_out[t * d ..][0..d];
                mv16(k[li * enc_seq_len * d + t * d ..][0..d], layer.cross_k_w, src, d, d);
                mv16(v[li * enc_seq_len * d + t * d ..][0..d], layer.cross_v_w, src, d, d);
                addBias(v[li * enc_seq_len * d + t * d ..][0..d], layer.cross_v_b);
            }
        }

        return .{ .k = k, .v = v };
    }

    /// Encoder forward pass.
    fn runEncoder(self: *const WhisperModel, alloc: Allocator, mel_frames: []const f32, n_frames: usize) ![]f32 {
        const d = self.config.n_audio_state;
        const n_heads = self.config.n_audio_head;
        const head_dim = d / n_heads;
        const ffn_dim = d * 4;

        // Conv1: [80, n_frames] → [d, n_frames], kernel=3, stride=1, pad=1
        const t1 = n_frames;
        const conv1_out = try alloc.alloc(f32, t1 * d);
        defer alloc.free(conv1_out);
        whisperConv1d(conv1_out, mel_frames, self.enc_conv1_w, self.enc_conv1_b, n_frames, 80, d, 3, 1);
        math.gelu(conv1_out);

        // Conv2: stride=2 → halves time
        const t2 = (t1 + 1) / 2;
        const conv2_out = try alloc.alloc(f32, t2 * d);
        defer alloc.free(conv2_out);
        whisperConv1d(conv2_out, conv1_out, self.enc_conv2_w, self.enc_conv2_b, t1, d, d, 3, 2);
        math.gelu(conv2_out);

        const seq_len = @min(t2, 1500);

        // x = conv_out + pos_emb (pos_emb is [d, 1500] column-major)
        var x = try alloc.alloc(f32, seq_len * d);
        for (0..seq_len) |t| {
            for (0..d) |j| {
                x[t * d + j] = conv2_out[t * d + j] + self.enc_pos_emb[j * 1500 + t];
            }
        }

        var work = try alloc.alloc(f32, seq_len * d);
        defer alloc.free(work);
        var q_buf = try alloc.alloc(f32, seq_len * d);
        defer alloc.free(q_buf);
        var k_buf = try alloc.alloc(f32, seq_len * d);
        defer alloc.free(k_buf);
        var v_buf = try alloc.alloc(f32, seq_len * d);
        defer alloc.free(v_buf);
        var ffn_out = try alloc.alloc(f32, seq_len * ffn_dim);
        defer alloc.free(ffn_out);

        for (self.enc_layers) |*layer| {
            // LayerNorm → self-attention → residual
            for (0..seq_len) |t| math.layerNorm(work[t * d ..][0..d], x[t * d ..][0..d], layer.attn_ln_w, layer.attn_ln_b, 1e-5);
            for (0..seq_len) |t| {
                mv16(q_buf[t * d ..][0..d], layer.attn_q_w, work[t * d ..][0..d], d, d);
                addBias(q_buf[t * d ..][0..d], layer.attn_q_b);
                mv16(k_buf[t * d ..][0..d], layer.attn_k_w, work[t * d ..][0..d], d, d);
                mv16(v_buf[t * d ..][0..d], layer.attn_v_w, work[t * d ..][0..d], d, d);
                addBias(v_buf[t * d ..][0..d], layer.attn_v_b);
            }

            const scale = 1.0 / std.math.sqrt(@as(f32, @floatFromInt(head_dim)));
            for (0..n_heads) |h| {
                for (0..seq_len) |qi| {
                    var attn: [1500]f32 = undefined;
                    for (0..seq_len) |kj| {
                        var dot: f32 = 0;
                        for (0..head_dim) |hd| {
                            dot += q_buf[qi * d + h * head_dim + hd] * k_buf[kj * d + h * head_dim + hd];
                        }
                        attn[kj] = dot * scale;
                    }
                    math.softMax(attn[0..seq_len]);
                    for (0..head_dim) |hd| {
                        var sum: f32 = 0;
                        for (0..seq_len) |vj| sum += attn[vj] * v_buf[vj * d + h * head_dim + hd];
                        work[qi * d + h * head_dim + hd] = sum;
                    }
                }
            }

            for (0..seq_len) |t| {
                var out_vec: [1536]f32 = undefined;
                mv16(out_vec[0..d], layer.attn_out_w, work[t * d ..][0..d], d, d);
                addBias(out_vec[0..d], layer.attn_out_b);
                for (0..d) |j| x[t * d + j] += out_vec[j];
            }

            // LayerNorm → MLP → residual
            for (0..seq_len) |t| math.layerNorm(work[t * d ..][0..d], x[t * d ..][0..d], layer.mlp_ln_w, layer.mlp_ln_b, 1e-5);
            for (0..seq_len) |t| {
                mv16(ffn_out[t * ffn_dim ..][0..ffn_dim], layer.mlp_0_w, work[t * d ..][0..d], ffn_dim, d);
                addBias(ffn_out[t * ffn_dim ..][0..ffn_dim], layer.mlp_0_b);
                math.gelu(ffn_out[t * ffn_dim ..][0..ffn_dim]);
                var down: [1536]f32 = undefined;
                mv16(down[0..d], layer.mlp_2_w, ffn_out[t * ffn_dim ..][0..ffn_dim], d, ffn_dim);
                addBias(down[0..d], layer.mlp_2_b);
                for (0..d) |j| x[t * d + j] += down[j];
            }
        }

        // Final norm
        for (0..seq_len) |t| math.layerNorm(x[t * d ..][0..d], x[t * d ..][0..d], self.enc_ln_w, self.enc_ln_b, 1e-5);

        return x;
    }

    /// Compute mel spectrogram using model's filterbank.
    fn computeMel(self: *const WhisperModel, alloc: Allocator, samples: []const i16) !struct { frames: []f32, n_frames: usize } {
        // Convert i16 → f32
        const f_samples = try alloc.alloc(f32, samples.len);
        defer alloc.free(f_samples);
        for (0..samples.len) |i| f_samples[i] = @as(f32, @floatFromInt(samples[i])) / 32768.0;

        // FFT params (whisper standard)
        const n_fft = 400;
        const hop = 160;
        const n_mels = self.config.n_mels;
        const n_fft_bins = n_fft / 2 + 1; // 201

        if (f_samples.len < n_fft) return .{ .frames = try alloc.alloc(f32, 0), .n_frames = 0 };
        const n_frames = (f_samples.len - n_fft) / hop + 1;

        // Hann window
        var window: [400]f32 = undefined;
        for (0..n_fft) |n| {
            const phase = 2.0 * std.math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(n_fft - 1));
            window[n] = 0.5 * (1.0 - @cos(phase));
        }

        const frames = try alloc.alloc(f32, n_frames * n_mels);

        // Process each frame
        var fft_re: [512]f32 = undefined;
        var fft_im: [512]f32 = undefined;
        var power: [201]f32 = undefined;

        for (0..n_frames) |fi| {
            // Window + zero-pad to 512
            @memset(&fft_re, 0);
            @memset(&fft_im, 0);
            for (0..n_fft) |n| fft_re[n] = f_samples[fi * hop + n] * window[n];

            // FFT
            fft512(&fft_re, &fft_im);

            // Power spectrum
            for (0..n_fft_bins) |k| power[k] = fft_re[k] * fft_re[k] + fft_im[k] * fft_im[k];

            // Apply mel filterbank (stored as [n_mels, n_fft_bins] in GGML)
            for (0..n_mels) |m| {
                var sum: f32 = 0;
                const fb = self.mel_filters[m * self.mel_f ..][0..n_fft_bins];
                for (0..n_fft_bins) |k| sum += fb[k] * power[k];
                frames[fi * n_mels + m] = @log(@max(sum, 1e-10));
            }
        }

        // Normalize: clamp max, scale to [-1, 1]
        var max_val: f32 = frames[0];
        for (frames) |v| max_val = @max(max_val, v);
        for (frames) |*v| {
            v.* = @max(v.*, max_val - 8.0); // clamp floor
            v.* = (v.* + 4.0) / 4.0; // rough normalization to [-1, 1]
        }

        return .{ .frames = frames, .n_frames = n_frames };
    }
};

const CrossKV = struct {
    k: []f32,
    v: []f32,
};

// ── Helpers ──

fn readU32(file: std.Io.File) !u32 {
    var buf: [4]u8 = undefined;
    try readExact(file, &buf);
    return std.mem.readInt(u32, &buf, .little);
}

fn readExact(file: std.Io.File, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.readStreaming(compat.io(), &.{buf[total..]});
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

const TensorData = struct {
    data: []u8,
    n_elems: usize,
    dtype: u32,
};

fn nf(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "";
}

fn f32T(tensors: *std.StringHashMap(TensorData), name: []const u8) []const f32 {
    const t = tensors.get(name) orelse @panic("missing tensor");
    return @as([*]const f32, @ptrCast(@alignCast(t.data.ptr)))[0..t.n_elems];
}

fn f16T(tensors: *std.StringHashMap(TensorData), name: []const u8) []const f16 {
    const t = tensors.get(name) orelse @panic("missing tensor");
    return @as([*]const f16, @ptrCast(@alignCast(t.data.ptr)))[0..t.n_elems];
}

fn mv16(out: []f32, w: []const f16, x: []const f32, rows: usize, cols: usize) void {
    const ctx = math.F16MatmulCtx{ .data = w, .x = x, .cols = cols };
    for (0..rows) |i| out[i] = ctx.computeRow(i);
}

fn addBias(x: []f32, bias: []const f32) void {
    for (0..x.len) |i| x[i] += bias[i];
}

/// Whisper Conv1D: weight [kernel, in_ch, out_ch], padding = (kernel-1)/2
fn whisperConv1d(out: []f32, input: []const f32, weight: []const f16, bias: []const f32, in_len: usize, in_ch: usize, out_ch: usize, kernel: usize, stride: usize) void {
    const pad = (kernel - 1) / 2;
    const out_len = (in_len + 2 * pad - kernel) / stride + 1;
    for (0..out_len) |t| {
        for (0..out_ch) |oc| {
            var sum: f32 = bias[oc];
            for (0..kernel) |k| {
                const in_t_s = t * stride + k;
                if (in_t_s < pad or in_t_s >= in_len + pad) continue;
                const in_t = in_t_s - pad;
                for (0..in_ch) |ic| {
                    sum += @as(f32, @floatCast(weight[k * in_ch * out_ch + ic * out_ch + oc])) * input[in_t * in_ch + ic];
                }
            }
            out[t * out_ch + oc] = sum;
        }
    }
}

/// In-place radix-2 FFT, N=512.
fn fft512(re: *[512]f32, im: *[512]f32) void {
    const N = 512;
    const LOG2_N = 9;
    // Bit-reversal
    for (0..N) |i| {
        var rev: u32 = 0;
        var val: u32 = @intCast(i);
        for (0..LOG2_N) |_| {
            rev = (rev << 1) | (val & 1);
            val >>= 1;
        }
        if (i < rev) {
            std.mem.swap(f32, &re[i], &re[rev]);
            std.mem.swap(f32, &im[i], &im[rev]);
        }
    }
    // Butterfly
    var half: usize = 1;
    for (0..LOG2_N) |_| {
        const step = half * 2;
        const angle_step = -std.math.pi / @as(f32, @floatFromInt(half));
        var j: usize = 0;
        while (j < N) : (j += step) {
            for (0..half) |k| {
                const angle = angle_step * @as(f32, @floatFromInt(k));
                const wr = @cos(angle);
                const wi = @sin(angle);
                const a = j + k;
                const b = a + half;
                const tre = wr * re[b] - wi * im[b];
                const tim = wr * im[b] + wi * re[b];
                re[b] = re[a] - tre;
                im[b] = im[a] - tim;
                re[a] += tre;
                im[a] += tim;
            }
        }
        half = step;
    }
}
