// agent_queue.zig - lock-free SPSC ring buffer for agent <-> shell communication
// Single Producer Single Consumer: agent thread writes, main thread reads (output queue)
// and main thread writes, agent thread reads (request queue)

const std = @import("std");

pub const MAX_MSG_LEN = 4096;
pub const QUEUE_CAPACITY = 64; // power of 2

pub const MsgKind = enum(u8) {
    text_delta,       // streamed text chunk from model
    tool_call,        // agent is running a tool (name + cmd)
    tool_done,        // tool finished (exit code)
    done,             // agent finished turn
    error_msg,        // something went wrong
    cancel,           // cancel signal
    confirm_request,  // agent -> main: "Run this command? [y/N]"
    confirm_response, // main -> agent: "y" or "n"
    usage_info,       // agent -> main: token usage "input:N output:N cost:$X.XX"
    router_info,      // agent -> main: routing decision "agent -> medium (med cost)"
    add_task,         // main -> agent: queue a task for autonomous processing
    spawn_worker,     // main -> agent: spawn a full-tools worker subagent
    agent_status_req, // main -> agent: request subagent status listing
    agent_status,     // agent -> main: subagent status line
    agent_tree_req,   // main -> agent: request tree-structured agent data
    agent_tree_node,  // agent -> main: binary tree node (depth|status|type|id|desc|result_preview)
    agent_result_req, // main -> agent: request full result for agent id (payload = id)
    agent_result,     // agent -> main: result text chunk (may be split across messages)

    /// Returns true if this message kind is an output (agent → main) message.
    pub fn isOutput(self: MsgKind) bool {
        return switch (self) {
            .text_delta, .tool_call, .tool_done, .done, .error_msg, .cancel,
            .confirm_request, .usage_info, .router_info, .agent_status,
            .agent_tree_node, .agent_result => true,
            .confirm_response, .add_task, .spawn_worker, .agent_status_req,
            .agent_tree_req, .agent_result_req => false,
        };
    }
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

        /// Producer: enqueue a message, spinning until space is available.
        pub fn pushWait(self: *Self, kind: MsgKind, text: []const u8) void {
            while (!self.push(kind, text)) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
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
    /// shared bulletin board — the commons (pointer, shared across all agent threads)
    bulletin: *Bulletin = undefined,

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

// ── Bulletin Board ─────────────────────────────────────────────────────
// Shared broadcast log: any agent thread can post, all readers see everything.
// No hierarchy, no ownership. The commons.
//
// MPSC (many producers, each reader tracks own position) via atomic CAS on tail.
// Slots are immutable once written — readers just chase the tail.

pub const BULLETIN_CAPACITY = 128; // power of 2
const BULLETIN_MASK = BULLETIN_CAPACITY - 1;

pub const PostKind = enum(u8) {
    /// Agent found something relevant to share with all peers
    discovery,
    /// Agent is escalating — "stop, look at this" (overrides parent plans)
    escalate,
    /// Agent requesting peer help — "someone grab this subtask"
    request_peer,
    /// Agent broadcasting its status change
    status_change,
    /// Agent voting on a decision (consensus)
    vote,
};

pub const Post = struct {
    kind: PostKind = .discovery,
    /// Who posted (agent id, e.g. "main", "1", "2", "t0")
    author: [16]u8 = undefined,
    author_len: u8 = 0,
    /// Depth of the posting agent (0=main, 1=subagent, etc.)
    depth: u8 = 0,
    /// Message content
    data: [512]u8 = undefined,
    len: u16 = 0,
    /// Monotonic timestamp (millis)
    timestamp: i64 = 0,
    /// Sequence number (set by bulletin on write)
    seq: u64 = 0,

    pub fn authorSlice(self: *const Post) []const u8 {
        return self.author[0..self.author_len];
    }

    pub fn slice(self: *const Post) []const u8 {
        return self.data[0..self.len];
    }

    pub fn setAuthor(self: *Post, id: []const u8) void {
        const n: u8 = @intCast(@min(id.len, 16));
        @memcpy(self.author[0..n], id[0..n]);
        self.author_len = n;
    }

    pub fn setData(self: *Post, text: []const u8) void {
        const n: u16 = @intCast(@min(text.len, 512));
        @memcpy(self.data[0..n], text[0..n]);
        self.len = n;
    }
};

/// Lock-free broadcast log. Many producers (CAS on tail), many readers (each tracks own cursor).
/// Old posts are overwritten when the ring wraps — readers that fall behind lose history.
pub const Bulletin = struct {
    slots: [BULLETIN_CAPACITY]Post = [_]Post{.{}} ** BULLETIN_CAPACITY,
    tail: usize = 0, // atomic: next write position (monotonically increasing)

    /// Post a message to the bulletin. Thread-safe (CAS loop).
    pub fn post(self: *Bulletin, kind: PostKind, author: []const u8, depth: u8, text: []const u8) void {
        // CAS loop to claim a slot
        while (true) {
            const cur_tail = @atomicLoad(usize, &self.tail, .acquire);
            if (@cmpxchgWeak(usize, &self.tail, cur_tail, cur_tail +% 1, .release, .monotonic) == null) {
                // Won the slot at cur_tail
                const slot = &self.slots[cur_tail & BULLETIN_MASK];
                slot.kind = kind;
                slot.setAuthor(author);
                slot.depth = depth;
                slot.setData(text);
                slot.timestamp = std.time.milliTimestamp();
                slot.seq = cur_tail;
                return;
            }
            // Lost CAS race, retry
        }
    }

    /// Read posts newer than `cursor`. Returns new cursor position.
    /// Caller provides a buffer to fill with post copies.
    pub fn read(self: *const Bulletin, cursor: usize, out: []Post) struct { count: usize, new_cursor: usize } {
        const current_tail = @atomicLoad(usize, &self.tail, .acquire);
        var pos = cursor;
        var count: usize = 0;
        while (pos < current_tail and count < out.len) {
            // Check if this slot hasn't been overwritten (ring wrapped)
            if (current_tail -% pos > BULLETIN_CAPACITY) {
                // Too far behind — skip to oldest available
                pos = current_tail -% BULLETIN_CAPACITY;
                continue;
            }
            out[count] = self.slots[pos & BULLETIN_MASK];
            // Verify the post we read is the one we expected (not overwritten mid-read)
            if (out[count].seq == pos) {
                count += 1;
            }
            pos +%= 1;
        }
        return .{ .count = count, .new_cursor = current_tail };
    }

    /// Get the current tail position (for initializing a reader's cursor).
    pub fn position(self: *const Bulletin) usize {
        return @atomicLoad(usize, &self.tail, .acquire);
    }
};
