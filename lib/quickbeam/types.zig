pub const std = @import("std");
pub const beam = @import("beam");
pub const e = @import("erl_nif");
pub const qjs = @cImport(@cInclude("quickjs.h"));

pub const gpa = std.heap.c_allocator;

pub const RuntimeData = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    queue_head: ?*MessageNode,
    queue_tail: ?*MessageNode,
    stopped: bool,
    thread: ?std.Thread,
};

pub const MemoryUsageResult = struct {
    malloc_size: i64 = 0,
    malloc_count: i64 = 0,
    memory_used_size: i64 = 0,
    atom_count: i64 = 0,
    str_count: i64 = 0,
    obj_count: i64 = 0,
    prop_count: i64 = 0,
    shape_count: i64 = 0,
    js_func_count: i64 = 0,
    c_func_count: i64 = 0,
    array_count: i64 = 0,
    done: ?*std.Thread.ResetEvent = null,
};

pub const Message = union(enum) {
    eval: RequestPayload,
    call_fn: CallPayload,
    load_module: ModulePayload,
    reset: RequestPayload,
    resolve_call: CallResponse,
    reject_call: CallResponse,
    send_message: StringPayload,
    memory_usage: *MemoryUsageResult,
    stop,
};

pub const RequestPayload = struct {
    code: []const u8,
    result: *Result,
    done: *std.Thread.ResetEvent,
};

pub const CallPayload = struct {
    name: []const u8,
    args_json: []const u8,
    result: *Result,
    done: *std.Thread.ResetEvent,
};

pub const ModulePayload = struct {
    name: []const u8,
    code: []const u8,
    result: *Result,
    done: *std.Thread.ResetEvent,
};

pub const CallResponse = struct {
    id: u64,
    json: []const u8,
};

pub const StringPayload = struct {
    data: []const u8,
};

pub const Result = struct {
    ok: bool = false,
    json: []const u8 = "",
    // New: direct BEAM term result (bypasses JSON)
    env: ?*e.ErlNifEnv = null,
    term: ?e.ErlNifTerm = null,
};

pub const MessageNode = struct {
    msg: Message,
    next: ?*MessageNode,
};

// ──────────────────── Message queue ────────────────────

pub fn enqueue(rd: *RuntimeData, msg: Message) void {
    const node = gpa.create(MessageNode) catch return;
    node.* = .{ .msg = msg, .next = null };

    rd.mutex.lock();
    defer rd.mutex.unlock();

    if (rd.queue_tail) |tail| {
        tail.next = node;
    } else {
        rd.queue_head = node;
    }
    rd.queue_tail = node;
    rd.cond.signal();
}

pub fn dequeue(rd: *RuntimeData) ?Message {
    rd.mutex.lock();
    defer rd.mutex.unlock();

    const node = rd.queue_head orelse return null;
    rd.queue_head = node.next;
    if (rd.queue_head == null) rd.queue_tail = null;
    const msg = node.msg;
    gpa.destroy(node);
    return msg;
}

pub fn dequeue_blocking(rd: *RuntimeData, timeout_ns: ?u64) ?Message {
    rd.mutex.lock();

    while (rd.queue_head == null and !rd.stopped) {
        if (timeout_ns) |t| {
            rd.cond.timedWait(&rd.mutex, t) catch break;
        } else {
            rd.cond.wait(&rd.mutex);
        }
    }

    const node = rd.queue_head;
    if (node) |n| {
        rd.queue_head = n.next;
        if (rd.queue_head == null) rd.queue_tail = null;
        rd.mutex.unlock();
        const msg = n.msg;
        gpa.destroy(n);
        return msg;
    }

    rd.mutex.unlock();
    return null;
}
