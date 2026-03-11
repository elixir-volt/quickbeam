pub const std = @import("std");
pub const beam = @import("beam");
pub const e = @import("erl_nif");
pub const qjs = @cImport(@cInclude("quickjs.h"));

pub const gpa = std.heap.c_allocator;

pub var class_ids_mutex: std.Thread.Mutex = .{};

pub const SyncCallSlot = struct {
    result_json: []const u8 = "",
    result_env: ?*e.ErlNifEnv = null,
    result_term: ?e.ErlNifTerm = null,
    ok: bool = false,
    done: std.Thread.ResetEvent = .{},
};

pub const RuntimeData = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    queue_head: ?*MessageNode,
    queue_tail: ?*MessageNode,
    stopped: bool,
    thread: ?std.Thread,
    memory_limit: usize = 256 * 1024 * 1024,
    max_stack_size: usize = 1024 * 1024,
    sync_slots_mutex: std.Thread.Mutex = .{},
    sync_slots: std.AutoHashMapUnmanaged(u64, *SyncCallSlot) = .{},
    deadline: ?i128 = null,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const Message = union(enum) {
    eval: AsyncRequestPayload,
    compile: AsyncRequestPayload,
    call_fn: AsyncCallPayload,
    load_module: AsyncModulePayload,
    load_bytecode: AsyncRequestPayload,
    reset: AsyncRequestPayload,
    resolve_call: CallResponse,
    reject_call: CallResponse,
    resolve_call_term: CallResponseTerm,
    send_message: MessagePayload,
    define_global: SetGlobalPayload,
    memory_usage: AsyncMemoryPayload,
    dom_op: AsyncDomPayload,
    stop,
};

pub const AsyncRequestPayload = struct {
    code: []const u8,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
    timeout_ns: u64 = 0,
};

pub const AsyncCallPayload = struct {
    name: []const u8,
    args_env: ?*e.ErlNifEnv,
    args_term: e.ErlNifTerm,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
    timeout_ns: u64 = 0,
};

pub const AsyncModulePayload = struct {
    name: []const u8,
    code: []const u8,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
};

pub const AsyncMemoryPayload = struct {
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
};

pub const AsyncDomPayload = struct {
    op: DomOp,
    selector: []const u8 = "",
    attr_name: []const u8 = "",
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
};

pub const DomOp = enum {
    find,
    find_all,
    text,
    attr,
    html,
};

pub const CallResponse = struct {
    id: u64,
    json: []const u8,
};

pub const CallResponseTerm = struct {
    id: u64,
    env: ?*e.ErlNifEnv,
    term: e.ErlNifTerm,
    ok: bool,
};

pub const MessagePayload = struct {
    env: ?*e.ErlNifEnv,
    term: e.ErlNifTerm,
};

pub const SetGlobalPayload = struct {
    name: []const u8,
    env: ?*e.ErlNifEnv,
    term: e.ErlNifTerm,
};

pub const MessageNode = struct {
    msg: Message,
    next: ?*MessageNode,
};

// ──────────────────── Reply helper ────────────────────

pub fn send_reply(caller_pid: beam.pid, ref_env: ?*e.ErlNifEnv, ref_term: e.ErlNifTerm, ok: bool, result_env: ?*e.ErlNifEnv, result_term: ?e.ErlNifTerm, result_json: []const u8) void {
    const msg_env = beam.alloc_env();
    const ref_copy = e.enif_make_copy(msg_env, ref_term);

    const result_val = if (result_env) |renv| blk: {
        const copied = e.enif_make_copy(msg_env, result_term.?);
        beam.free_env(renv);
        break :blk copied;
    } else beam.make(result_json, .{ .env = msg_env }).v;

    const tag = if (ok) beam.make_into_atom("ok", .{ .env = msg_env }).v else beam.make_into_atom("error", .{ .env = msg_env }).v;
    const inner = e.enif_make_tuple2(msg_env, tag, result_val);
    const msg = e.enif_make_tuple2(msg_env, ref_copy, inner);

    var pid = caller_pid;
    _ = e.enif_send(null, &pid, msg_env, msg);
    beam.free_env(msg_env);
    if (ref_env) |re| beam.free_env(re);
}

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
