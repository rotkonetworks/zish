// history_log.zig - append-only encrypted log for history persistence
const std = @import("std");
const compat = @import("compat.zig");
const crypto_mod = @import("crypto.zig");
const fs = std.Io.Dir;
const posix = compat.posix;

const CryptoContext = crypto_mod.CryptoContext;

// log entry header (unencrypted, 32 bytes)
const MAGIC = "ZENT"; // zish entry
const VERSION: u8 = 1;

pub const EntryHeader = extern struct {
    magic: [4]u8,
    version: u8,
    reserved: u8,
    entry_len: u16, // length of encrypted data
    instance: u8,
    sequence: u64,
    timestamp: u64,
    padding: [6]u8,

    pub fn validate(self: EntryHeader) !void {
        if (!std.mem.eql(u8, &self.magic, MAGIC)) {
            return error.InvalidMagic;
        }
        if (self.version != VERSION) {
            return error.UnsupportedVersion;
        }
    }
};

// entry data (encrypted)
pub const EntryData = struct {
    command_hash: u64,
    command: []const u8,
    exit_code: u8,
    flags: u8,
    frequency: u16,
    timestamp: u64, // from log header, 0 = not set

    pub fn serialize(self: EntryData, allocator: std.mem.Allocator) ![]u8 {
        // format: hash(8) + cmd_len(2) + cmd + exit(1) + flags(1) + freq(2)
        const total_len = 8 + 2 + self.command.len + 1 + 1 + 2;
        var buf = try allocator.alloc(u8, total_len);
        errdefer allocator.free(buf);

        var pos: usize = 0;

        // hash
        std.mem.writeInt(u64, buf[pos..][0..8], self.command_hash, .little);
        pos += 8;

        // command length
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(self.command.len), .little);
        pos += 2;

        // command
        @memcpy(buf[pos .. pos + self.command.len], self.command);
        pos += self.command.len;

        // exit code
        buf[pos] = self.exit_code;
        pos += 1;

        // flags
        buf[pos] = self.flags;
        pos += 1;

        // frequency
        std.mem.writeInt(u16, buf[pos..][0..2], self.frequency, .little);

        return buf;
    }

    fn deserialize(data: []const u8, allocator: std.mem.Allocator) !EntryData {
        if (data.len < 14) return error.InvalidEntryData; // min: 8+2+0+1+1+2

        var pos: usize = 0;

        const command_hash = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;

        const command_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        if (pos + command_len + 4 > data.len) return error.InvalidEntryData;

        const command = try allocator.dupe(u8, data[pos .. pos + command_len]);
        pos += command_len;

        const exit_code = data[pos];
        pos += 1;

        const flags = data[pos];
        pos += 1;

        const frequency = std.mem.readInt(u16, data[pos..][0..2], .little);

        return EntryData{
            .command_hash = command_hash,
            .command = command,
            .exit_code = exit_code,
            .flags = flags,
            .frequency = frequency,
            .timestamp = 0, // filled from header after deserialize
        };
    }
};

/// append-only log writer
pub const LogWriter = struct {
    crypto: *CryptoContext,
    log_dir: []const u8,
    allocator: std.mem.Allocator,
    instance_id: u8,
    sequence: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        crypto: *CryptoContext,
    ) !LogWriter {
        const log_dir = try getLogDir(allocator);
        errdefer allocator.free(log_dir);

        // ensure directory exists
        fs.createDirAbsolute(compat.io(), log_dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // generate instance id
        const instance_id = generateInstanceId();

        return LogWriter{
            .crypto = crypto,
            .log_dir = log_dir,
            .allocator = allocator,
            .instance_id = instance_id,
            .sequence = 0,
        };
    }

    pub fn deinit(self: *LogWriter) void {
        self.allocator.free(self.log_dir);
    }

    /// append entry to log atomically
    pub fn append(self: *LogWriter, entry: EntryData) !void {
        // serialize entry data
        const plaintext = try entry.serialize(self.allocator);
        defer self.allocator.free(plaintext);

        // create header (entry_len will be set after encryption)
        // zero-initialize so implicit extern-struct padding bytes are not
        // undefined stack garbage written to disk
        var header = std.mem.zeroes(EntryHeader);
        header.magic = MAGIC[0..4].*;
        header.version = VERSION;
        header.reserved = 0;
        header.entry_len = 0; // placeholder
        header.instance = self.instance_id;
        header.sequence = self.sequence;
        header.timestamp = if (entry.timestamp > 0) entry.timestamp else @intCast(compat.timestamp());
        header.padding = [_]u8{0} ** 6;

        // create AAD from metadata fields (manual serialization to avoid padding issues)
        var aad_buf: [24]u8 = undefined;
        @memcpy(aad_buf[0..4], &header.magic);
        aad_buf[4] = header.version;
        aad_buf[5] = header.reserved;
        // skip entry_len (bytes 6-7)
        aad_buf[6] = header.instance;
        aad_buf[7] = 0; // padding
        std.mem.writeInt(u64, aad_buf[8..16], header.sequence, .little);
        std.mem.writeInt(u64, aad_buf[16..24], header.timestamp, .little);

        // encrypt entry
        const encrypted = try self.crypto.encrypt(plaintext, &aad_buf);
        defer self.allocator.free(encrypted);

        // update header with actual encrypted length
        header.entry_len = @intCast(encrypted.len);

        // get log file path
        const log_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/current.log.enc",
            .{self.log_dir}
        );
        defer self.allocator.free(log_path);

        // Build the whole record (header + ciphertext) contiguously and append
        // it with a SINGLE O_APPEND write. The old code read file.length() then
        // writePositionalAll at that offset — a TOCTOU race: two shells sharing
        // the history read the same end offset and overwrote each other's
        // entries (concurrent-write data loss). With O_APPEND the kernel does
        // seek-to-end + write as one atomic step, and a single write of a small
        // (<PIPE_BUF) record is not interleaved with other appenders.
        const header_bytes = std.mem.asBytes(&header);
        const record = try self.allocator.alloc(u8, header_bytes.len + encrypted.len);
        defer self.allocator.free(record);
        @memcpy(record[0..header_bytes.len], header_bytes);
        @memcpy(record[header_bytes.len..], encrypted);

        const fd = try compat.posix.open(log_path, .{
            .ACCMODE = .WRONLY,
            .APPEND = true,
            .CREAT = true,
        }, 0o600);
        defer compat.posix.close(fd);

        var written: usize = 0;
        while (written < record.len) {
            written += try compat.posix.write(fd, record[written..]);
        }
        _ = std.c.fsync(fd); // durability

        // increment sequence
        self.sequence += 1;
    }
};

/// log reader
pub const LogReader = struct {
    crypto: *CryptoContext,
    log_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        crypto: *CryptoContext,
    ) !LogReader {
        const log_dir = try getLogDir(allocator);

        return LogReader{
            .crypto = crypto,
            .log_dir = log_dir,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LogReader) void {
        self.allocator.free(self.log_dir);
    }

    /// read all entries from all log files
    pub fn readAll(self: *LogReader) ![]EntryData {
        var end_offset: u64 = 0;
        return self.readAllTracked(&end_offset);
    }

    /// read all entries and report final file offset
    pub fn readAllTracked(self: *LogReader, end_offset: *u64) ![]EntryData {
        var entries = try std.ArrayList(EntryData).initCapacity(self.allocator, 100);
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry.command);
            }
            entries.deinit(self.allocator);
        }

        // read current.log.enc
        const log_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/current.log.enc",
            .{self.log_dir}
        );
        defer self.allocator.free(log_path);

        self.readFileFrom(log_path, &entries, 0, end_offset) catch {
            // silently ignore - file might not exist or be corrupted
        };

        return entries.toOwnedSlice(self.allocator);
    }

    /// read entries appended after the given offset
    pub fn readFrom(self: *LogReader, offset: u64, end_offset: *u64) ![]EntryData {
        var entries = try std.ArrayList(EntryData).initCapacity(self.allocator, 16);
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry.command);
            }
            entries.deinit(self.allocator);
        }

        const log_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/current.log.enc",
            .{self.log_dir}
        );
        defer self.allocator.free(log_path);

        self.readFileFrom(log_path, &entries, offset, end_offset) catch {
            // silently ignore
        };

        return entries.toOwnedSlice(self.allocator);
    }

    fn readFileFrom(self: *LogReader, path: []const u8, entries: *std.ArrayList(EntryData), start_offset: u64, end_offset: *u64) !void {
        const file = try fs.openFileAbsolute(compat.io(), path, .{});
        defer file.close(compat.io());

        var pos: u64 = start_offset;

        while (true) {
            // read header
            var header: EntryHeader = undefined;
            const header_bytes = std.mem.asBytes(&header);
            const n = file.readPositionalAll(compat.io(), header_bytes, pos) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            pos += n;

            if (n == 0) break; // eof
            if (n < @sizeOf(EntryHeader)) break; // truncated file

            // validate header
            header.validate() catch break; // corrupted/old format

            // read encrypted data
            const encrypted = try self.allocator.alloc(u8, header.entry_len);
            defer self.allocator.free(encrypted);

            const data_read = try file.readPositionalAll(compat.io(), encrypted, pos);
            pos += data_read;
            if (data_read < header.entry_len) break; // truncated entry

            // create AAD same as during encryption (manual serialization)
            var aad_buf: [24]u8 = undefined;
            @memcpy(aad_buf[0..4], &header.magic);
            aad_buf[4] = header.version;
            aad_buf[5] = header.reserved;
            // skip entry_len (bytes 6-7)
            aad_buf[6] = header.instance;
            aad_buf[7] = 0; // padding
            std.mem.writeInt(u64, aad_buf[8..16], header.sequence, .little);
            std.mem.writeInt(u64, aad_buf[16..24], header.timestamp, .little);

            // decrypt (silently skip entries from old keys)
            const plaintext = self.crypto.decrypt(encrypted, &aad_buf) catch {
                continue;
            };
            defer self.allocator.free(plaintext);

            // deserialize (silently skip malformed entries)
            var entry = EntryData.deserialize(plaintext, self.allocator) catch {
                continue;
            };
            entry.timestamp = header.timestamp;

            try entries.append(self.allocator, entry);
        }

        end_offset.* = pos;
    }
};

fn getLogDir(allocator: std.mem.Allocator) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/zish/history.d", .{home});
}

/// read all entries with a specific key (for password change)
pub fn readAllWithKey(allocator: std.mem.Allocator, key: [32]u8) ![]EntryData {
    var temp_crypto = try CryptoContext.initWithKey(allocator, key);
    defer temp_crypto.deinit();

    var reader = try LogReader.init(allocator, &temp_crypto);
    defer reader.deinit();

    return reader.readAll();
}

fn generateInstanceId() u8 {
    const pid = std.os.linux.getpid();
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&pid));
    var hostname_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    if (posix.gethostname(&hostname_buf)) |hostname| {
        hasher.update(hostname);
    } else |_| {}
    return @truncate(hasher.final());
}

// tests
test "serialize and deserialize entry" {
    const allocator = std.testing.allocator;

    const original = EntryData{
        .command_hash = 12345,
        .command = "echo test",
        .exit_code = 0,
        .flags = 1,
        .frequency = 5,
        .timestamp = 0,
    };

    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized = try EntryData.deserialize(serialized, allocator);
    defer allocator.free(deserialized.command);

    try std.testing.expectEqual(original.command_hash, deserialized.command_hash);
    try std.testing.expectEqualStrings(original.command, deserialized.command);
    try std.testing.expectEqual(original.exit_code, deserialized.exit_code);
    try std.testing.expectEqual(original.flags, deserialized.flags);
    try std.testing.expectEqual(original.frequency, deserialized.frequency);
}

// test disabled: uses real ~/.config/zish/history.d path, not isolated
// TODO: refactor to use temp directory for test isolation
