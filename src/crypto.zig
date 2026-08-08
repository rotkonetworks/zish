// crypto.zig - encryption for history at rest
const std = @import("std");
const compat = @import("compat.zig");
const crypto = std.crypto;
const fs = std.Io.Dir;
const posix = compat.posix;
const history_log = @import("history_log.zig");

const AEAD = crypto.aead.chacha_poly.XChaCha20Poly1305;
const Blake2b256 = crypto.hash.blake2.Blake2b256;

pub const KEY_LEN = 32;
pub const NONCE_LEN = AEAD.nonce_length; // 24 bytes for XChaCha20
pub const TAG_LEN = AEAD.tag_length; // 16 bytes

/// crypto context holds encryption key
pub const CryptoContext = struct {
    key: [KEY_LEN]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CryptoContext {
        var key: [KEY_LEN]u8 = undefined;

        // check if password mode is enabled (and not bypassed)
        const bypass_password = posix.getenv("ZISH_BYPASS_PASSWORD") != null;
        const stdin_is_tty = compat.posix.isatty(compat.posix.STDIN_FILENO);

        // skip password prompt if stdin is not a tty (eg. in tests or pipes)
        if (isPasswordModeEnabled(allocator) and !bypass_password and stdin_is_tty) {
            // try up to 3 times to get the password
            var attempts: u8 = 0;
            while (attempts < 3) : (attempts += 1) {
                // prompt for password
                const password = try promptPassword(allocator, "Enter history password: ");
                // Wipe before returning to the allocator: freed heap is reused,
                // not cleared, so the plaintext would otherwise sit in whatever
                // allocation happens to land on those bytes next.
                defer {
                    std.crypto.secureZero(u8, password);
                    allocator.free(password);
                }

                if (password.len == 0) {
                    return error.EmptyPassword;
                }

                // derive key from password
                key = try deriveKeyFromPassword(password, allocator);

                // validate by trying to read the history file
                if (validateKey(key, allocator)) {
                    break;
                } else {
                    const remaining = 2 - attempts;
                    if (remaining > 0) {
                        const stdout_fd = compat.posix.STDOUT_FILENO;
                        const msg = try std.fmt.allocPrint(allocator, "Wrong password. {d} attempt(s) remaining.\n", .{remaining});
                        defer allocator.free(msg);
                        _ = compat.posix.write(stdout_fd, msg) catch {};
                    } else {
                        // 3 failed attempts - offer to reset
                        const stdout_fd = compat.posix.STDOUT_FILENO;
                        _ = compat.posix.write(stdout_fd, "\nToo many failed attempts.\n") catch {};
                        _ = compat.posix.write(stdout_fd, "Reset history and start fresh? (yes/no): ") catch {};

                        // enable canonical mode to read full line
                        const stdin_fd = compat.posix.STDIN_FILENO;
                        const orig_termios = compat.posix.tcgetattr(stdin_fd) catch {
                            return error.TooManyFailedAttempts;
                        };
                        var line_termios = orig_termios;
                        line_termios.lflag.ICANON = true;
                        line_termios.lflag.ECHO = true;
                        compat.posix.tcsetattr(stdin_fd, .NOW, line_termios) catch {};
                        defer compat.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};

                        var response_buf: [256]u8 = undefined;
                        const bytes_read = compat.posix.read(stdin_fd, &response_buf) catch 0;
                        const response = std.mem.trim(u8, response_buf[0..bytes_read], " \t\r\n");

                        if (std.mem.eql(u8, response, "yes") or std.mem.eql(u8, response, "y")) {
                            try resetHistory(allocator);
                            _ = compat.posix.write(stdout_fd, "History reset. Starting fresh.\n") catch {};

                            // generate new random key
                            compat.io().random(&key);
                            try saveKey(key);
                            break;
                        } else {
                            return error.TooManyFailedAttempts;
                        }
                    }
                }
            }
        } else {
            // try to load existing key, or generate new one
            if (loadKey(&key)) {
                // existing key loaded
            } else |_| {
                // generate new random key
                compat.io().random(&key);
                try saveKey(key);
            }
        }

        return CryptoContext{
            .key = key,
            .allocator = allocator,
        };
    }

    /// init with a specific key (for re-encryption)
    pub fn initWithKey(allocator: std.mem.Allocator, key: [KEY_LEN]u8) !CryptoContext {
        return CryptoContext{
            .key = key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CryptoContext) void {
        // zero sensitive data
        @memset(&self.key, 0);
    }

    /// encrypt plaintext with random nonce
    /// returns: nonce ++ ciphertext ++ tag
    pub fn encrypt(
        self: *CryptoContext,
        plaintext: []const u8,
        aad: []const u8,
    ) ![]u8 {
        // allocate: nonce + ciphertext + tag
        const total_len = NONCE_LEN + plaintext.len + TAG_LEN;
        var result = try self.allocator.alloc(u8, total_len);
        errdefer self.allocator.free(result);

        // generate random nonce
        var nonce: [NONCE_LEN]u8 = undefined;
        compat.io().random(&nonce);

        // copy nonce to output
        @memcpy(result[0..NONCE_LEN], &nonce);

        // encrypt
        const ciphertext = result[NONCE_LEN .. NONCE_LEN + plaintext.len];
        const tag = result[NONCE_LEN + plaintext.len ..][0..TAG_LEN];

        AEAD.encrypt(ciphertext, tag, plaintext, aad, nonce, self.key);

        return result;
    }

    /// decrypt nonce ++ ciphertext ++ tag
    pub fn decrypt(
        self: *CryptoContext,
        encrypted: []const u8,
        aad: []const u8,
    ) ![]u8 {
        if (encrypted.len < NONCE_LEN + TAG_LEN) {
            return error.CiphertextTooShort;
        }

        // extract nonce
        const nonce = encrypted[0..NONCE_LEN].*;

        // extract ciphertext and tag
        const ciphertext_len = encrypted.len - NONCE_LEN - TAG_LEN;
        const ciphertext = encrypted[NONCE_LEN .. NONCE_LEN + ciphertext_len];
        const tag = encrypted[encrypted.len - TAG_LEN ..][0..TAG_LEN].*;

        // allocate plaintext
        const plaintext = try self.allocator.alloc(u8, ciphertext_len);
        errdefer self.allocator.free(plaintext);

        // decrypt and authenticate
        AEAD.decrypt(plaintext, ciphertext, tag, aad, nonce, self.key) catch {
            return error.AuthenticationFailed;
        };

        return plaintext;
    }
};

/// get path to key file: ~/.config/zish/key
fn getKeyPath(allocator: std.mem.Allocator) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/zish/key", .{home});
}

/// load existing key from disk
fn loadKey(key: *[KEY_LEN]u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const key_path = try getKeyPath(allocator);

    const file = try fs.openFileAbsolute(compat.io(), key_path, .{});
    defer file.close(compat.io());

    const bytes_read = try compat.readAll(file, key);
    if (bytes_read != KEY_LEN) {
        return error.InvalidKeyFile;
    }
}

/// save key to disk with secure permissions (public version for chpw)
pub fn saveKeyDirect(key: [KEY_LEN]u8) !void {
    try saveKey(key);
}

/// save key to disk with secure permissions
fn saveKey(key: [KEY_LEN]u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const key_path = try getKeyPath(allocator);

    // ensure directory exists
    if (std.fs.path.dirname(key_path)) |dir| {
        fs.createDirAbsolute(compat.io(), dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    // create file with secure permissions
    const file = try fs.createFileAbsolute(compat.io(), key_path, .{
        .permissions = .fromMode(0o600), // user read/write only
    });
    defer file.close(compat.io());

    try compat.writeAll(file, &key);
    try file.sync(compat.io()); // ensure it hits disk
}

/// prompt for password with echo disabled
pub fn promptPassword(allocator: std.mem.Allocator, prompt_text: []const u8) ![]u8 {
    const stdin_fd = compat.posix.STDIN_FILENO;
    const stdout_fd = compat.posix.STDOUT_FILENO;

    // save original termios
    const original_termios = try compat.posix.tcgetattr(stdin_fd);

    // disable echo but enable canonical mode for line input
    var termios = original_termios;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = true; // enable line-buffered input
    try compat.posix.tcsetattr(stdin_fd, .NOW, termios);

    // restore on exit
    defer compat.posix.tcsetattr(stdin_fd, .NOW, original_termios) catch {};

    // show prompt
    _ = compat.posix.write(stdout_fd, prompt_text) catch return error.WriteFailed;

    // read password
    var password_buf: [256]u8 = undefined;
    // Wipe the plaintext before returning by any path. Without this the
    // password stayed on the stack after the function returned, where it can
    // surface in a core dump or be handed to a later frame that reuses the
    // same bytes. The caller gets its own heap copy.
    defer std.crypto.secureZero(u8, &password_buf);
    const bytes_read = compat.posix.read(stdin_fd, &password_buf) catch return error.ReadFailed;
    const password_line = password_buf[0..bytes_read];

    // print newline since echo was disabled
    _ = compat.posix.write(stdout_fd, "\n") catch {};

    // trim whitespace (including newline)
    const password = std.mem.trim(u8, password_line, " \t\r\n");

    return try allocator.dupe(u8, password);
}

/// derive key from password using Argon2id
pub fn deriveKeyFromPassword(password: []const u8, allocator: std.mem.Allocator) ![KEY_LEN]u8 {
    const Argon2 = crypto.pwhash.argon2;

    // load or generate salt
    const salt = try loadOrGenerateSalt(allocator);

    // derive key using argon2id
    var key: [KEY_LEN]u8 = undefined;
    try Argon2.kdf(
        allocator,
        &key,
        password,
        &salt,
        .{ .t = 3, .m = 65536, .p = 4 }, // moderate security params
        .argon2id,
        compat.io(),
    );

    return key;
}

fn getHistoryDirPath(allocator: std.mem.Allocator) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/zish/history.d", .{home});
}

fn getPasswordModePath(allocator: std.mem.Allocator) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/zish/password_mode", .{home});
}

/// validate that a key can decrypt the history file
fn validateKey(key: [KEY_LEN]u8, allocator: std.mem.Allocator) bool {
    const history_dir = getHistoryDirPath(allocator) catch return true; // assume valid if can't check
    defer allocator.free(history_dir);

    const log_path = std.fmt.allocPrint(allocator, "{s}/current.log.enc", .{history_dir}) catch return true;
    defer allocator.free(log_path);

    // if file doesn't exist, key is "valid" (nothing to validate)
    const file = fs.openFileAbsolute(compat.io(), log_path, .{}) catch return true;
    defer file.close(compat.io());

    // read header using proper struct to handle alignment
    var header: history_log.EntryHeader = undefined;
    const header_bytes = std.mem.asBytes(&header);
    const bytes_read = compat.readAll(file, header_bytes) catch return false;
    if (bytes_read < @sizeOf(history_log.EntryHeader)) return true; // empty/incomplete file is valid

    // validate header magic
    header.validate() catch return false;

    if (header.entry_len == 0) return false;

    // read encrypted data
    const encrypted = allocator.alloc(u8, header.entry_len) catch return false;
    defer allocator.free(encrypted);

    const data_read = compat.readAll(file, encrypted) catch return false;
    if (data_read < header.entry_len) return false;

    // create crypto context with the key
    var ctx = CryptoContext{ .key = key, .allocator = allocator };

    // create AAD (same as during encryption in history_log.zig)
    var aad_buf: [24]u8 = undefined;
    @memcpy(aad_buf[0..4], &header.magic);
    aad_buf[4] = header.version;
    aad_buf[5] = header.reserved;
    aad_buf[6] = header.instance;
    aad_buf[7] = 0; // padding
    std.mem.writeInt(u64, aad_buf[8..16], header.sequence, .little);
    std.mem.writeInt(u64, aad_buf[16..24], header.timestamp, .little);

    // try to decrypt
    const plaintext = ctx.decrypt(encrypted, &aad_buf) catch return false;
    allocator.free(plaintext);

    return true;
}

/// reset history by renaming the encrypted file and removing password mode
fn resetHistory(allocator: std.mem.Allocator) !void {
    const history_dir = try getHistoryDirPath(allocator);
    defer allocator.free(history_dir);

    const log_path = try std.fmt.allocPrint(allocator, "{s}/current.log.enc", .{history_dir});
    defer allocator.free(log_path);

    // rename old history file with timestamp
    const timestamp = compat.timestamp();
    const backup_path = try std.fmt.allocPrint(allocator, "{s}/corrupted_{d}.log.enc", .{ history_dir, timestamp });
    defer allocator.free(backup_path);

    fs.renameAbsolute(log_path, backup_path, compat.io()) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    // disable password mode
    try disablePasswordMode(allocator);
}

pub fn isPasswordModeEnabled(allocator: std.mem.Allocator) bool {
    const path = getPasswordModePath(allocator) catch return false;
    defer allocator.free(path);

    const file = fs.openFileAbsolute(compat.io(), path, .{}) catch return false;
    file.close(compat.io());
    return true;
}

pub fn enablePasswordMode(allocator: std.mem.Allocator) !void {
    const path = try getPasswordModePath(allocator);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        fs.createDirAbsolute(compat.io(), dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    const file = try fs.createFileAbsolute(compat.io(), path, .{ .permissions = .fromMode(0o600) });
    defer file.close(compat.io());
    try compat.writeAll(file, "1");
}

pub fn disablePasswordMode(allocator: std.mem.Allocator) !void {
    const path = try getPasswordModePath(allocator);
    defer allocator.free(path);

    fs.deleteFileAbsolute(compat.io(), path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

fn getSaltPath(allocator: std.mem.Allocator) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/zish/salt", .{home});
}

fn loadOrGenerateSalt(allocator: std.mem.Allocator) ![16]u8 {
    const salt_path = try getSaltPath(allocator);
    defer allocator.free(salt_path);

    // try to load existing salt
    if (fs.openFileAbsolute(compat.io(), salt_path, .{})) |file| {
        defer file.close(compat.io());
        var salt: [16]u8 = undefined;
        const bytes_read = try compat.readAll(file, &salt);
        if (bytes_read == 16) {
            return salt;
        }
    } else |_| {}

    // generate new salt
    var salt: [16]u8 = undefined;
    compat.io().random(&salt);

    // save to disk
    if (std.fs.path.dirname(salt_path)) |dir| {
        fs.createDirAbsolute(compat.io(), dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    const file = try fs.createFileAbsolute(compat.io(), salt_path, .{
        .permissions = .fromMode(0o600),
    });
    defer file.close(compat.io());

    try compat.writeAll(file, &salt);
    try file.sync(compat.io());

    return salt;
}

// tests
test "encrypt and decrypt roundtrip" {
    const allocator = std.testing.allocator;

    var ctx = try CryptoContext.init(allocator);
    defer ctx.deinit();

    const plaintext = "secret history command";
    const aad = "header data";

    const encrypted = try ctx.encrypt(plaintext, aad);
    defer allocator.free(encrypted);

    const decrypted = try ctx.decrypt(encrypted, aad);
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "decrypt with wrong aad fails" {
    const allocator = std.testing.allocator;

    var ctx = try CryptoContext.init(allocator);
    defer ctx.deinit();

    const plaintext = "secret history command";
    const aad = "correct header";
    const wrong_aad = "wrong header";

    const encrypted = try ctx.encrypt(plaintext, aad);
    defer allocator.free(encrypted);

    const result = ctx.decrypt(encrypted, wrong_aad);
    try std.testing.expectError(error.AuthenticationFailed, result);
}

test "decrypt corrupted ciphertext fails" {
    const allocator = std.testing.allocator;

    var ctx = try CryptoContext.init(allocator);
    defer ctx.deinit();

    const plaintext = "secret history command";
    const aad = "header";

    var encrypted = try ctx.encrypt(plaintext, aad);
    defer allocator.free(encrypted);

    // corrupt a byte in the middle
    encrypted[NONCE_LEN + 5] ^= 0xff;

    const result = ctx.decrypt(encrypted, aad);
    try std.testing.expectError(error.AuthenticationFailed, result);
}

test "key persists across context recreations" {
    const allocator = std.testing.allocator;

    const plaintext = "test data";
    const aad = "header";

    // first context - creates key
    var encrypted: []u8 = undefined;
    {
        var ctx1 = try CryptoContext.init(allocator);
        defer ctx1.deinit();
        encrypted = try ctx1.encrypt(plaintext, aad);
    }
    defer allocator.free(encrypted);

    // second context - loads same key
    {
        var ctx2 = try CryptoContext.init(allocator);
        defer ctx2.deinit();

        const decrypted = try ctx2.decrypt(encrypted, aad);
        defer allocator.free(decrypted);

        try std.testing.expectEqualStrings(plaintext, decrypted);
    }
}
