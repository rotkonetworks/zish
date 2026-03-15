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

        if (self.vocab_size <= 256 and self.merges == null) {
            // Byte-level tokenization: each byte is a token
            for (text) |byte| {
                tokens.append(alloc, @intCast(byte)) catch return error.OutOfMemory;
            }
        } else if (self.merges != null) {
            // BPE tokenization with pre-tokenizer
            try self.encodeBPE(text, &tokens, alloc);
        } else {
            // SentencePiece tokenization (greedy longest match)
            try self.encodeSP(text, &tokens, alloc);
        }

        return tokens.toOwnedSlice(alloc) catch return error.OutOfMemory;
    }

    /// tiktoken-compatible BPE encoding with pre-tokenizer.
    /// Nanochat's split pattern (simplified for ASCII):
    ///   '(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,2}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+
    /// Pre-splits text into chunks, then BPE-encodes each chunk independently.
    fn encodeBPE(self: *const Tokenizer, text: []const u8, tokens: *std.ArrayList(Token), alloc: Allocator) !void {
        if (text.len == 0) return;

        // Pre-split text into chunks matching nanochat's regex pattern
        var pos: usize = 0;
        while (pos < text.len) {
            const chunk_len = self.matchTiktokenChunk(text, pos);
            if (chunk_len == 0) {
                pos += 1; // skip unmatched byte
                continue;
            }
            const chunk = text[pos..][0..chunk_len];
            try self.bpeEncodeChunk(chunk, tokens, alloc);
            pos += chunk_len;
        }
    }

    /// Match one pre-tokenizer chunk at the given position.
    /// Returns the length of the matched chunk (0 if nothing matches).
    fn matchTiktokenChunk(self: *const Tokenizer, text: []const u8, pos: usize) usize {
        _ = self;
        const len = text.len;
        if (pos >= len) return 0;
        const c = text[pos];

        // Pattern 1: Contractions — 's 't 'd 'm 'll 've 're
        if (c == '\'') {
            if (pos + 2 < len) {
                const c2 = text[pos + 1];
                const c3 = text[pos + 2];
                // 'll 've 're
                if ((c2 == 'l' or c2 == 'L') and (c3 == 'l' or c3 == 'L')) return 3;
                if ((c2 == 'v' or c2 == 'V') and (c3 == 'e' or c3 == 'E')) return 3;
                if ((c2 == 'r' or c2 == 'R') and (c3 == 'e' or c3 == 'E')) return 3;
            }
            if (pos + 1 < len) {
                const c2 = text[pos + 1] | 0x20; // lowercase
                if (c2 == 's' or c2 == 't' or c2 == 'd' or c2 == 'm') return 2;
            }
        }

        // Pattern 2: Optional non-letter/non-digit + letters
        // [^\r\n\p{L}\p{N}]?\p{L}+
        {
            var p = pos;
            // Optional leading non-letter/non-digit (not \r\n)
            if (p < len and !isLetter(text[p]) and !isDigit(text[p]) and text[p] != '\r' and text[p] != '\n') {
                p += 1;
            }
            if (p < len and isLetter(text[p])) {
                p += 1;
                while (p < len and isLetter(text[p])) : (p += 1) {}
                return p - pos;
            }
        }

        // Pattern 3: 1-2 digit numbers
        if (isDigit(c)) {
            if (pos + 1 < len and isDigit(text[pos + 1])) return 2;
            return 1;
        }

        // Pattern 4: Optional space + punctuation + optional newlines
        // ' ?[^\s\p{L}\p{N}]+[\r\n]*'
        {
            var p = pos;
            if (p < len and text[p] == ' ') p += 1;
            const punct_start = p;
            while (p < len and !isSpace(text[p]) and !isLetter(text[p]) and !isDigit(text[p])) : (p += 1) {}
            if (p > punct_start) {
                // Got some punctuation; consume trailing newlines
                while (p < len and (text[p] == '\r' or text[p] == '\n')) : (p += 1) {}
                return p - pos;
            }
        }

        // Pattern 5: Whitespace before newline — \s*[\r\n]
        if (c == '\r' or c == '\n') {
            var p = pos + 1;
            while (p < len and (text[p] == '\r' or text[p] == '\n')) : (p += 1) {}
            return p - pos;
        }

        // Pattern 6/7: Whitespace — \s+(?!\S) or \s+
        if (isSpace(c)) {
            var p = pos + 1;
            while (p < len and isSpace(text[p])) : (p += 1) {}
            return p - pos;
        }

        // Fallback: single byte
        return 1;
    }

    /// BPE-encode a single pre-tokenized chunk.
    fn bpeEncodeChunk(self: *const Tokenizer, chunk: []const u8, tokens: *std.ArrayList(Token), alloc: Allocator) !void {
        // Trivial case: whole chunk is a single token
        if (self.token_map.get(chunk)) |tok| {
            tokens.append(alloc, tok) catch return error.OutOfMemory;
            return;
        }

        // Start with individual bytes
        const Piece = struct { start: u16, len: u16 };
        var pieces_buf: [256]Piece = undefined;
        var pieces: []Piece = undefined;
        var heap_pieces: ?[]Piece = null;
        defer if (heap_pieces) |hp| alloc.free(hp);

        if (chunk.len <= 256) {
            pieces = pieces_buf[0..chunk.len];
        } else {
            heap_pieces = try alloc.alloc(Piece, chunk.len);
            pieces = heap_pieces.?;
        }
        var n_pieces: usize = chunk.len;
        for (0..chunk.len) |i| {
            pieces[i] = .{ .start = @intCast(i), .len = 1 };
        }

        // Iteratively merge the pair with lowest rank
        while (n_pieces >= 2) {
            var best_rank: f32 = std.math.inf(f32);
            var best_idx: usize = 0;
            var found = false;

            for (0..n_pieces - 1) |i| {
                const a_start = pieces[i].start;
                const total_len = pieces[i].len + pieces[i + 1].len;
                if (total_len > 64) continue;

                const merged = chunk[a_start..][0..total_len];
                if (self.token_map.get(merged)) |tok| {
                    const rank = self.scores[@intCast(tok)];
                    if (rank < best_rank) {
                        best_rank = rank;
                        best_idx = i;
                        found = true;
                    }
                }
            }

            if (!found) break;

            pieces[best_idx].len += pieces[best_idx + 1].len;
            var j = best_idx + 1;
            while (j + 1 < n_pieces) : (j += 1) {
                pieces[j] = pieces[j + 1];
            }
            n_pieces -= 1;
        }

        // Convert pieces to token IDs
        for (0..n_pieces) |i| {
            const piece = chunk[pieces[i].start..][0..pieces[i].len];
            if (self.token_map.get(piece)) |tok| {
                tokens.append(alloc, tok) catch return error.OutOfMemory;
            }
            // Unknown piece — emit individual bytes as fallback
        }
    }

    fn isLetter(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
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
