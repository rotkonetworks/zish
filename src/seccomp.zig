//! Syscall restriction via seccomp-BPF — the "pledge" half of the sandbox.
//!
//! Landlock (see sandbox.zig) is the "unveil" half: it bounds which files a
//! process may touch. This bounds which *syscalls* it may make. The two are
//! complementary and both are needed — Landlock cannot stop `ptrace`, and
//! seccomp cannot express "write only under /home/x".
//!
//! ## Why a denylist, not an allowlist
//!
//! Cosmopolitan's `pledge()` is an allowlist of promise categories, which
//! works because redbean is a closed world with a known syscall set. A shell
//! `exec`s arbitrary programs — a compiler, git, python, next year's glibc —
//! and the filter is inherited across exec, so a tight allowlist would
//! SIGSYS-kill legitimate tools and rot with every kernel release (the reason
//! Docker's default profile carries a permanent trail of "add this syscall"
//! patches). So this is a small, curated *denylist* of syscalls that a shell's
//! children have no legitimate need for and that are real escape primitives.
//!
//! ## Scope of this filter (deliberately minimal)
//!
//! Only the genuinely tension-free set, closing the tested `ptrace` escape:
//!
//!   ptrace, process_vm_readv, process_vm_writev  — attach to / read / write
//!       another process's memory. The escape: with yama ptrace_scope=0 a
//!       restricted process drives an unrestricted one. Denying ptrace alone
//!       leaves process_vm_* as half the same primitive, so all three go.
//!   pidfd_getfd  — steal an already-open fd from another same-user process
//!       (gated by the same PTRACE_MODE_ATTACH_REALCREDS check under
//!       ptrace_scope=0). Since Landlock checks rights at open() not per-write,
//!       a stolen O_WRONLY fd writes outside the profile — the third leg of the
//!       same primitive, so it goes with the others.
//!   kexec_load, kexec_file_load                  — boot a new kernel. Zero
//!       legitimate use from a shell; already CAP_SYS_BOOT-gated. Free.
//!
//! Deliberately NOT here (each has real tension, revisit behind an explicit
//! opt-in profile rather than defaulting them on):
//!   - socket family — the network story; breaks reaching a model. See the
//!     `offline` profile design, not this filter.
//!   - unshare/setns/mount — rootless containers, `nix build`, bwrap use them.
//!   - bpf — bpftrace and observability tooling.
//!   - memfd_create/execveat — glibc, CPython, Wayland use them legitimately;
//!     and anonymous exec is still Landlock-write-bounded, so it is a
//!     monitoring gap, not a containment gap.
//!
//! ## Return action
//!
//! Denied syscalls return EPERM (SECCOMP_RET_ERRNO), not SIGSYS-kill: it is
//! evaluated before the syscall runs, so it is exactly as strong for
//! containment, but a program sees a clean error (strace fails the way yama
//! already makes it fail) instead of dying. The one KILL is the architecture
//! guard: a filter keyed on syscall numbers is bypassable by entering through
//! a foreign ABI (x32, compat), so any non-native arch is killed outright.
//! This guard is mandatory, not optional — it is the classic seccomp CVE class.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const SECCOMP = linux.SECCOMP;

pub const Error = error{
    Unsupported,
    InstallFailed,
    NoNewPrivsFailed,
};

// Classic-BPF instruction, matching the kernel's `struct sock_filter`.
const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

// Classic BPF opcodes used here.
const LD_W_ABS: u16 = 0x20; // BPF_LD | BPF_W  | BPF_ABS
const JEQ_K: u16 = 0x15; //    BPF_JMP| BPF_JEQ| BPF_K
const JGE_K: u16 = 0x35; //    BPF_JMP| BPF_JGE| BPF_K
const RET_K: u16 = 0x06; //    BPF_RET| BPF_K

// Offsets into `struct seccomp_data`: nr is the first u32, arch the second.
const OFF_NR: u32 = 0;
const OFF_ARCH: u32 = 4;

// On x86_64, a syscall number with this bit set is an x32-ABI call with
// different numbering — kill rather than risk a number collision.
const X32_SYSCALL_BIT: u32 = 0x4000_0000;

// AUDIT_ARCH for the native ABI: EM number | __AUDIT_ARCH_64BIT | _LE. Defined
// directly rather than via std's AUDIT.ARCH enum, which has a member that fails
// to compile (references a missing elf.EM tag) the moment the enum is analyzed.
const AUDIT_ARCH_64BIT: u32 = 0x8000_0000;
const AUDIT_ARCH_LE: u32 = 0x4000_0000;
const native_audit_arch: u32 = switch (builtin.cpu.arch) {
    .x86_64 => 62 | AUDIT_ARCH_64BIT | AUDIT_ARCH_LE, // EM_X86_64
    .aarch64 => 183 | AUDIT_ARCH_64BIT | AUDIT_ARCH_LE, // EM_AARCH64
    else => 0,
};

// The denylist, resolved to arch-correct numbers at compile time. A name the
// target kernel headers don't define simply isn't included.
fn deniedSyscalls() []const u32 {
    const names = [_][]const u8{
        "ptrace",
        "process_vm_readv",
        "process_vm_writev",
        "pidfd_getfd",
        "kexec_load",
        "kexec_file_load",
    };
    comptime {
        var list: [names.len]u32 = undefined;
        var n: usize = 0;
        for (names) |name| {
            if (@hasField(linux.SYS, name)) {
                list[n] = @intFromEnum(@field(linux.SYS, name));
                n += 1;
            }
        }
        const out = list[0..n].*;
        return &out;
    }
}

/// Apply the syscall filter to the current process, irreversibly. Call after
/// Landlock (so the filter need not allow the landlock syscalls) and while
/// still single-threaded. Fails closed: returns an error rather than
/// installing a partial or no filter.
pub fn apply() Error!void {
    // Only little-endian x86_64 / aarch64 are shipped targets and the ones the
    // offset/x32 assumptions below are correct for. Fail closed elsewhere
    // rather than install a filter that might be keyed wrong.
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) {
        return Error.Unsupported;
    }

    const denied = comptime deniedSyscalls();
    const is_x86_64 = builtin.cpu.arch == .x86_64;
    // x32 guard instruction, x86_64 only. Comptime so it sizes the array.
    const guard: usize = if (is_x86_64) 1 else 0;

    // Build the program. Layout:
    //   LD arch; JEQ current ? continue : KILL       (2)
    //   LD nr                                         (1)
    //   [x86_64] JGE X32_BIT ? KILL : continue        (guard)
    //   for each denied nr: JEQ nr ? EPERM : continue (denied.len)
    //   RET ALLOW; RET EPERM; RET KILL                (3)
    var prog: [6 + guard + denied.len]SockFilter = undefined;
    var i: usize = 0;

    // Tail indices (three RET instructions at the very end).
    const allow_idx: usize = 3 + guard + denied.len;
    const eperm_idx: usize = allow_idx + 1;
    const kill_idx: usize = allow_idx + 2;

    // 0: load arch
    prog[i] = .{ .code = LD_W_ABS, .jt = 0, .jf = 0, .k = OFF_ARCH };
    i += 1;
    // 1: if arch == native, fall through; else jump to KILL
    prog[i] = .{
        .code = JEQ_K,
        .jt = 0,
        .jf = @intCast(kill_idx - i - 1),
        .k = native_audit_arch,
    };
    i += 1;
    // 2: load nr
    prog[i] = .{ .code = LD_W_ABS, .jt = 0, .jf = 0, .k = OFF_NR };
    i += 1;
    // 3 (x86_64 only): if nr >= X32_BIT, jump to KILL
    if (is_x86_64) {
        prog[i] = .{
            .code = JGE_K,
            .jt = @intCast(kill_idx - i - 1),
            .jf = 0,
            .k = X32_SYSCALL_BIT,
        };
        i += 1;
    }
    // deny checks: if nr == denied, jump to EPERM
    for (denied) |nr| {
        prog[i] = .{
            .code = JEQ_K,
            .jt = @intCast(eperm_idx - i - 1),
            .jf = 0,
            .k = nr,
        };
        i += 1;
    }
    // tail
    prog[i] = .{ .code = RET_K, .jt = 0, .jf = 0, .k = SECCOMP.RET.ALLOW };
    i += 1;
    prog[i] = .{ .code = RET_K, .jt = 0, .jf = 0, .k = SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM)) };
    i += 1;
    prog[i] = .{ .code = RET_K, .jt = 0, .jf = 0, .k = SECCOMP.RET.KILL_PROCESS };
    i += 1;

    std.debug.assert(i == prog.len);

    // seccomp filter install requires no_new_privs (unless CAP_SYS_ADMIN).
    // Landlock already set it, but set it here too so this is self-contained.
    const PR_SET_NO_NEW_PRIVS = 38;
    if (@as(isize, @bitCast(linux.syscall5(.prctl, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))) != 0) {
        return Error.NoNewPrivsFailed;
    }

    // TSYNC applies the filter to every thread of the process, not just this
    // one. zish is single-threaded at this point (the filter is installed at
    // startup, before any worker thread is spawned) — but a plain
    // SET_MODE_FILTER covers only the calling thread, so relying on that
    // invariant means a future thread-spawn moved earlier would silently leave
    // threads unfiltered. With TSYNC the kernel either syncs all threads or
    // returns the offending thread id (a positive value), which the != 0 check
    // treats as failure. Fail-closed and correct regardless of thread count.
    const fprog = SockFprog{ .len = @intCast(prog.len), .filter = &prog };
    const rc = linux.syscall3(.seccomp, SECCOMP.SET_MODE_FILTER, SECCOMP.FILTER_FLAG.TSYNC, @intFromPtr(&fprog));
    if (@as(isize, @bitCast(rc)) != 0) return Error.InstallFailed;
}

// ============================================================
// Tests
// ============================================================

test "denylist resolves and contains ptrace" {
    const denied = comptime deniedSyscalls();
    try std.testing.expect(denied.len >= 1);
    var found = false;
    for (denied) |nr| {
        if (nr == @intFromEnum(linux.SYS.ptrace)) found = true;
    }
    try std.testing.expect(found);
}

test "denylist contains the full ptrace-family fd-theft primitive" {
    const denied = comptime deniedSyscalls();
    inline for (.{ "process_vm_readv", "process_vm_writev", "pidfd_getfd" }) |name| {
        if (@hasField(linux.SYS, name)) {
            const want = @intFromEnum(@field(linux.SYS, name));
            var found = false;
            for (denied) |nr| {
                if (nr == want) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "program length matches layout" {
    // head(3) + optional x32 guard + N deny + tail(3).
    const denied = comptime deniedSyscalls();
    const guard: usize = if (builtin.cpu.arch == .x86_64) 1 else 0;
    try std.testing.expectEqual(@as(usize, 6 + guard + denied.len), 3 + guard + denied.len + 3);
}
