// BPE Tokenizer for GGUF models
// Handles both SentencePiece (llama) and GPT-style BPE (qwen2) tokenizers
// Token vocabulary and merge rules are loaded from GGUF metadata.

const std = @import("std");
const gguf = @import("gguf.zig");

const Allocator = std.mem.Allocator;

pub const Token = i64;

pub const Tokenizer = struct {
    vocab: [][]const u8,
    scores: []f32,
    vocab_size: usize,
    bos_id: Token,
    eos_id: Token,
    // Merges for BPE
    merges: ?[]MergePair,
    // Token type info
    token_types: ?[]u32,
    // For encoding: token string -> token id
    token_map: std.StringHashMapUnmanaged(Token),

    arena: std.heap.ArenaAllocator,

    const MergePair = struct {
        a: []const u8,
        b: []const u8,
    };

    pub fn initFromGGUF(file: *const gguf.GGUFFile, alloc: Allocator) !Tokenizer {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        // Load vocabulary tokens
        const tokens_val = file.getValue("tokenizer.ggml.tokens") orelse return error.BadFormat;
        const tokens_arr = tokens_val.array.array;
        const vocab_size = tokens_arr.len;

        var vocab = try a.alloc([]const u8, vocab_size);
        for (0..vocab_size) |i| {
            vocab[i] = tokens_arr[i].string.str;
        }

        // Load scores (optional, SentencePiece uses these)
        var scores = try a.alloc(f32, vocab_size);
        if (file.getValue("tokenizer.ggml.scores")) |scores_val| {
            const scores_arr = scores_val.array.array;
            for (0..@min(vocab_size, scores_arr.len)) |i| {
                scores[i] = scores_arr[i].float32;
            }
        } else {
            @memset(scores, 0);
        }

        // Load token types (optional)
        var token_types: ?[]u32 = null;
        if (file.getValue("tokenizer.ggml.token_type")) |tt_val| {
            const tt_arr = tt_val.array.array;
            var types = try a.alloc(u32, tt_arr.len);
            for (0..tt_arr.len) |i| {
                types[i] = @intCast(tt_arr[i].int32);
            }
            token_types = types;
        }

        // Load merges (for BPE tokenizers)
        var merges: ?[]MergePair = null;
        if (file.getValue("tokenizer.ggml.merges")) |merges_val| {
            const merges_arr = merges_val.array.array;
            var merge_list = try a.alloc(MergePair, merges_arr.len);
            for (0..merges_arr.len) |i| {
                const merge_str = merges_arr[i].string.str;
                // Each merge is "tokenA tokenB" separated by space
                if (std.mem.indexOfScalar(u8, merge_str, ' ')) |space_idx| {
                    merge_list[i] = .{
                        .a = merge_str[0..space_idx],
                        .b = merge_str[space_idx + 1 ..],
                    };
                } else {
                    merge_list[i] = .{ .a = merge_str, .b = "" };
                }
            }
            merges = merge_list;
        }

        // Special tokens
        const bos_id: Token = blk: {
            if (file.getU32("tokenizer.ggml.bos_token_id")) |id| break :blk @intCast(id);
            break :blk 1; // default
        };
        const eos_id: Token = blk: {
            if (file.getU32("tokenizer.ggml.eos_token_id")) |id| break :blk @intCast(id);
            break :blk 2; // default
        };

        // Build reverse map: string -> token id
        var token_map: std.StringHashMapUnmanaged(Token) = .{};
        for (0..vocab_size) |i| {
            token_map.put(a, vocab[i], @intCast(i)) catch {};
        }

        return .{
            .vocab = vocab,
            .scores = scores,
            .vocab_size = vocab_size,
            .bos_id = bos_id,
            .eos_id = eos_id,
            .merges = merges,
            .token_types = token_types,
            .token_map = token_map,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.arena.deinit();
    }

    /// Decode a single token to its string representation.
    pub fn decode(self: *const Tokenizer, tok: Token) ?[]const u8 {
        const idx: usize = @intCast(tok);
        if (idx < self.vocab_size) return self.vocab[idx];
        return null;
    }

    /// Decode a sequence of tokens to a string.
    pub fn decodeAll(self: *const Tokenizer, tokens: []const Token, alloc: Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .{};
        for (tokens) |tok| {
            if (self.decode(tok)) |s| {
                // Handle SentencePiece's "▁" (U+2581) -> space mapping
                for (s) |c| {
                    if (c == 0xe2) {
                        // Check for ▁ (0xe2 0x96 0x81)
                        // We'll just pass through for now; proper handling needs look-ahead
                        result.append(alloc, c) catch {};
                    } else {
                        result.append(alloc, c) catch {};
                    }
                }
            }
        }
        return result.toOwnedSlice(alloc) catch return error.OutOfMemory;
    }

    /// Encode text to tokens using BPE or SentencePiece.
    /// For our use case (small classification prompts), a greedy approach works fine.
    pub fn encode(self: *const Tokenizer, text: []const u8, add_bos: bool, alloc: Allocator) ![]Token {
        var tokens: std.ArrayList(Token) = .{};

        if (add_bos) {
            tokens.append(alloc, self.bos_id) catch return error.OutOfMemory;
        }

        if (self.merges != null) {
            // BPE tokenization
            try self.encodeBPE(text, &tokens, alloc);
        } else {
            // SentencePiece tokenization (greedy longest match)
            try self.encodeSP(text, &tokens, alloc);
        }

        return tokens.toOwnedSlice(alloc) catch return error.OutOfMemory;
    }

    /// BPE encoding: start with characters, iteratively merge.
    fn encodeBPE(self: *const Tokenizer, text: []const u8, tokens: *std.ArrayList(Token), alloc: Allocator) !void {
        // Start with byte-level tokens (each byte gets its own token)
        // For GPT-style BPE, look up each byte
        var parts: std.ArrayList([]const u8) = .{};
        defer parts.deinit(alloc);

        // Split into initial tokens (bytes or unicode chars)
        var pos: usize = 0;
        while (pos < text.len) {
            // Try to find the longest matching token from current position
            var best_len: usize = 1;
            var best_tok: ?Token = null;

            // Try decreasing lengths
            const max_look = @min(text.len - pos, 32);
            var try_len = max_look;
            while (try_len >= 1) : (try_len -= 1) {
                const candidate = text[pos..][0..try_len];
                if (self.token_map.get(candidate)) |tok| {
                    best_len = try_len;
                    best_tok = tok;
                    break;
                }
            }

            if (best_tok) |tok| {
                tokens.append(alloc, tok) catch return error.OutOfMemory;
                pos += best_len;
            } else {
                // Fallback: look for byte token like <0xAB>
                var byte_buf: [8]u8 = undefined;
                const byte_str = std.fmt.bufPrint(&byte_buf, "<0x{X:0>2}>", .{text[pos]}) catch unreachable;
                if (self.token_map.get(byte_str)) |tok| {
                    tokens.append(alloc, tok) catch return error.OutOfMemory;
                } else {
                    // Skip unknown byte
                }
                pos += 1;
            }
        }

        // Now apply BPE merges iteratively
        if (self.merges) |merge_list| {
            var changed = true;
            while (changed) {
                changed = false;
                if (tokens.items.len < 2) break;

                // Find the highest-priority merge (lowest merge index)
                var best_merge_idx: usize = merge_list.len;
                var best_pos: usize = 0;

                var i: usize = 0;
                while (i + 1 < tokens.items.len) : (i += 1) {
                    const a_str = self.decode(tokens.items[i]) orelse continue;
                    const b_str = self.decode(tokens.items[i + 1]) orelse continue;

                    // Find this pair in merges
                    for (0..merge_list.len) |mi| {
                        if (mi >= best_merge_idx) break; // can't improve
                        const merge = merge_list[mi];
                        if (std.mem.eql(u8, merge.a, a_str) and std.mem.eql(u8, merge.b, b_str)) {
                            best_merge_idx = mi;
                            best_pos = i;
                            break;
                        }
                    }
                }

                if (best_merge_idx < merge_list.len) {
                    // Merge tokens at best_pos and best_pos+1
                    const merge = merge_list[best_merge_idx];
                    // Find the merged token
                    var merged_buf: [256]u8 = undefined;
                    const merged_len = merge.a.len + merge.b.len;
                    @memcpy(merged_buf[0..merge.a.len], merge.a);
                    @memcpy(merged_buf[merge.a.len..][0..merge.b.len], merge.b);
                    const merged = merged_buf[0..merged_len];

                    if (self.token_map.get(merged)) |merged_tok| {
                        tokens.items[best_pos] = merged_tok;
                        _ = tokens.orderedRemove(best_pos + 1);
                        changed = true;
                    }
                }
            }
        }
    }

    /// SentencePiece-style greedy encoding.
    fn encodeSP(self: *const Tokenizer, text: []const u8, tokens: *std.ArrayList(Token), alloc: Allocator) !void {
        var pos: usize = 0;
        while (pos < text.len) {
            var best_len: usize = 1;
            var best_tok: Token = 0; // unknown
            var best_score: f32 = -std.math.inf(f32);

            const max_look = @min(text.len - pos, 64);
            for (1..max_look + 1) |try_len| {
                const candidate = text[pos..][0..try_len];
                if (self.token_map.get(candidate)) |tok| {
                    const idx: usize = @intCast(tok);
                    if (self.scores[idx] > best_score) {
                        best_score = self.scores[idx];
                        best_tok = tok;
                        best_len = try_len;
                    }
                }
            }

            tokens.append(alloc, best_tok) catch return error.OutOfMemory;
            pos += best_len;
        }
    }
};
