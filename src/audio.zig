// Audio capture and playback via subprocess.
// Same pattern as curl for HTTP — shell out to arecord/aplay.
// No libasound dependency. The subprocess handles ALSA.
//
// Capture: arecord → pipe → PCM frames → consumer
// Playback: producer → pipe → PCM frames → aplay

const std = @import("std");
const compat = @import("compat.zig");
const posix = compat.posix;

/// Streaming audio capture via arecord subprocess.
/// Produces 16kHz mono i16 PCM on stdout pipe.
pub const Capture = struct {
    child: std.process.Child,
    stdout_fd: posix.fd_t,
    running: bool = true,

    /// Start capturing from default audio device.
    /// Returns immediately — read PCM from stdout_fd.
    pub fn start(alloc: std.mem.Allocator) !Capture {
        _ = alloc;
        // Try parecord (PulseAudio/PipeWire) first, fall back to arecord (ALSA)
        const child = try std.process.spawn(compat.io(), .{
            .argv = &.{
                "parecord",
                "--format=s16le", // signed 16-bit little-endian
                "--rate=16000", // 16kHz
                "--channels=1", // mono
                "--raw", // raw PCM (no WAV header)
            },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        return .{
            .child = child,
            .stdout_fd = child.stdout.?.handle,
        };
    }

    /// Read PCM samples. Returns number of samples read (0 = would block or EOF).
    /// Each sample is i16 (2 bytes).
    pub fn read(self: *Capture, buf: []i16) usize {
        const byte_buf: [*]u8 = @ptrCast(buf.ptr);
        const byte_len = buf.len * 2;
        const n = posix.read(self.stdout_fd, byte_buf[0..byte_len]) catch return 0;
        return n / 2;
    }

    /// Get pollfd for use in poll() event loop.
    pub fn pollFd(self: *const Capture) posix.pollfd {
        return .{
            .fd = self.stdout_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        };
    }

    /// Stop capture.
    pub fn stop(self: *Capture) void {
        if (self.running) {
            // kill() blocks until termination and cleans up (wait built in)
            self.child.kill(compat.io());
            self.running = false;
        }
    }
};

/// Streaming audio playback via aplay subprocess.
/// Accepts 24kHz mono i16 PCM on stdin pipe.
pub const Playback = struct {
    child: std.process.Child,
    stdin_fd: posix.fd_t,
    running: bool = true,

    /// Start playback to default audio device.
    pub fn start(alloc: std.mem.Allocator, sample_rate: u32) !Playback {
        _ = alloc;
        var rate_buf: [8]u8 = undefined;
        const rate_str = std.fmt.bufPrint(&rate_buf, "{d}", .{sample_rate}) catch "24000";

        const child = try std.process.spawn(compat.io(), .{
            .argv = &.{ "paplay", "--format=s16le", "--rate", rate_str, "--channels=1", "--raw" },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        return .{
            .child = child,
            .stdin_fd = child.stdin.?.handle,
        };
    }

    /// Write PCM samples to playback.
    pub fn write(self: *Playback, samples: []const i16) !void {
        const byte_buf: [*]const u8 = @ptrCast(samples.ptr);
        const byte_len = samples.len * 2;
        _ = try posix.write(self.stdin_fd, byte_buf[0..byte_len]);
    }

    /// Stop playback.
    pub fn stop(self: *Playback) void {
        if (self.running) {
            // close stdin to signal EOF so paplay drains; clear the field so
            // wait()'s cleanup doesn't double-close the fd
            posix.close(self.stdin_fd);
            self.child.stdin = null;
            _ = self.child.wait(compat.io()) catch {};
            self.running = false;
        }
    }
};

/// Simple voice activity detection: energy threshold on PCM samples.
/// Returns true if the frame likely contains speech.
pub fn detectVoice(samples: []const i16, threshold: f32) bool {
    if (samples.len == 0) return false;
    var energy: f64 = 0;
    for (samples) |s| {
        const f: f64 = @floatFromInt(s);
        energy += f * f;
    }
    energy /= @floatFromInt(samples.len);
    return energy > @as(f64, threshold);
}
