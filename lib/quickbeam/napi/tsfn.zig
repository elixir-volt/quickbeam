const c = @import("common.zig");
const types = @import("../types.zig");

const qjs = c.qjs;
const gpa = c.gpa;
const Status = c.Status;
pub const napi_status = c.napi_status;
pub const napi_env = c.napi_env;
pub const napi_value = c.napi_value;
pub const NapiEnv = c.NapiEnv;
pub const ThreadSafeFunction = c.ThreadSafeFunction;
pub const napi_threadsafe_function = c.napi_threadsafe_function;
const nt = c.napi_types;

pub export fn napi_create_threadsafe_function(
    env_: napi_env,
    func: napi_value,
    _: napi_value,
    _: napi_value,
    max_queue_size: usize,
    initial_thread_count: usize,
    _: ?*anyopaque,
    finalize_cb: c.napi_finalize,
    context: ?*anyopaque,
    call_js_cb: ?nt.napi_threadsafe_function_call_js,
    result: ?*napi_threadsafe_function,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const tsfn = gpa.create(ThreadSafeFunction) catch return env.genericFailure();
    const func_val = c.toVal(func);
    tsfn.* = .{
        .env = env,
        .callback = if (qjs.JS_IsFunction(env.ctx, func_val)) qjs.JS_DupValue(env.ctx, func_val) else null,
        .call_js_cb = call_js_cb,
        .ctx = context,
        .finalize_cb = finalize_cb,
        .max_queue_size = max_queue_size,
        .thread_count = c.std.atomic.Value(i64).init(@intCast(initial_thread_count)),
    };
    r.* = tsfn;
    return env.ok();
}

pub export fn napi_call_threadsafe_function(func_: napi_threadsafe_function, data: ?*anyopaque, is_blocking: nt.napi_threadsafe_function_call_mode) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    func.lock.lock();

    if (func.closing.load(.seq_cst)) {
        func.lock.unlock();
        return @intFromEnum(Status.closing);
    }

    if (is_blocking == nt.napi_tsfn_blocking) {
        while (func.max_queue_size > 0 and func.queue.items.len >= func.max_queue_size) {
            func.condvar.wait(&func.lock);
            if (func.closing.load(.seq_cst)) {
                func.lock.unlock();
                return @intFromEnum(Status.closing);
            }
        }
    } else {
        if (func.max_queue_size > 0 and func.queue.items.len >= func.max_queue_size) {
            func.lock.unlock();
            return @intFromEnum(Status.queue_full);
        }
    }

    func.queue.append(gpa, data) catch {
        func.lock.unlock();
        return @intFromEnum(Status.generic_failure);
    };
    func.lock.unlock();

    if (func.env.runtime_data) |rd| {
        types.enqueue(rd, .{ .napi_tsfn_call = .{ .tsfn = func, .data = null } });
    }

    return @intFromEnum(Status.ok);
}

pub export fn napi_acquire_threadsafe_function(func_: napi_threadsafe_function) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    _ = func.thread_count.fetchAdd(1, .seq_cst);
    return @intFromEnum(Status.ok);
}

pub export fn napi_release_threadsafe_function(func_: napi_threadsafe_function, mode: nt.napi_threadsafe_function_release_mode) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    const prev = func.thread_count.fetchSub(1, .seq_cst);
    if (mode == .abort or prev == 1) {
        func.closing.store(true, .seq_cst);
        func.condvar.broadcast();
    }
    return @intFromEnum(Status.ok);
}

pub export fn napi_ref_threadsafe_function(_: napi_env, _: napi_threadsafe_function) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_unref_threadsafe_function(_: napi_env, _: napi_threadsafe_function) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_get_threadsafe_function_context(func_: napi_threadsafe_function, result: ?*?*anyopaque) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return @intFromEnum(Status.invalid_arg);
    r.* = func.ctx;
    return @intFromEnum(Status.ok);
}
