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
    /// Handles BPE space markers: Ġ (GPT-2/Qwen, U+0120 = \xc4\xa0) and ▁ (SentencePiece, U+2581 = \xe2\x96\x81)
    pub fn decodeAll(self: *const Tokenizer, tokens: []const Token, alloc: Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .{};
        for (tokens) |tok| {
            if (self.decode(tok)) |s| {
                var i: usize = 0;
                while (i < s.len) {
                    // GPT-2/Qwen BPE: Ġ (U+0120 = 0xc4 0xa0) -> space
                    if (i + 1 < s.len and s[i] == 0xc4 and s[i + 1] == 0xa0) {
                        result.append(alloc, ' ') catch {};
                        i += 2;
                        continue;
                    }
                    // SentencePiece: ▁ (U+2581 = 0xe2 0x96 0x81) -> space
                    if (i + 2 < s.len and s[i] == 0xe2 and s[i + 1] == 0x96 and s[i + 2] == 0x81) {
                        result.append(alloc, ' ') catch {};
                        i += 3;
                        continue;
                    }
                    // GPT-2 byte-level BPE: Ā-ÿ range (U+0100-U+01FF) encodes raw bytes
                    // First byte 0xc4 (U+0100-U+013F) or 0xc5 (U+0140-U+017F) etc.
                    if (i + 1 < s.len and s[i] >= 0xc4 and s[i] <= 0xc7) {
                        // Decode 2-byte UTF-8 to codepoint, then extract byte value
                        const cp: u16 = (@as(u16, s[i] & 0x1f) << 6) | @as(u16, s[i + 1] & 0x3f);
                        if (cp >= 0x100 and cp <= 0x1ff) {
                            // This is a byte-level token: codepoint 0x100+N encodes byte N
                            result.append(alloc, @intCast(cp - 0x100)) catch {};
                            i += 2;
                            continue;
                        }
                    }
                    result.append(alloc, s[i]) catch {};
                    i += 1;
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

    /// tiktoken-compatible BPE encoding.
    /// Uses scores as ranks: repeatedly merge the adjacent pair whose
    /// concatenation has the lowest rank (score) in the vocabulary.
    fn encodeBPE(self: *const Tokenizer, text: []const u8, tokens: *std.ArrayList(Token), alloc: Allocator) !void {
        if (text.len == 0) return;

        // Start with individual bytes — each byte maps to token 0-255
        // (tiktoken's first 256 ranks are individual bytes)
        const Piece = struct { start: u16, len: u16 };
        var pieces = try alloc.alloc(Piece, text.len);
        defer alloc.free(pieces);
        var n_pieces: usize = text.len;
        for (0..text.len) |i| {
            pieces[i] = .{ .start = @intCast(i), .len = 1 };
        }

        // Iteratively merge the pair with lowest rank
        while (n_pieces >= 2) {
            // Find best pair to merge (lowest rank of concatenation)
            var best_rank: f32 = std.math.inf(f32);
            var best_idx: usize = 0;
            var found = false;

            for (0..n_pieces - 1) |i| {
                // Build concatenated bytes for pieces[i] + pieces[i+1]
                const a_start = pieces[i].start;
                const a_len = pieces[i].len;
                const b_len = pieces[i + 1].len;
                const total_len = a_len + b_len;
                if (total_len > 64) continue; // skip impossibly long merges

                const merged = text[a_start..][0..total_len];
                // Look up rank of merged sequence
                if (self.token_map.get(merged)) |tok| {
                    const rank = self.scores[@intCast(tok)];
                    if (rank < best_rank) {
                        best_rank = rank;
                        best_idx = i;
                        found = true;
                    }
                }
            }

            if (!found) break; // no more merges possible

            // Merge pieces[best_idx] and pieces[best_idx+1]
            pieces[best_idx].len += pieces[best_idx + 1].len;
            // Shift remaining pieces left
            var j = best_idx + 1;
            while (j + 1 < n_pieces) : (j += 1) {
                pieces[j] = pieces[j + 1];
            }
            n_pieces -= 1;
        }

        // Convert pieces to token IDs
        for (0..n_pieces) |i| {
            const piece = text[pieces[i].start..][0..pieces[i].len];
            if (self.token_map.get(piece)) |tok| {
                tokens.append(alloc, tok) catch return error.OutOfMemory;
            }
            // else: unknown piece, skip (shouldn't happen with byte-level base vocab)
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
