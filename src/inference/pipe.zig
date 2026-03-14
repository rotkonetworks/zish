// Typed SPSC pipe: lock-free ring buffer for streaming frames.
//
// Same abstraction for local (shared memory) and remote (fd/quicnet).
// The pipe doesn't care about transport — it moves typed frames
// between a producer and consumer. Period.
//
// Local: mmap(MAP_SHARED|MAP_ANONYMOUS) before fork → zero-copy IPC
// Remote: read()/write() on fd (pipe, unix socket, QUIC stream)
// The frame type is comptime — no runtime dispatch, no boxing.
//
// Design: DMA ring buffer pattern. Producer writes at tail,
// consumer reads at head. Power-of-2 capacity for mask trick.
// Atomic head/tail for lock-free cross-thread/process sync.
// Same pattern as agent_queue.zig but generic.

const std = @import("std");
const posix = std.posix;

/// Lock-free typed SPSC ring buffer.
/// Works in shared memory (same process or across fork).
pub fn Ring(comptime Frame: type, comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);
    const MASK = capacity - 1;

    return struct {
        const Self = @This();

        frames: [capacity]Frame,
        head: std.atomic.Value(usize), // consumer reads here
        tail: std.atomic.Value(usize), // producer writes here

        pub fn init() Self {
            return .{
                .frames = undefined,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
            };
        }

        /// Push a frame. Returns false if full.
        pub fn push(self: *Self, frame: Frame) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail -% head >= capacity) return false;
            self.frames[tail & MASK] = frame;
            self.tail.store(tail +% 1, .release);
            return true;
        }

        /// Pop a frame. Returns null if empty.
        pub fn pop(self: *Self) ?Frame {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;
            const frame = self.frames[head & MASK];
            self.head.store(head +% 1, .release);
            return frame;
        }

        /// Push multiple frames. Returns count pushed.
        pub fn pushSlice(self: *Self, frames: []const Frame) usize {
            var pushed: usize = 0;
            for (frames) |f| {
                if (!self.push(f)) break;
                pushed += 1;
            }
            return pushed;
        }

        /// Pop multiple frames into buffer. Returns count popped.
        pub fn popSlice(self: *Self, out: []Frame) usize {
            var popped: usize = 0;
            while (popped < out.len) {
                if (self.pop()) |f| {
                    out[popped] = f;
                    popped += 1;
                } else break;
            }
            return popped;
        }

        /// Number of frames available to read.
        pub fn available(self: *const Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return tail -% head;
        }

        /// Space available for writing.
        pub fn space(self: *const Self) usize {
            return capacity - self.available();
        }

        /// Blocking push: spin until space available.
        pub fn pushWait(self: *Self, frame: Frame) void {
            while (!self.push(frame)) {
                std.Thread.sleep(100_000); // 100μs
            }
        }
    };
}

// ============================================================
// Frame types for the audio pipeline
// ============================================================

/// 10ms of audio @ 16kHz mono. The heartbeat of the pipeline.
pub const AudioFrame = struct {
    samples: [160]i16,
};

/// One mel spectrogram frame (128 frequency bins).
pub const MelFrame = struct {
    bins: [128]f32,
};

/// A token with metadata.
pub const TokenFrame = struct {
    token: u32,
    flags: Flags = .{},

    const Flags = packed struct {
        eos: bool = false, // end of sequence
        bos: bool = false, // beginning of sequence
        _pad: u6 = 0,
    };
};

/// Out-of-band control signal (separate pipe, never blocks data path).
pub const Control = enum(u8) {
    flush, // discard buffered frames
    eos, // end of stream
    abort, // abort current generation
    cont, // continue after interruption
    mute, // stop sending to speaker
    unmute, // resume sending to speaker
};

// ============================================================
// FdPipe: pipe over file descriptor (unix pipe, socket, QUIC)
// Same typed interface, but serialized over read/write.
// ============================================================

/// Typed pipe over a file descriptor pair.
/// Serializes frames as raw bytes — Frame must be extern or packed.
pub fn FdPipe(comptime Frame: type) type {
    return struct {
        const Self = @This();
        const frame_size = @sizeOf(Frame);

        read_fd: posix.fd_t,
        write_fd: posix.fd_t,

        /// Create from an existing pipe pair.
        pub fn fromFds(read_fd: posix.fd_t, write_fd: posix.fd_t) Self {
            return .{ .read_fd = read_fd, .write_fd = write_fd };
        }

        /// Create a new unix pipe pair.
        pub fn create() !Self {
            const fds = try posix.pipe();
            return .{ .read_fd = fds[0], .write_fd = fds[1] };
        }

        /// Write a frame (blocking).
        pub fn send(self: *const Self, frame: *const Frame) !void {
            const bytes: [*]const u8 = @ptrCast(frame);
            var written: usize = 0;
            while (written < frame_size) {
                const n = posix.write(self.write_fd, bytes[written..frame_size]) catch |e| {
                    if (e == error.WouldBlock) continue;
                    return e;
                };
                written += n;
            }
        }

        /// Read a frame (blocking).
        pub fn recv(self: *const Self, frame: *Frame) !bool {
            const bytes: [*]u8 = @ptrCast(frame);
            var total: usize = 0;
            while (total < frame_size) {
                const n = posix.read(self.read_fd, bytes[total..frame_size]) catch |e| {
                    if (e == error.WouldBlock) continue;
                    return e;
                };
                if (n == 0) return false; // EOF
                total += n;
            }
            return true;
        }

        /// Get pollfd for the read end (for use in poll()).
        pub fn pollFd(self: *const Self) posix.pollfd {
            return .{
                .fd = self.read_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };
        }

        /// Close both ends.
        pub fn close(self: *Self) void {
            posix.close(self.read_fd);
            posix.close(self.write_fd);
        }

        /// Close write end only (signal EOF to reader).
        pub fn closeWrite(self: *Self) void {
            posix.close(self.write_fd);
        }
    };
}
