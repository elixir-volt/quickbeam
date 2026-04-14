const types = @import("types.zig");
const worker = @import("worker.zig");

pub const std = types.std;
pub const beam = types.beam;
pub const e = types.e;
pub const qjs = types.qjs;
pub const gpa = types.gpa;

pub const ContextId = u64;

pub const ContextEntry = struct {
    state: worker.WorkerState,
    rd: types.RuntimeData,
    owner_pid: beam.pid,
    id: ContextId,
};

pub const PoolMessage = union(enum) {
    create_context: CreateContextPayload,
    destroy_context: DestroyContextPayload,
    ctx_eval: CtxEvalPayload,
    ctx_load_bytecode: CtxEvalPayload,
    ctx_call_fn: CtxCallPayload,
    ctx_reset: CtxResetPayload,
    ctx_send_message: CtxMessagePayload,
    ctx_define_global: CtxDefineGlobalPayload,
    ctx_get_global: CtxGetGlobalPayload,
    ctx_memory_usage: CtxMemoryPayload,
    ctx_dom_op: CtxDomPayload,
    ctx_resolve_call: CtxCallResponse,
    ctx_reject_call: CtxCallResponse,
    ctx_resolve_call_term: CtxCallResponseTerm,
    stop,
};

pub const CreateContextPayload = struct {
    context_id: ContextId,
    owner_pid: beam.pid,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
    memory_limit: usize = 0,
    max_reductions: i64 = 0,
};

pub const DestroyContextPayload = struct {
    context_id: ContextId,
};

pub const CtxEvalPayload = struct {
    context_id: ContextId,
    code: []const u8,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
    timeout_ns: u64 = 0,
};

pub const CtxCallPayload = struct {
    context_id: ContextId,
    name: []const u8,
    args_env: ?*e.ErlNifEnv,
    args_term: e.ErlNifTerm,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
    timeout_ns: u64 = 0,
};

pub const CtxResetPayload = struct {
    context_id: ContextId,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
};

pub const CtxMessagePayload = struct {
    context_id: ContextId,
    env: ?*e.ErlNifEnv,
    term: e.ErlNifTerm,
};

pub const CtxDefineGlobalPayload = struct {
    context_id: ContextId,
    name: [:0]const u8,
    env: ?*e.ErlNifEnv,
    term: e.ErlNifTerm,
};

pub const CtxGetGlobalPayload = struct {
    context_id: ContextId,
    name: [:0]const u8,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
};

pub const CtxMemoryPayload = struct {
    context_id: ContextId,
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
};

pub const CtxDomPayload = struct {
    context_id: ContextId,
    op: types.DomOp,
    selector: []const u8 = "",
    attr_name: []const u8 = "",
    caller_pid: beam.pid,
    ref_env: ?*e.ErlNifEnv,
    ref_term: e.ErlNifTerm,
};

pub const CtxCallResponse = struct {
    context_id: ContextId,
    id: u64,
    json: []const u8,
};

pub const CtxCallResponseTerm = struct {
    context_id: ContextId,
    id: u64,
    env: ?*e.ErlNifEnv,
    term: e.ErlNifTerm,
    ok: bool,
};

pub const PoolMessageNode = struct {
    msg: PoolMessage,
    next: ?*PoolMessageNode,
};

pub const PoolData = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    queue_head: ?*PoolMessageNode,
    queue_tail: ?*PoolMessageNode,
    stopped: bool,
    thread: ?std.Thread,
    memory_limit: usize = 256 * 1024 * 1024,
    max_stack_size: usize = 8 * 1024 * 1024,
    max_convert_depth: u32 = 32,
    max_convert_nodes: u32 = 10_000,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deadline: ?i128 = null,
    // Maps context_id → pointer to context's RuntimeData (for sync call resolution)
    rd_map_mutex: std.Thread.Mutex = .{},
    rd_map: std.AutoHashMapUnmanaged(ContextId, *types.RuntimeData) = .{},
};

pub fn pool_enqueue(pd: *PoolData, msg: PoolMessage) void {
    const node = gpa.create(PoolMessageNode) catch return;
    node.* = .{ .msg = msg, .next = null };

    pd.mutex.lock();
    defer pd.mutex.unlock();

    if (pd.queue_tail) |tail| {
        tail.next = node;
    } else {
        pd.queue_head = node;
    }
    pd.queue_tail = node;
    pd.cond.signal();
}

pub fn pool_dequeue(pd: *PoolData) ?PoolMessage {
    pd.mutex.lock();
    defer pd.mutex.unlock();

    const node = pd.queue_head orelse return null;
    pd.queue_head = node.next;
    if (pd.queue_head == null) pd.queue_tail = null;
    const msg = node.msg;
    gpa.destroy(node);
    return msg;
}

pub fn pool_dequeue_blocking(pd: *PoolData, timeout_ns: ?u64) ?PoolMessage {
    pd.mutex.lock();

    while (pd.queue_head == null and !pd.stopped) {
        if (timeout_ns) |t| {
            pd.cond.timedWait(&pd.mutex, t) catch break;
        } else {
            pd.cond.wait(&pd.mutex);
        }
    }

    const node = pd.queue_head;
    if (node) |n| {
        pd.queue_head = n.next;
        if (pd.queue_head == null) pd.queue_tail = null;
        pd.mutex.unlock();
        const msg = n.msg;
        gpa.destroy(n);
        return msg;
    }

    pd.mutex.unlock();
    return null;
}
