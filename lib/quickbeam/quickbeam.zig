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

fn get_map_uint(env: *e.ErlNifEnv, map: e.ErlNifTerm, key: [:0]const u8) ?usize {
    // SAFETY: out-param written by enif_make_existing_atom_len before use
    var key_atom: e.ErlNifTerm = undefined;
    if (e.enif_make_existing_atom_len(env, key.ptr, key.len, &key_atom, e.ERL_NIF_LATIN1) == 0) return null;
    // SAFETY: out-param written by enif_get_map_value before use
    var val: e.ErlNifTerm = undefined;
    if (e.enif_get_map_value(env, map, key_atom, &val) == 0) return null;
    // SAFETY: out-param written by enif_get_uint64 before use
    var result: u64 = undefined;
    if (e.enif_get_uint64(env, val, &result) == 0) return null;
    return @intCast(result);
}

pub fn start_runtime(owner_pid: beam.pid, opts: beam.term) !RuntimeResource {
    const data = try gpa.create(RuntimeData);
    data.* = .{
        .mutex = .{},
        .cond = .{},
        .queue_head = null,
        .queue_tail = null,
        .stopped = false,
        .thread = null,
    };

    const env = beam.context.env orelse return error.NoEnv;
    if (get_map_uint(env, opts.v, "memory_limit")) |v| {
        data.memory_limit = v;
    }
    if (get_map_uint(env, opts.v, "max_stack_size")) |v| {
        data.max_stack_size = v;
    }

    const res = try RuntimeResource.create(data, .{});

    const min_thread_stack = 2 * 1024 * 1024;
    const thread_stack = @max(data.max_stack_size + min_thread_stack, min_thread_stack);
    data.thread = std.Thread.spawn(.{ .stack_size = thread_stack }, worker.worker_main, .{ data, owner_pid }) catch {
        gpa.destroy(data);
        return error.ThreadSpawn;
    };

    return res;
}

pub fn eval(resource: RuntimeResource, code: []const u8, timeout_ms: u64) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .eval = .{
        .code = code,
        .result = &result,
        .done = &done,
        .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
    } });

    done.wait();
    return make_result(&result);
}

pub fn compile(resource: RuntimeResource, code: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .compile = .{
        .code = code,
        .result = &result,
        .done = &done,
    } });

    done.wait();
    return make_result(&result);
}

pub fn load_bytecode(resource: RuntimeResource, bytecode: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .load_bytecode = .{
        .code = bytecode,
        .result = &result,
        .done = &done,
    } });

    done.wait();
    return make_result(&result);
}

pub fn call_function(resource: RuntimeResource, name: []const u8, args: beam.term, timeout_ms: u64) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    // Copy args to a private env so they outlive the NIF call
    const args_env = beam.alloc_env();
    const args_copy = e.enif_make_copy(args_env, args.v);

    enqueue(data, .{ .call_fn = .{
        .name = name,
        .args_env = args_env,
        .args_term = args_copy,
        .result = &result,
        .done = &done,
        .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
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

pub fn resolve_call_term(resource: RuntimeResource, call_id: u64, value: beam.term) beam.term {
    const data = resource.unpack();

    data.sync_slots_mutex.lock();
    const slot = data.sync_slots.get(call_id);
    data.sync_slots_mutex.unlock();

    if (slot) |s| {
        const term_env = beam.alloc_env();
        s.result_env = term_env;
        s.result_term = e.enif_make_copy(term_env, value.v);
        s.ok = true;
        s.done.set();
        return beam.make(.ok, .{});
    }

    const msg_env = beam.alloc_env();
    const copied = e.enif_make_copy(msg_env, value.v);
    enqueue(data, .{ .resolve_call_term = .{ .id = call_id, .env = msg_env, .term = copied, .ok = true } });
    return beam.make(.ok, .{});
}

pub fn reject_call_term(resource: RuntimeResource, call_id: u64, reason: []const u8) beam.term {
    const data = resource.unpack();

    data.sync_slots_mutex.lock();
    const slot = data.sync_slots.get(call_id);
    data.sync_slots_mutex.unlock();

    if (slot) |s| {
        const term_env = beam.alloc_env();
        s.result_env = term_env;
        s.result_term = beam.make(reason, .{ .env = term_env }).v;
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

pub fn dom_find(resource: RuntimeResource, selector: []const u8) beam.term {
    return dom_op(resource, .find, selector, "");
}

pub fn dom_find_all(resource: RuntimeResource, selector: []const u8) beam.term {
    return dom_op(resource, .find_all, selector, "");
}

pub fn dom_text(resource: RuntimeResource, selector: []const u8) beam.term {
    return dom_op(resource, .text, selector, "");
}

pub fn dom_attr(resource: RuntimeResource, selector: []const u8, attr_name: []const u8) beam.term {
    return dom_op(resource, .attr, selector, attr_name);
}

pub fn dom_html(resource: RuntimeResource) beam.term {
    return dom_op(resource, .html, "", "");
}

fn dom_op(resource: RuntimeResource, op: types.DomOp, selector: []const u8, attr_name: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    var payload = types.DomOpPayload{
        .op = op,
        .selector = selector,
        .attr_name = attr_name,
        .result = &result,
        .done = &done,
    };

    enqueue(resource.unpack(), .{ .dom_op = &payload });
    done.wait();
    return make_result(&result);
}

pub fn send_message(resource: RuntimeResource, message: beam.term) beam.term {
    const msg_env = beam.alloc_env();
    const copied = e.enif_make_copy(msg_env, message.v);
    enqueue(resource.unpack(), .{ .send_message = .{ .env = msg_env, .term = copied } });
    return beam.make(.ok, .{});
}
