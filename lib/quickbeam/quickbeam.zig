const types = @import("types.zig");
const worker = @import("worker.zig");
const std = types.std;
const beam = @import("beam");
const e = types.e;
const gpa = types.gpa;
const RuntimeData = types.RuntimeData;
const Result = types.Result;
const enqueue = types.enqueue;

// ──────────────────── Resource ────────────────────

pub const RuntimeResource = beam.Resource(*RuntimeData, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(ptr: **RuntimeData) void {
            const data = ptr.*;
            enqueue(data, .{ .stop = {} });
            if (data.thread) |t_| t_.join();
            gpa.destroy(data);
        }
    },
});

// ──────────────────── Result helper ────────────────────

fn make_result(result: *Result) beam.term {
    if (result.term) |t| {
        const copied = beam.term{ .v = e.enif_make_copy(beam.context.env, t) };
        beam.free_env(result.env.?);
        if (result.ok) {
            return beam.make(.{ .ok, copied }, .{});
        } else {
            return beam.make(.{ .@"error", copied }, .{});
        }
    }
    if (result.ok) {
        return beam.make(.{ .ok, result.json }, .{});
    } else {
        return beam.make(.{ .@"error", result.json }, .{});
    }
}

// ──────────────────── NIF entry points ────────────────────

pub fn start_runtime(owner_pid: beam.pid) !RuntimeResource {
    const data = try gpa.create(RuntimeData);
    data.* = .{
        .mutex = .{},
        .cond = .{},
        .queue_head = null,
        .queue_tail = null,
        .stopped = false,
        .thread = null,
    };

    const res = try RuntimeResource.create(data, .{});

    data.thread = std.Thread.spawn(.{}, worker.worker_main, .{ data, owner_pid }) catch {
        gpa.destroy(data);
        return error.ThreadSpawn;
    };

    return res;
}

pub fn eval(resource: RuntimeResource, code: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .eval = .{
        .code = code,
        .result = &result,
        .done = &done,
    } });

    done.wait();
    return make_result(&result);
}

pub fn call_function(resource: RuntimeResource, name: []const u8, args_json: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .call_fn = .{
        .name = name,
        .args_json = args_json,
        .result = &result,
        .done = &done,
    } });

    done.wait();
    return make_result(&result);
}

pub fn load_module(resource: RuntimeResource, name: []const u8, code: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .load_module = .{
        .name = name,
        .code = code,
        .result = &result,
        .done = &done,
    } });

    done.wait();
    return make_result(&result);
}

pub fn reset_runtime(resource: RuntimeResource) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .reset = .{
        .code = "",
        .result = &result,
        .done = &done,
    } });

    done.wait();
    return make_result(&result);
}

pub fn stop_runtime(resource: RuntimeResource) beam.term {
    const data = resource.unpack();
    enqueue(data, .{ .stop = {} });
    if (data.thread) |th| {
        th.join();
        data.thread = null;
    }
    return beam.make(.ok, .{});
}

pub fn resolve_call(resource: RuntimeResource, call_id: u64, value_json: []const u8) beam.term {
    const data = resource.unpack();

    // Check for sync call slot first
    data.sync_slots_mutex.lock();
    const slot = data.sync_slots.get(call_id);
    data.sync_slots_mutex.unlock();

    if (slot) |s| {
        s.result_json = gpa.dupe(u8, value_json) catch "";
        s.ok = true;
        s.done.set();
        return beam.make(.ok, .{});
    }

    const json_copy = gpa.dupe(u8, value_json) catch return beam.make(.ok, .{});
    enqueue(data, .{ .resolve_call = .{ .id = call_id, .json = json_copy } });
    return beam.make(.ok, .{});
}

pub fn reject_call(resource: RuntimeResource, call_id: u64, reason: []const u8) beam.term {
    const data = resource.unpack();

    // Check for sync call slot first
    data.sync_slots_mutex.lock();
    const slot = data.sync_slots.get(call_id);
    data.sync_slots_mutex.unlock();

    if (slot) |s| {
        s.result_json = gpa.dupe(u8, reason) catch "";
        s.ok = false;
        s.done.set();
        return beam.make(.ok, .{});
    }

    const reason_copy = gpa.dupe(u8, reason) catch return beam.make(.ok, .{});
    enqueue(data, .{ .reject_call = .{ .id = call_id, .json = reason_copy } });
    return beam.make(.ok, .{});
}

pub fn memory_usage(resource: RuntimeResource) beam.term {
    var result = types.MemoryUsageResult{};
    var done = std.Thread.ResetEvent{};
    result.done = &done;

    enqueue(resource.unpack(), .{ .memory_usage = &result });
    done.wait();

    return beam.make(.{
        .malloc_size = result.malloc_size,
        .malloc_count = result.malloc_count,
        .memory_used_size = result.memory_used_size,
        .atom_count = result.atom_count,
        .str_count = result.str_count,
        .obj_count = result.obj_count,
        .prop_count = result.prop_count,
        .shape_count = result.shape_count,
        .js_func_count = result.js_func_count,
        .c_func_count = result.c_func_count,
        .array_count = result.array_count,
    }, .{});
}

pub fn send_message(resource: RuntimeResource, json: []const u8) beam.term {
    const json_copy = gpa.dupe(u8, json) catch return beam.make(.ok, .{});
    enqueue(resource.unpack(), .{ .send_message = .{ .data = json_copy } });
    return beam.make(.ok, .{});
}
