// Audio capture and playback via subprocess.
// Same pattern as curl for HTTP — shell out to arecord/aplay.
// No libasound dependency. The subprocess handles ALSA.
//
// Capture: arecord → pipe → PCM frames → consumer
// Playback: producer → pipe → PCM frames → aplay

const std = @import("std");
const posix = std.posix;

/// Streaming audio capture via arecord subprocess.
/// Produces 16kHz mono i16 PCM on stdout pipe.
pub const Capture = struct {
    child: std.process.Child,
    stdout_fd: posix.fd_t,
    running: bool = true,

    /// Start capturing from default audio device.
    /// Returns immediately — read PCM from stdout_fd.
    pub fn start(alloc: std.mem.Allocator) !Capture {
        // Try parecord (PulseAudio/PipeWire) first, fall back to arecord (ALSA)
        var child = std.process.Child.init(
            &.{
                "parecord",
                "--format=s16le", // signed 16-bit little-endian
                "--rate=16000", // 16kHz
                "--channels=1", // mono
                "--raw", // raw PCM (no WAV header)
            },
            alloc,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

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
            _ = self.child.kill() catch {};
            _ = self.child.wait() catch {};
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
        var rate_buf: [8]u8 = undefined;
        const rate_str = std.fmt.bufPrint(&rate_buf, "{d}", .{sample_rate}) catch "24000";

        var child = std.process.Child.init(
            &.{ "paplay", "--format=s16le", "--rate", rate_str, "--channels=1", "--raw" },
            alloc,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

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
            posix.close(self.stdin_fd);
            _ = self.child.wait() catch {};
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
