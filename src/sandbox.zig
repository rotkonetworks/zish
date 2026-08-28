//! Session capability restriction via Landlock.
//!
//! The shell is the fork/exec chokepoint, which makes it the only place that
//! can bound what a command may touch *without* trusting the command. An agent
//! driving zish can therefore ask for less authority than it has, and get it
//! enforced by the kernel rather than by convention.
//!
//! Restriction is applied in the child, after fork and before exec. Landlock
//! is inherited across exec and cannot be relaxed afterwards, so a restricted
//! command cannot escape by spawning something else — which is exactly the
//! property that makes it worth having.
//!
//! **Fail closed.** If a profile asks for restriction and the kernel cannot
//! provide it, `apply` returns an error and the caller must refuse to run the
//! command. A sandbox that silently degrades to "no sandbox" is worse than no
//! sandbox, because the caller believes it is protected. This is the one rule
//! in this file that must not be softened for convenience.
//!
//! Not covered here: network restriction (Landlock ABI 4+) and process scoping
//! (ABI 6+). Both are useful and both are deliberately absent until there is a
//! caller that needs them — see the ABI note in `probe`.

const std = @import("std");
const linux = std.os.linux;

/// Landlock filesystem access rights, ABI 1 unless noted.
pub const Access = struct {
    pub const execute: u64 = 1 << 0;
    pub const write_file: u64 = 1 << 1;
    pub const read_file: u64 = 1 << 2;
    pub const read_dir: u64 = 1 << 3;
    pub const remove_dir: u64 = 1 << 4;
    pub const remove_file: u64 = 1 << 5;
    pub const make_char: u64 = 1 << 6;
    pub const make_dir: u64 = 1 << 7;
    pub const make_reg: u64 = 1 << 8;
    pub const make_sock: u64 = 1 << 9;
    pub const make_fifo: u64 = 1 << 10;
    pub const make_block: u64 = 1 << 11;
    pub const make_sym: u64 = 1 << 12;
    pub const refer: u64 = 1 << 13; // ABI 2
    pub const truncate: u64 = 1 << 14; // ABI 3
    pub const ioctl_dev: u64 = 1 << 15; // ABI 5

    /// Everything an ABI-1 kernel understands.
    pub const all_v1: u64 = 0x1fff;

    /// Reading and traversing, but changing nothing.
    pub const read_only: u64 = execute | read_file | read_dir;

    /// Everything that mutates the filesystem.
    pub const write_all: u64 = write_file | remove_dir | remove_file |
        make_char | make_dir | make_reg | make_sock | make_fifo |
        make_block | make_sym | refer | truncate | ioctl_dev;
};

/// Character devices a restricted process may still write to. None of them can
/// be used to persist data, which is why granting them does not weaken the
/// profile.
const dev_writable = [_][*:0]const u8{
    "/dev/null",
    "/dev/zero",
    "/dev/full",
    "/dev/random",
    "/dev/urandom",
    "/dev/tty",
    "/dev/stdout",
    "/dev/stderr",
    "/dev/stdin",
    "/dev/ptmx",
};

pub const Error = error{
    /// The kernel has no Landlock support, or it is disabled.
    Unsupported,
    /// A path in the profile could not be opened to build a rule.
    BadPath,
    /// The kernel refused the ruleset.
    RulesetFailed,
    /// prctl(NO_NEW_PRIVS) failed; Landlock cannot be applied without it.
    NoNewPrivsFailed,
};

/// Highest access bit the running kernel understands, given its ABI version.
/// Requesting a bit the kernel does not know is EINVAL, so the mask matters.
fn maskForAbi(abi: i64) u64 {
    var m: u64 = Access.all_v1;
    if (abi >= 2) m |= Access.refer;
    if (abi >= 3) m |= Access.truncate;
    if (abi >= 5) m |= Access.ioctl_dev;
    return m;
}

/// Landlock ABI version, or a negative errno if unsupported.
///
/// The version is queried rather than assumed because the access bits a
/// ruleset may declare depend on it: a bit from a newer ABI is rejected
/// outright, so a binary built on a new kernel would otherwise fail on an
/// older one.
pub fn probe() i64 {
    const rc = linux.syscall3(.landlock_create_ruleset, 0, 0, 1); // VERSION
    return @bitCast(rc);
}

pub fn available() bool {
    return probe() > 0;
}

/// What a command is allowed to do.
pub const Profile = enum {
    /// No restriction. The default, and the only one that costs nothing.
    unrestricted,
    /// Read and execute anywhere; mutate nothing.
    read_only,
    /// Read and execute anywhere; mutate only beneath the given write roots.
    workdir,

    pub fn fromString(s: []const u8) ?Profile {
        if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "unrestricted")) return .unrestricted;
        if (std.mem.eql(u8, s, "readonly") or std.mem.eql(u8, s, "read-only")) return .read_only;
        if (std.mem.eql(u8, s, "workdir")) return .workdir;
        return null;
    }
};

/// Add a `path beneath` rule granting `allowed` under `path`.
fn addPathRule(ruleset_fd: i32, path: [*:0]const u8, allowed: u64) Error!void {
    // O_PATH is enough: Landlock only needs to identify the directory, and
    // opening with it avoids needing read permission on the path itself.
    const O_PATH = 0o10000000;
    const O_CLOEXEC = 0o2000000;
    const fd_rc = linux.syscall3(.open, @intFromPtr(path), O_PATH | O_CLOEXEC, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_rc)));
    if (fd < 0) return Error.BadPath;
    defer _ = linux.syscall1(.close, @intCast(fd));

    // struct landlock_path_beneath_attr is __packed__ in the kernel headers:
    // u64 followed by s32, 12 bytes with no tail padding. A Zig extern struct
    // would pad to 16 and the kernel would reject the size, so it is built by
    // hand.
    var attr: [12]u8 = undefined;
    std.mem.writeInt(u64, attr[0..8], allowed, .little);
    std.mem.writeInt(i32, attr[8..12], fd, .little);

    const rc = linux.syscall4(.landlock_add_rule, @intCast(ruleset_fd), 1, // RULE_PATH_BENEATH
        @intFromPtr(&attr), 0);
    if (@as(isize, @bitCast(rc)) != 0) return Error.RulesetFailed;
}

/// Apply `profile` to the current process, irreversibly.
///
/// `write_roots` are the directories the `workdir` profile may mutate; ignored
/// by the other profiles. Call this in the child, after fork, before exec.
///
/// Returns an error rather than degrading when the kernel cannot enforce the
/// request. Callers must treat that as fatal for the command.
pub fn apply(profile: Profile, write_roots: []const [*:0]const u8) Error!void {
    if (profile == .unrestricted) return;

    const abi = probe();
    if (abi <= 0) return Error.Unsupported;
    const handled = maskForAbi(abi);

    // Only handled_access_fs is declared, and the size is 8, which every ABI
    // accepts. Newer kernels take a larger struct for network and scoping
    // rules; declaring only what is used keeps this working on both.
    var ruleset_attr: [8]u8 = undefined;
    std.mem.writeInt(u64, ruleset_attr[0..8], handled, .little);

    const rs_rc = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&ruleset_attr), 8, 0);
    const ruleset_fd: i32 = @intCast(@as(isize, @bitCast(rs_rc)));
    if (ruleset_fd < 0) return Error.RulesetFailed;
    defer _ = linux.syscall1(.close, @intCast(ruleset_fd));

    // Read and execute everywhere. Landlock is deny-by-default over the rights
    // named in `handled`, so granting read beneath "/" and nothing else yields
    // a filesystem that can be read and traversed but not modified.
    try addPathRule(ruleset_fd, "/", Access.read_only & handled);

    // The write-only device files, always.
    //
    // `>/dev/null` is a *write*, and so are the tty devices every interactive
    // program touches. A read-only profile that blocks them is not a sandbox,
    // it is a broken shell — `cat x >/dev/null` fails, and so does anything
    // that writes to its own terminal. These grant write to a handful of
    // character devices that cannot be used to persist anything, which is the
    // line that matters: they are pass-through sinks and entropy sources, not
    // storage.
    for (dev_writable) |dev| {
        // Missing on some systems (no /dev/tty without a controlling
        // terminal); a device that is not there cannot be written to either,
        // so skipping is safe.
        addPathRule(ruleset_fd, dev, (Access.write_file | Access.read_file | Access.ioctl_dev) & handled) catch continue;
    }

    // Write roots apply to every restrictive profile, not just `workdir`:
    // `readonly` plus an explicit root is "read anywhere, write only here",
    // which is the shape a caller wrapping a program usually wants. With no
    // roots — plain `readonly` — the loop does nothing and the behaviour is
    // unchanged.
    for (write_roots) |root| {
        try addPathRule(ruleset_fd, root, handled);
    }

    // Landlock requires no_new_privs so a restricted process cannot regain
    // authority through a setuid binary.
    const PR_SET_NO_NEW_PRIVS = 38;
    const pr = linux.syscall5(.prctl, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (@as(isize, @bitCast(pr)) != 0) return Error.NoNewPrivsFailed;

    const rc = linux.syscall2(.landlock_restrict_self, @intCast(ruleset_fd), 0);
    if (@as(isize, @bitCast(rc)) != 0) return Error.RulesetFailed;
}

// ============================================================
// Tests
// ============================================================

test "profile names round-trip" {
    try std.testing.expectEqual(Profile.read_only, Profile.fromString("readonly").?);
    try std.testing.expectEqual(Profile.read_only, Profile.fromString("read-only").?);
    try std.testing.expectEqual(Profile.workdir, Profile.fromString("workdir").?);
    try std.testing.expectEqual(Profile.unrestricted, Profile.fromString("none").?);
    try std.testing.expect(Profile.fromString("nonsense") == null);
}

test "unrestricted never fails, even without kernel support" {
    try apply(.unrestricted, &.{});
}

test "abi mask grows with version and never exceeds it" {
    try std.testing.expectEqual(Access.all_v1, maskForAbi(1));
    try std.testing.expect(maskForAbi(3) & Access.truncate != 0);
    try std.testing.expect(maskForAbi(1) & Access.truncate == 0);
    try std.testing.expect(maskForAbi(5) & Access.ioctl_dev != 0);
    try std.testing.expect(maskForAbi(4) & Access.ioctl_dev == 0);
}

test "read_only and write_all partition the v1 rights" {
    // Every ABI-1 right is either a read/traverse right or a mutation right;
    // if a new bit is added to one set and not the other, this catches it.
    const union_bits = (Access.read_only | Access.write_all) & Access.all_v1;
    try std.testing.expectEqual(Access.all_v1, union_bits);
    try std.testing.expectEqual(@as(u64, 0), Access.read_only & Access.write_all);
}
