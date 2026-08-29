// history.zig - Secure, high-performance history implementation
// Security-focused design with DoS protection and memory safety

const std = @import("std");
const compat = @import("compat.zig");
const types = @import("types.zig");
const crypto_mod = @import("crypto.zig");
const log_mod = @import("history_log.zig");

const CryptoContext = crypto_mod.CryptoContext;
const LogWriter = log_mod.LogWriter;
const LogReader = log_mod.LogReader;

// Security constants - prevent DoS attacks
const MAX_COMMAND_LENGTH = types.MAX_COMMAND_LENGTH; // Use consistent limit from types
const MAX_HISTORY_ENTRIES = 10000; // Hard limit to prevent memory exhaustion
const DEFAULT_CAPACITY = 1000; // Default size
const STRING_POOL_SIZE = 256 * 1024; // 256KB string pool for cache efficiency

const HistoryEntry = struct {
    command_hash: u64, // For fast deduplication
    command_offset: u32, // Offset into string pool (cache-friendly)
    command_len: u16, // Command length
    frequency: u16, // Usage count for ranking
    timestamp: u32, // When command was last used
    exit_code: u8,
    flags: u8, // Success flag, etc.

    const SUCCESSFUL_FLAG: u8 = 1;

    pub fn isSuccessful(self: HistoryEntry) bool {
        return (self.flags & SUCCESSFUL_FLAG) != 0;
    }
};

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(HistoryEntry),
    string_pool: []u8, // Contiguous string storage for cache efficiency
    string_pool_used: usize,
    hash_map: std.HashMap(u64, u32, std.hash_map.AutoContext(u64), 80), // For O(1) deduplication
    // encrypted persistence
    crypto: *CryptoContext,
    log_writer: LogWriter,
    log_offset: u64, // file position after last read
    dirty: bool, // needs save

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, _: ?[]const u8) !*Self {
        const history = try allocator.create(Self);
        errdefer allocator.destroy(history);

        // Pre-allocate for performance and predictable memory usage
        var entries = try std.ArrayList(HistoryEntry).initCapacity(allocator, DEFAULT_CAPACITY);
        errdefer entries.deinit(allocator);

        const string_pool = try allocator.alloc(u8, STRING_POOL_SIZE);
        errdefer allocator.free(string_pool);

        var hash_map = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), 80).init(allocator);
        errdefer hash_map.deinit();
        try hash_map.ensureTotalCapacity(DEFAULT_CAPACITY);

        // init crypto (allocate on heap so pointer stays valid)
        const crypto = try allocator.create(CryptoContext);
        errdefer allocator.destroy(crypto);
        crypto.* = try CryptoContext.init(allocator);
        errdefer crypto.deinit();

        // init log writer
        var log_writer = try LogWriter.init(allocator, crypto);
        errdefer log_writer.deinit();

        history.* = .{
            .allocator = allocator,
            .entries = entries,
            .string_pool = string_pool,
            .string_pool_used = 0,
            .hash_map = hash_map,
            .crypto = crypto,
            .log_writer = log_writer,
            .log_offset = 0,
            .dirty = false,
        };

        // load encrypted history from disk
        history.load() catch |err| {
            std.log.warn("failed to load encrypted history: {}", .{err});
        };

        return history;
    }

    pub fn deinit(self: *Self) void {
        // save any pending changes
        self.save() catch |err| {
            std.log.warn("failed to save history on exit: {}", .{err});
        };

        self.log_writer.deinit();
        self.crypto.deinit();
        self.allocator.destroy(self.crypto);
        self.hash_map.deinit();
        self.entries.deinit(self.allocator);
        self.allocator.free(self.string_pool);
        self.allocator.destroy(self);
    }

    /// Ensure the string pool has room for `needed` more bytes, growing it if
    /// necessary. Commands are referenced by offset (see getCommand), so a
    /// realloc that moves the buffer keeps every stored entry valid. This
    /// replaces the old fixed-256KB pool that returned StringPoolFull once full
    /// — which silently froze history (new + cross-session commands dropped).
    fn ensurePoolSpace(self: *Self, needed: usize) !void {
        if (self.string_pool_used + needed <= self.string_pool.len) return;
        var new_size = self.string_pool.len;
        while (self.string_pool_used + needed > new_size) new_size *|= 2;
        self.string_pool = try self.allocator.realloc(self.string_pool, new_size);
    }

    pub fn addCommand(self: *Self, command: []const u8, exit_code: u8) !void {
        // Security: Input validation
        if (command.len == 0) return;
        if (command.len > MAX_COMMAND_LENGTH) return error.CommandTooLong;
        // The on-disk log stores each record length in a u16 (see history_log
        // EntryData.serialize / LogWriter.append). A command near
        // MAX_COMMAND_LENGTH plus header+crypto overhead overflows that u16 and
        // used to abort the whole shell on save. History is best-effort: skip
        // recording anything too large to encode rather than crash. Margin below
        // 65535 covers the 14-byte header + 40-byte nonce/tag overhead.
        if (command.len > 65000) return;

        // Security: Sanitize command - remove control characters except tab/newline
        if (!isCommandSafe(command)) return error.UnsafeCommand;

        // Calculate hash for deduplication
        const command_hash = std.hash.Wyhash.hash(0, command);

        // Check if command already exists - move to end for recency
        if (self.hash_map.get(command_hash)) |existing_index| {
            var entry = self.entries.items[existing_index];
            entry.frequency = @min(65535, entry.frequency + 1);
            entry.timestamp = @intCast(compat.timestamp());
            entry.exit_code = exit_code;
            entry.flags = if (exit_code == 0) HistoryEntry.SUCCESSFUL_FLAG else 0;

            // move to end: swap with last entry, then update in place
            const last_index: u32 = @intCast(self.entries.items.len - 1);
            if (existing_index != last_index) {
                // swap entries
                const last_entry = self.entries.items[last_index];
                self.entries.items[existing_index] = last_entry;
                self.entries.items[last_index] = entry;

                // update hash_map for swapped entry
                try self.hash_map.put(last_entry.command_hash, existing_index);
                try self.hash_map.put(command_hash, last_index);
            } else {
                // already at end, just update in place
                self.entries.items[last_index] = entry;
            }

            self.dirty = true;
            try self.saveEntry(entry);
            return;
        }

        // Security: Check limits to prevent DoS
        if (self.entries.items.len >= MAX_HISTORY_ENTRIES) {
            try self.evictOldestEntry();
        }

        // Grow the string pool if needed (offsets survive realloc).
        try self.ensurePoolSpace(command.len);

        // Store command in string pool for cache efficiency
        const command_offset: u32 = @intCast(self.string_pool_used);
        @memcpy(self.string_pool[self.string_pool_used..self.string_pool_used + command.len], command);
        self.string_pool_used += command.len;

        const entry = HistoryEntry{
            .command_hash = command_hash,
            .command_offset = command_offset,
            .command_len = @intCast(command.len),
            .frequency = 1,
            .timestamp = @intCast(compat.timestamp()),
            .exit_code = exit_code,
            .flags = if (exit_code == 0) HistoryEntry.SUCCESSFUL_FLAG else 0,
        };

        const entry_index: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, entry);
        try self.hash_map.put(command_hash, entry_index);

        // mark dirty for save
        self.dirty = true;

        // save immediately (append-only, fast)
        try self.saveEntry(entry);
    }

    /// save single entry immediately (append-only)
    fn saveEntry(self: *Self, entry: HistoryEntry) !void {
        const command = self.getCommand(entry);

        const log_entry = log_mod.EntryData{
            .command_hash = entry.command_hash,
            .command = command,
            .exit_code = entry.exit_code,
            .flags = entry.flags,
            .frequency = entry.frequency,
            .timestamp = entry.timestamp,
        };

        try self.log_writer.append(log_entry);
        self.dirty = false; // just saved

        // Do NOT advance log_offset here. Setting it to the current file size
        // skips not only our own entry but any commands OTHER shells appended
        // since our last sync() — so a long-running window permanently loses
        // what was typed in other windows (broken shared history). sync() reads
        // from log_offset and mergeEntry dedups our own entry by hash, so
        // leaving the offset put lets the next sync() re-read from there and
        // pick up every session's writes; it advances log_offset itself.
    }

    /// import new entries written by other sessions since last read
    pub fn sync(self: *Self) void {
        var reader = LogReader.init(self.allocator, self.crypto) catch return;
        defer reader.deinit();

        var end_offset: u64 = 0;
        const new_entries = reader.readFrom(self.log_offset, &end_offset) catch return;
        defer {
            for (new_entries) |entry| {
                self.allocator.free(entry.command);
            }
            self.allocator.free(new_entries);
        }

        if (new_entries.len == 0) {
            self.log_offset = end_offset;
            return;
        }

        for (new_entries) |entry| {
            self.mergeEntry(entry) catch {};
        }

        self.log_offset = end_offset;
        self.sortByTimestamp();
    }

    // Security: Validate that command contains only safe characters
    fn isCommandSafe(command: []const u8) bool {
        for (command) |c| {
            switch (c) {
                // Printable ASCII, tab, newline, and UTF-8 bytes (>= 0x80).
                // Only C0 control characters are rejected (escape-injection
                // into the history display); accented/CJK/emoji commands are
                // valid and must be recorded now that UTF-8 input is accepted.
                32...126, '\t', '\n', 0x80...0xFF => {},
                else => return false, // reject control characters
            }
        }
        return true;
    }

    fn evictOldestEntry(self: *Self) !void {
        if (self.entries.items.len == 0) return;

        // Find oldest entry (could be optimized with a min-heap)
        var oldest_index: usize = 0;
        var oldest_timestamp = self.entries.items[0].timestamp;

        for (self.entries.items, 0..) |entry, i| {
            if (entry.timestamp < oldest_timestamp) {
                oldest_timestamp = entry.timestamp;
                oldest_index = i;
            }
        }

        // Remove from hash map and entries
        const removed_entry = self.entries.orderedRemove(oldest_index);
        _ = self.hash_map.remove(removed_entry.command_hash);

        // Update indices in hash map (they shifted after removal)
        var iterator = self.hash_map.iterator();
        while (iterator.next()) |kv| {
            if (kv.value_ptr.* > oldest_index) {
                kv.value_ptr.* -= 1;
            }
        }
    }

    pub fn getStats(self: *Self) struct { total: usize, unique: usize } {
        return .{
            .total = self.entries.items.len,
            .unique = self.entries.items.len, // All entries are unique due to deduplication
        };
    }

    pub fn getCommand(self: *Self, entry: HistoryEntry) []const u8 {
        const start = entry.command_offset;
        const end = start + entry.command_len;
        return self.string_pool[start..end];
    }

    pub fn fuzzySearch(self: *Self, query: []const u8, allocator: std.mem.Allocator) ![]FuzzyMatch {
        // Security: Validate query
        if (query.len == 0 or query.len > MAX_COMMAND_LENGTH) {
            return try allocator.alloc(FuzzyMatch, 0);
        }
        if (!isCommandSafe(query)) {
            return try allocator.alloc(FuzzyMatch, 0);
        }

        var matches = try std.ArrayList(FuzzyMatch).initCapacity(allocator, 20);

        // Score-based matching with frequency and recency weighting
        for (self.entries.items, 0..) |entry, i| {
            const command = self.getCommand(entry);

            // Simple substring match (could be improved with fuzzy matching)
            if (std.mem.indexOf(u8, command, query)) |_| {
                // Calculate score based on multiple factors
                var score: f32 = 1.0;

                // Frequency bonus (commands used more often rank higher)
                score += @as(f32, @floatFromInt(entry.frequency)) * 0.1;

                // Recency bonus (recent commands rank higher). Saturating: a
                // clock-skewed peer can write a shared-history entry timestamped
                // in the future; plain u32 subtraction would underflow and panic
                // on every Ctrl-R until it ages out.
                const now = @as(u32, @intCast(compat.timestamp()));
                const age = now -| entry.timestamp;
                if (age < 3600) {
                    score += 2.0; // Bonus for commands used in last hour
                } else if (age < 86400) {
                    score += 1.0; // Bonus for commands used today
                }

                // Success bonus (successful commands rank higher)
                if (entry.isSuccessful()) score += 0.5;

                // Exact match bonus
                if (std.mem.eql(u8, command, query)) score += 5.0;

                // Prefix match bonus
                if (std.mem.startsWith(u8, command, query)) score += 2.0;

                try matches.append(allocator, .{
                    .entry_index = @intCast(i),
                    .score = score,
                });
            }
        }

        // Sort by score (highest first)
        std.sort.insertion(FuzzyMatch, matches.items, {}, FuzzyMatch.compareByScore);

        // Limit results to top 10 for performance
        const result_count = @min(matches.items.len, 10);
        matches.shrinkRetainingCapacity(result_count);
        return try matches.toOwnedSlice(allocator);
    }

    /// save all entries to encrypted log
    pub fn save(self: *Self) !void {
        if (!self.dirty) return; // nothing to save

        // write all current entries
        for (self.entries.items) |entry| {
            const command = self.getCommand(entry);

            const log_entry = log_mod.EntryData{
                .command_hash = entry.command_hash,
                .command = command,
                .exit_code = entry.exit_code,
                .flags = entry.flags,
                .frequency = entry.frequency,
                .timestamp = entry.timestamp,
            };

            try self.log_writer.append(log_entry);
        }

        self.dirty = false;
    }

    /// load entries from encrypted log and merge with in-memory
    fn load(self: *Self) !void {
        var reader = try LogReader.init(self.allocator, self.crypto);
        defer reader.deinit();

        var end_offset: u64 = 0;
        const entries = try reader.readAllTracked(&end_offset);
        defer {
            for (entries) |entry| {
                self.allocator.free(entry.command);
            }
            self.allocator.free(entries);
        }

        // merge with in-memory entries (silently skip failures)
        for (entries) |entry| {
            self.mergeEntry(entry) catch {};
        }

        // sort by timestamp to restore chronological order
        self.sortByTimestamp();

        // compact on startup if bloated (>2x unique entries)
        // fast: batch write + single fsync, no per-entry overhead
        if (entries.len > self.entries.items.len * 2) {
            self.compact() catch |err| {
                std.log.warn("failed to compact history log: {}", .{err});
                self.log_offset = end_offset;
            };
        } else {
            self.log_offset = end_offset;
        }
    }

    /// sort entries by timestamp and rebuild hash_map indices
    fn sortByTimestamp(self: *Self) void {
        // O(n log n) heap sort. The previous insertion sort was O(n²) and made
        // interactive startup crawl on large history files (Boot: ~0.37s on a
        // 686 KB log). Heap sort is equivalent for our purpose (equal timestamps
        // have no required order) and keeps the same O(1) memory profile.
        std.sort.heap(HistoryEntry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: HistoryEntry, b: HistoryEntry) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);

        // rebuild hash_map with new indices
        self.hash_map.clearRetainingCapacity();
        for (self.entries.items, 0..) |entry, i| {
            self.hash_map.put(entry.command_hash, @intCast(i)) catch {};
        }
    }

    /// rewrite log file with only current deduplicated entries
    /// single open, batch writes, one fsync, atomic rename
    fn compact(self: *Self) !void {
        const log_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/current.log.enc",
            .{self.log_writer.log_dir},
        );
        defer self.allocator.free(log_path);

        const tmp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/current.log.enc.tmp",
            .{self.log_writer.log_dir},
        );
        defer self.allocator.free(tmp_path);

        // write all entries to temp file in one batch
        const file = try std.Io.Dir.createFileAbsolute(compat.io(), tmp_path, .{ .permissions = .fromMode(0o600) });
        errdefer {
            file.close(compat.io());
            std.Io.Dir.deleteFileAbsolute(compat.io(), tmp_path) catch {};
        }

        var seq: u64 = 0;
        for (self.entries.items) |entry| {
            const command = self.getCommand(entry);

            const log_entry = log_mod.EntryData{
                .command_hash = entry.command_hash,
                .command = command,
                .exit_code = entry.exit_code,
                .flags = entry.flags,
                .frequency = entry.frequency,
                .timestamp = entry.timestamp,
            };

            const plaintext = try log_entry.serialize(self.allocator);
            defer self.allocator.free(plaintext);

            // zero-initialize so implicit extern-struct padding bytes are not
            // undefined stack garbage written to disk
            var header = std.mem.zeroes(log_mod.EntryHeader);
            header.magic = "ZENT".*;
            header.version = 1;
            header.reserved = 0;
            header.entry_len = 0;
            header.instance = self.log_writer.instance_id;
            header.sequence = seq;
            header.timestamp = entry.timestamp;
            header.padding = [_]u8{0} ** 6;

            // AAD from metadata fields (shared owner: EntryHeader.aad())
            const aad_buf = header.aad();

            const encrypted = try self.crypto.encrypt(plaintext, &aad_buf);
            defer self.allocator.free(encrypted);

            header.entry_len = @intCast(encrypted.len);

            try compat.writeAll(file, std.mem.asBytes(&header));
            try compat.writeAll(file, encrypted);
            seq += 1;
        }

        // one fsync, then atomic rename
        try file.sync(compat.io());
        file.close(compat.io());

        try std.Io.Dir.renameAbsolute(tmp_path, log_path, compat.io());

        self.log_writer.sequence = seq;
        self.log_offset = self.getLogFileSize();
    }

    fn getLogFileSize(self: *Self) u64 {
        const log_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/current.log.enc",
            .{self.log_writer.log_dir},
        ) catch return 0;
        defer self.allocator.free(log_path);

        const file = std.Io.Dir.openFileAbsolute(compat.io(), log_path, .{}) catch return 0;
        defer file.close(compat.io());

        const stat = file.stat(compat.io()) catch return 0;
        return stat.size;
    }

    /// re-encrypt all history with a new key
    pub fn reEncryptWithKey(self: *Self, new_key: [32]u8) !void {
        const fs = std.Io.Dir;

        // update crypto context with new key
        self.crypto.key = new_key;

        // get log file path
        const log_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/current.log.enc",
            .{self.log_writer.log_dir},
        );
        defer self.allocator.free(log_path);

        // delete old encrypted log
        fs.deleteFileAbsolute(compat.io(), log_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };

        // reset sequence counter
        self.log_writer.sequence = 0;

        // re-save all entries with new key
        for (self.entries.items) |entry| {
            try self.saveEntry(entry);
        }
    }

    /// merge single entry from disk into memory
    pub fn mergeEntry(self: *Self, disk_entry: log_mod.EntryData) !void {
        const disk_ts: u32 = if (disk_entry.timestamp > 0)
            @intCast(@min(disk_entry.timestamp, std.math.maxInt(u32)))
        else
            @intCast(compat.timestamp());

        // check if exists in memory
        if (self.hash_map.get(disk_entry.command_hash)) |existing_index| {
            // merge: keep highest frequency, newest timestamp, update in place
            var memory_entry = &self.entries.items[existing_index];

            memory_entry.frequency = @max(memory_entry.frequency, disk_entry.frequency);
            memory_entry.timestamp = @max(memory_entry.timestamp, disk_ts);
            memory_entry.flags |= disk_entry.flags;
            memory_entry.exit_code = disk_entry.exit_code;
        } else {
            // add new entry from disk (grow the pool if needed)
            try self.ensurePoolSpace(disk_entry.command.len);

            const command_offset: u32 = @intCast(self.string_pool_used);
            @memcpy(
                self.string_pool[self.string_pool_used .. self.string_pool_used + disk_entry.command.len],
                disk_entry.command,
            );
            self.string_pool_used += disk_entry.command.len;

            const entry = HistoryEntry{
                .command_hash = disk_entry.command_hash,
                .command_offset = command_offset,
                .command_len = @intCast(disk_entry.command.len),
                .frequency = disk_entry.frequency,
                .timestamp = disk_ts,
                .exit_code = disk_entry.exit_code,
                .flags = disk_entry.flags,
            };

            const entry_index: u32 = @intCast(self.entries.items.len);
            try self.entries.append(self.allocator, entry);
            try self.hash_map.put(disk_entry.command_hash, entry_index);
        }
    }
};

pub const FuzzyMatch = struct {
    entry_index: u32,
    score: f32,

    pub fn compareByScore(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
        return a.score > b.score;
    }
};