// agent_queue.zig - lock-free SPSC ring buffer for agent <-> shell communication
// Single Producer Single Consumer: agent thread writes, main thread reads (output queue)
// and main thread writes, agent thread reads (request queue)

const std = @import("std");

pub const MAX_MSG_LEN = 4096;
pub const QUEUE_CAPACITY = 64; // power of 2

pub const MsgKind = enum(u8) {
    text_delta,  // streamed text chunk from model
    tool_call,   // agent is running a tool (name + cmd)
    tool_done,   // tool finished (exit code)
    done,        // agent finished turn
    error_msg,   // something went wrong
    cancel,      // cancel signal
};

pub const Msg = struct {
    kind: MsgKind,
    len: u16,
    data: [MAX_MSG_LEN]u8,

    pub fn slice(self: *const Msg) []const u8 {
        return self.data[0..self.len];
    }

    pub fn set(self: *Msg, kind: MsgKind, text: []const u8) void {
        self.kind = kind;
        const n = @min(text.len, MAX_MSG_LEN);
        @memcpy(self.data[0..n], text[0..n]);
        self.len = @intCast(n);
    }
};

/// Lock-free SPSC queue using atomic head/tail indices.
/// One goroutine writes (producer), one reads (consumer).
pub fn Queue(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const MASK = capacity - 1;

        slots: [capacity]Msg = undefined,
        head: usize = 0, // consumer reads here (atomic)
        tail: usize = 0, // producer writes here (atomic)

        comptime {
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);
        }

        /// Producer: try to enqueue a message. Returns false if full.
        pub fn push(self: *Self, kind: MsgKind, text: []const u8) bool {
            const tail = @atomicLoad(usize, &self.tail, .monotonic);
            const head = @atomicLoad(usize, &self.head, .acquire);
            if (tail -% head >= capacity) return false; // full

            self.slots[tail & MASK].set(kind, text);
            @atomicStore(usize, &self.tail, tail +% 1, .release);
            return true;
        }

        /// Consumer: try to dequeue a message. Returns null if empty.
        pub fn pop(self: *Self, out: *Msg) bool {
            const head = @atomicLoad(usize, &self.head, .monotonic);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            if (head == tail) return false; // empty

            out.* = self.slots[head & MASK];
            @atomicStore(usize, &self.head, head +% 1, .release);
            return true;
        }

        pub fn isEmpty(self: *const Self) bool {
            const head = @atomicLoad(usize, &self.head, .monotonic);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            return head == tail;
        }
    };
}

/// The two queues that connect main thread <-> agent thread
pub const AgentQueues = struct {
    /// agent → main: streamed output, status, tool calls
    output: Queue(QUEUE_CAPACITY) = .{},
    /// main → agent: query requests
    request: Queue(QUEUE_CAPACITY) = .{},
    /// atomic: agent is currently working
    busy: bool = false,
    /// atomic: main thread requests cancel
    cancel_requested: bool = false,

    pub fn requestCancel(self: *AgentQueues) void {
        @atomicStore(bool, &self.cancel_requested, true, .release);
    }

    pub fn checkCancel(self: *AgentQueues) bool {
        return @atomicLoad(bool, &self.cancel_requested, .acquire);
    }

    pub fn clearCancel(self: *AgentQueues) void {
        @atomicStore(bool, &self.cancel_requested, false, .release);
    }

    pub fn setBusy(self: *AgentQueues, val: bool) void {
        @atomicStore(bool, &self.busy, val, .release);
    }

    pub fn isBusy(self: *const AgentQueues) bool {
        return @atomicLoad(bool, &self.busy, .acquire);
    }
};
