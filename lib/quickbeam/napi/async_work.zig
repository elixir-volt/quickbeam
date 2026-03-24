const c = @import("common.zig");
const types = @import("../types.zig");

const gpa = c.gpa;
const Status = c.Status;
pub const napi_status = c.napi_status;
pub const napi_env = c.napi_env;
pub const napi_value = c.napi_value;
pub const napi_async_work = c.napi_async_work;
pub const AsyncWork = c.AsyncWork;
const nt = c.napi_types;

pub export fn napi_create_async_work(
    env_: napi_env,
    _: napi_value,
    _: napi_value,
    execute_: ?nt.napi_async_execute_callback,
    complete: ?nt.napi_async_complete_callback,
    data: ?*anyopaque,
    result: ?*napi_async_work,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const execute = execute_ orelse return env.invalidArg();

    const work = gpa.create(AsyncWork) catch return env.genericFailure();
    work.* = .{
        .env = env,
        .execute = execute,
        .complete = if (complete) |cb| cb else null,
        .data = data,
        .rd = env.runtime_data,
    };
    r.* = work;
    return env.ok();
}

pub export fn napi_delete_async_work(env_: napi_env, work_: napi_async_work) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const work: *AsyncWork = work_ orelse return env.invalidArg();
    if (work.status.load(.seq_cst) == .started and work.thread == null) return env.genericFailure();
    work.deinit();
    return env.ok();
}

pub export fn napi_queue_async_work(env_: napi_env, work_: napi_async_work) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const work: *AsyncWork = work_ orelse return env.invalidArg();
    if (work.rd == null) return env.genericFailure();

    work.thread = c.std.Thread.spawn(.{}, asyncWorkRunner, .{work}) catch return env.genericFailure();
    return env.ok();
}

fn asyncWorkRunner(work: *AsyncWork) void {
    work.status.store(.started, .release);
    work.execute(work.env, work.data);

    _ = if (work.status.cmpxchgStrong(.started, .completed, .seq_cst, .seq_cst) == null)
        AsyncWork.AsyncStatus.completed
    else
        AsyncWork.AsyncStatus.cancelled;

    if (work.rd) |rd| {
        types.enqueue(rd, .{ .napi_async_complete = .{ .work = work } });
    }
}

pub export fn napi_cancel_async_work(env_: napi_env, work_: napi_async_work) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const work: *AsyncWork = work_ orelse return env.invalidArg();
    if (work.status.cmpxchgStrong(.pending, .cancelled, .seq_cst, .seq_cst) == null) {
        return env.ok();
    }
    return env.genericFailure();
}
