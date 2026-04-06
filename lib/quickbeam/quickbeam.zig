const types = @import("types.zig");
const worker = @import("worker.zig");
const ct = @import("context_types.zig");
const context_worker = @import("context_worker.zig");
pub const napi = @import("napi.zig");
pub const wasm_nif = @import("wasm_nif.zig");
pub const WasmModuleResource = wasm_nif.WasmModuleResource;
pub const WasmInstanceResource = wasm_nif.WasmInstanceResource;
pub const wasm_compile = wasm_nif.wasm_compile;
pub const wasm_start = wasm_nif.wasm_start;
pub fn wasm_start_with_imports(mod_res: WasmModuleResource, runtime_res: RuntimeResource, imports: beam.term, stack_size: u32, heap_size: u32) beam.term {
    return wasm_nif.wasm_start_with_imports_internal(mod_res, runtime_res.unpack(), imports, stack_size, heap_size);
}
pub const wasm_stop = wasm_nif.wasm_stop;
pub const wasm_call = wasm_nif.wasm_call;
pub const wasm_memory_size = wasm_nif.wasm_memory_size;
pub const wasm_memory_grow = wasm_nif.wasm_memory_grow;
pub const wasm_read_memory = wasm_nif.wasm_read_memory;
pub const wasm_write_memory = wasm_nif.wasm_write_memory;
pub const wasm_read_global = wasm_nif.wasm_read_global;
pub const wasm_write_global = wasm_nif.wasm_write_global;

export fn quickbeam_wasm_host_invoke_js(runtime_data: ?*anyopaque, callback_name_z: [*:0]const u8, signature_z: [*:0]const u8, raw_args: [*]u64, err_buf: [*]u8, err_buf_size: u32) bool {
    return worker.quickbeam_wasm_host_invoke_js_impl(runtime_data, callback_name_z, signature_z, raw_args, err_buf, err_buf_size);
}

const std = types.std;
const beam = @import("beam");
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;
const RuntimeData = types.RuntimeData;
const enqueue = types.enqueue;
const pool_enqueue = ct.pool_enqueue;

// ──────────────────── Resource ────────────────────

pub const RuntimeResource = beam.Resource(*RuntimeData, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(ptr: **RuntimeData) void {
            const data = ptr.*;
            data.shutting_down.store(true, .release);

            data.sync_slots_mutex.lock();
            var it = data.sync_slots.valueIterator();
            while (it.next()) |slot| {
                slot.*.ok = false;
                slot.*.result_json = "runtime shutting down";
                slot.*.done.set();
            }
            data.sync_slots_mutex.unlock();

            enqueue(data, .{ .stop = {} });
            if (data.thread) |t_| t_.join();
            gpa.destroy(data);
        }
    },
});

// ──────────────────── NIF entry points ────────────────────

fn get_map_uint(env: *e.ErlNifEnv, map: e.ErlNifTerm, key: [:0]const u8) ?usize {
    // SAFETY: enif_make_existing_atom_len initializes key_atom on success before use.
    var key_atom: e.ErlNifTerm = undefined;
    if (e.enif_make_existing_atom_len(env, key.ptr, key.len, &key_atom, e.ERL_NIF_LATIN1) == 0) return null;
    // SAFETY: enif_get_map_value initializes val on success before use.
    var val: e.ErlNifTerm = undefined;
    if (e.enif_get_map_value(env, map, key_atom, &val) == 0) return null;
    // SAFETY: enif_get_uint64 initializes result on success before use.
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
    if (get_map_uint(env, opts.v, "max_convert_depth")) |v| {
        data.max_convert_depth = @intCast(v);
    }
    if (get_map_uint(env, opts.v, "max_convert_nodes")) |v| {
        data.max_convert_nodes = @intCast(v);
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
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const code_copy = gpa.dupe(u8, code) catch return beam.make(.{ .@"error", "OOM" }, .{});

    enqueue(data, .{ .eval = .{
        .code = code_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
        .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn compile(resource: RuntimeResource, code: []const u8) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const code_copy = gpa.dupe(u8, code) catch return beam.make(.{ .@"error", "OOM" }, .{});

    enqueue(data, .{ .compile = .{
        .code = code_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn load_bytecode(resource: RuntimeResource, bytecode: []const u8) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const code_copy = gpa.dupe(u8, bytecode) catch return beam.make(.{ .@"error", "OOM" }, .{});

    enqueue(data, .{ .load_bytecode = .{
        .code = code_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn call_function(resource: RuntimeResource, name: []const u8, args: beam.term, timeout_ms: u64) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const args_env = beam.alloc_env();
    const args_copy = e.enif_make_copy(args_env, args.v);

    const name_copy = gpa.dupe(u8, name) catch return beam.make(.{ .@"error", "OOM" }, .{});

    enqueue(data, .{ .call_fn = .{
        .name = name_copy,
        .args_env = args_env,
        .args_term = args_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
        .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn load_module(resource: RuntimeResource, name: []const u8, code: []const u8) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const name_copy = gpa.dupe(u8, name) catch return beam.make(.{ .@"error", "OOM" }, .{});
    const code_copy = gpa.dupe(u8, code) catch {
        gpa.free(name_copy);
        return beam.make(.{ .@"error", "OOM" }, .{});
    };

    enqueue(data, .{ .load_module = .{
        .name = name_copy,
        .code = code_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn reset_runtime(resource: RuntimeResource) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    enqueue(data, .{ .reset = .{
        .code = "",
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn load_addon(resource: RuntimeResource, path: []const u8, global_name: []const u8) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const path_copy = gpa.dupeZ(u8, path) catch return beam.make(.{ .@"error", "OOM" }, .{});
    const name_copy: ?[:0]const u8 = if (global_name.len > 0)
        gpa.dupeZ(u8, global_name) catch {
            gpa.free(path_copy);
            return beam.make(.{ .@"error", "OOM" }, .{});
        }
    else
        null;

    enqueue(data, .{ .load_addon = .{
        .path = path_copy,
        .global_name = name_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn stop_runtime(resource: RuntimeResource) beam.term {
    const data = resource.unpack();

    data.shutting_down.store(true, .release);

    data.sync_slots_mutex.lock();
    var it = data.sync_slots.valueIterator();
    while (it.next()) |slot| {
        slot.*.ok = false;
        slot.*.result_json = "runtime shutting down";
        slot.*.done.set();
    }
    data.sync_slots_mutex.unlock();

    enqueue(data, .{ .stop = {} });
    if (data.thread) |th| {
        th.join();
        data.thread = null;
    }
    return beam.make(.ok, .{});
}

pub fn resolve_call(resource: RuntimeResource, call_id: u64, value_json: []const u8) beam.term {
    const data = resource.unpack();

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
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    enqueue(data, .{ .memory_usage = .{
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
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
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const sel_copy = gpa.dupe(u8, selector) catch return beam.make(.{ .@"error", "OOM" }, .{});
    const attr_copy = gpa.dupe(u8, attr_name) catch {
        gpa.free(sel_copy);
        return beam.make(.{ .@"error", "OOM" }, .{});
    };

    enqueue(data, .{ .dom_op = .{
        .op = op,
        .selector = sel_copy,
        .attr_name = attr_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn send_message(resource: RuntimeResource, message: beam.term) beam.term {
    const msg_env = beam.alloc_env();
    const copied = e.enif_make_copy(msg_env, message.v);
    enqueue(resource.unpack(), .{ .send_message = .{ .env = msg_env, .term = copied } });
    return beam.make(.ok, .{});
}

pub fn define_global(resource: RuntimeResource, name: []const u8, value: beam.term) beam.term {
    const val_env = beam.alloc_env();
    const copied = e.enif_make_copy(val_env, value.v);
    const name_copy = types.gpa.dupeZ(u8, name) catch return beam.make(.{ .@"error", "enomem" }, .{});
    enqueue(resource.unpack(), .{ .define_global = .{ .name = name_copy, .env = val_env, .term = copied } });
    return beam.make(.ok, .{});
}

pub fn snapshot_globals(resource: RuntimeResource) beam.term {
    enqueue(resource.unpack(), .{ .snapshot_globals = .{} });
    return beam.make(.ok, .{});
}

pub fn list_globals(resource: RuntimeResource, user_only: u8) beam.term {
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);
    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    enqueue(resource.unpack(), .{ .list_globals = .{ .user_only = user_only != 0, .caller_pid = caller_pid, .ref_env = ref_env, .ref_term = ref_term } });
    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn delete_globals(resource: RuntimeResource, names: []const beam.term) beam.term {
    var name_slices = types.gpa.alloc([:0]const u8, names.len) catch return beam.make(.{ .@"error", "OOM" }, .{});
    for (names, 0..) |name_term, i| {
        const name_str = beam.get([]const u8, name_term, .{}) catch {
            for (0..i) |j| types.gpa.free(name_slices[j]);
            types.gpa.free(name_slices);
            return beam.make(.{ .@"error", "bad_name" }, .{});
        };
        name_slices[i] = types.gpa.dupeZ(u8, name_str) catch {
            for (0..i) |j| types.gpa.free(name_slices[j]);
            types.gpa.free(name_slices);
            return beam.make(.{ .@"error", "OOM" }, .{});
        };
    }
    enqueue(resource.unpack(), .{ .delete_globals = .{ .names = name_slices } });
    return beam.make(.ok, .{});
}

pub fn get_global(resource: RuntimeResource, name: []const u8) beam.term {
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});
    const name_copy = types.gpa.dupeZ(u8, name) catch return beam.make(.{ .@"error", "enomem" }, .{});
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);
    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    enqueue(resource.unpack(), .{ .get_global = .{ .name = name_copy, .caller_pid = caller_pid, .ref_env = ref_env, .ref_term = ref_term } });
    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

// ──────────────────── Context Pool ────────────────────

pub const PoolResource = beam.Resource(*ct.PoolData, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(ptr: **ct.PoolData) void {
            const data = ptr.*;
            data.shutting_down.store(true, .release);
            pool_enqueue(data, .{ .stop = {} });
            if (data.thread) |t_| t_.join();
            gpa.destroy(data);
        }
    },
});

pub fn pool_start(opts: beam.term) !PoolResource {
    const data = try gpa.create(ct.PoolData);
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
    if (get_map_uint(env, opts.v, "max_convert_depth")) |v| {
        data.max_convert_depth = @intCast(v);
    }
    if (get_map_uint(env, opts.v, "max_convert_nodes")) |v| {
        data.max_convert_nodes = @intCast(v);
    }

    const res = try PoolResource.create(data, .{});

    const min_thread_stack = 2 * 1024 * 1024;
    const thread_stack = @max(data.max_stack_size + min_thread_stack, min_thread_stack);
    data.thread = std.Thread.spawn(.{ .stack_size = thread_stack }, context_worker.pool_worker_main, .{data}) catch {
        gpa.destroy(data);
        return error.ThreadSpawn;
    };

    return res;
}

pub fn pool_stop(resource: PoolResource) beam.term {
    const data = resource.unpack();
    data.shutting_down.store(true, .release);
    pool_enqueue(data, .{ .stop = {} });
    if (data.thread) |th| {
        th.join();
        data.thread = null;
    }
    return beam.make(.ok, .{});
}

pub fn pool_create_context(resource: PoolResource, context_id: u64, owner_pid: beam.pid, memory_limit: u64, max_reductions: i64) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    pool_enqueue(data, .{ .create_context = .{
        .context_id = context_id,
        .owner_pid = owner_pid,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
        .memory_limit = memory_limit,
        .max_reductions = max_reductions,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn pool_destroy_context(resource: PoolResource, context_id: u64) beam.term {
    pool_enqueue(resource.unpack(), .{ .destroy_context = .{ .context_id = context_id } });
    return beam.make(.ok, .{});
}

pub fn pool_eval(resource: PoolResource, context_id: u64, code: []const u8, timeout_ms: u64) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const code_copy = gpa.dupe(u8, code) catch return beam.make(.{ .@"error", "OOM" }, .{});

    pool_enqueue(data, .{ .ctx_eval = .{
        .context_id = context_id,
        .code = code_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
        .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn pool_call_function(resource: PoolResource, context_id: u64, name: []const u8, args: beam.term, timeout_ms: u64) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const args_env = beam.alloc_env();
    const args_copy = e.enif_make_copy(args_env, args.v);
    const name_copy = gpa.dupe(u8, name) catch return beam.make(.{ .@"error", "OOM" }, .{});

    pool_enqueue(data, .{ .ctx_call_fn = .{
        .context_id = context_id,
        .name = name_copy,
        .args_env = args_env,
        .args_term = args_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
        .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn pool_reset_context(resource: PoolResource, context_id: u64) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    pool_enqueue(data, .{ .ctx_reset = .{
        .context_id = context_id,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn pool_send_message(resource: PoolResource, context_id: u64, message: beam.term) beam.term {
    const msg_env = beam.alloc_env();
    const copied = e.enif_make_copy(msg_env, message.v);
    pool_enqueue(resource.unpack(), .{ .ctx_send_message = .{
        .context_id = context_id,
        .env = msg_env,
        .term = copied,
    } });
    return beam.make(.ok, .{});
}

pub fn pool_define_global(resource: PoolResource, context_id: u64, name: []const u8, value: beam.term) beam.term {
    const val_env = beam.alloc_env();
    const copied = e.enif_make_copy(val_env, value.v);
    const name_copy = gpa.dupeZ(u8, name) catch return beam.make(.{ .@"error", "OOM" }, .{});
    pool_enqueue(resource.unpack(), .{ .ctx_define_global = .{
        .context_id = context_id,
        .name = name_copy,
        .env = val_env,
        .term = copied,
    } });
    return beam.make(.ok, .{});
}

pub fn pool_get_global(resource: PoolResource, context_id: u64, name: []const u8) beam.term {
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});
    const name_copy = gpa.dupeZ(u8, name) catch return beam.make(.{ .@"error", "OOM" }, .{});
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);
    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    pool_enqueue(resource.unpack(), .{ .ctx_get_global = .{
        .context_id = context_id,
        .name = name_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });
    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn pool_load_bytecode(resource: PoolResource, context_id: u64, bytecode: []const u8) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const code_copy = gpa.dupe(u8, bytecode) catch return beam.make(.{ .@"error", "OOM" }, .{});

    pool_enqueue(data, .{ .ctx_load_bytecode = .{
        .context_id = context_id,
        .code = code_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
        .timeout_ns = 0,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn pool_memory_usage(resource: PoolResource, context_id: u64) beam.term {
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);
    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    pool_enqueue(resource.unpack(), .{ .ctx_memory_usage = .{
        .context_id = context_id,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });
    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

pub fn pool_dom_find(resource: PoolResource, context_id: u64, selector: []const u8) beam.term {
    return pool_dom_op(resource, context_id, .find, selector, "");
}

pub fn pool_dom_find_all(resource: PoolResource, context_id: u64, selector: []const u8) beam.term {
    return pool_dom_op(resource, context_id, .find_all, selector, "");
}

pub fn pool_dom_text(resource: PoolResource, context_id: u64, selector: []const u8) beam.term {
    return pool_dom_op(resource, context_id, .text, selector, "");
}

pub fn pool_dom_html(resource: PoolResource, context_id: u64) beam.term {
    return pool_dom_op(resource, context_id, .html, "", "");
}

fn pool_dom_op(resource: PoolResource, context_id: u64, op: types.DomOp, selector: []const u8, attr_name: []const u8) beam.term {
    const data = resource.unpack();
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    // SAFETY: enif_self initializes caller_pid before it is used.
    var caller_pid: beam.pid = undefined;
    _ = e.enif_self(env, &caller_pid);
    const ref_env = beam.alloc_env();
    const ref_term = e.enif_make_ref(ref_env);

    const sel_copy = gpa.dupe(u8, selector) catch return beam.make(.{ .@"error", "OOM" }, .{});
    const attr_copy = gpa.dupe(u8, attr_name) catch {
        gpa.free(sel_copy);
        return beam.make(.{ .@"error", "OOM" }, .{});
    };

    pool_enqueue(data, .{ .ctx_dom_op = .{
        .context_id = context_id,
        .op = op,
        .selector = sel_copy,
        .attr_name = attr_copy,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = ref_term,
    } });

    return beam.term{ .v = e.enif_make_copy(env, ref_term) };
}

fn pool_lookup_sync_slot(data: *ct.PoolData, context_id: u64, call_id: u64) ?*types.SyncCallSlot {
    data.rd_map_mutex.lock();
    const rd = data.rd_map.get(context_id);
    data.rd_map_mutex.unlock();

    if (rd) |r| {
        r.sync_slots_mutex.lock();
        const slot = r.sync_slots.get(call_id);
        r.sync_slots_mutex.unlock();
        return slot;
    }
    return null;
}

pub fn pool_resolve_call_term(resource: PoolResource, context_id: u64, call_id: u64, value: beam.term) beam.term {
    const data = resource.unpack();

    if (pool_lookup_sync_slot(data, context_id, call_id)) |s| {
        const term_env = beam.alloc_env();
        s.result_env = term_env;
        s.result_term = e.enif_make_copy(term_env, value.v);
        s.ok = true;
        s.done.set();
        return beam.make(.ok, .{});
    }

    const msg_env = beam.alloc_env();
    const copied = e.enif_make_copy(msg_env, value.v);
    pool_enqueue(data, .{ .ctx_resolve_call_term = .{
        .context_id = context_id,
        .id = call_id,
        .env = msg_env,
        .term = copied,
        .ok = true,
    } });
    return beam.make(.ok, .{});
}

pub fn pool_reject_call_term(resource: PoolResource, context_id: u64, call_id: u64, reason: []const u8) beam.term {
    const data = resource.unpack();

    if (pool_lookup_sync_slot(data, context_id, call_id)) |s| {
        const term_env = beam.alloc_env();
        s.result_env = term_env;
        s.result_term = beam.make(reason, .{ .env = term_env }).v;
        s.ok = false;
        s.done.set();
        return beam.make(.ok, .{});
    }

    const reason_copy = gpa.dupe(u8, reason) catch return beam.make(.ok, .{});
    pool_enqueue(data, .{ .ctx_reject_call = .{
        .context_id = context_id,
        .id = call_id,
        .json = reason_copy,
    } });
    return beam.make(.ok, .{});
}

// ──────────────────── Bytecode disassembly ────────────────────

const js_to_beam = @import("js_to_beam.zig");

pub fn disasm_bytecode(bytecode: []const u8) beam.term {
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});

    const rt = qjs.JS_NewRuntime() orelse return beam.make(.{ .@"error", "failed to create runtime" }, .{});
    defer qjs.JS_FreeRuntime(rt);

    const ctx = qjs.JS_NewContext(rt) orelse return beam.make(.{ .@"error", "failed to create context" }, .{});
    defer qjs.JS_FreeContext(ctx);

    const result = qjs.JS_DisasmBytecode(ctx, bytecode.ptr, bytecode.len);
    defer qjs.JS_FreeValue(ctx, result);

    if (qjs.JS_IsException(result)) {
        const exc = qjs.JS_GetException(ctx);
        defer qjs.JS_FreeValue(ctx, exc);
        const msg_val = qjs.JS_GetPropertyStr(ctx, exc, "message");
        defer qjs.JS_FreeValue(ctx, msg_val);
        var len: usize = 0;
        const ptr = qjs.JS_ToCStringLen(ctx, &len, msg_val);
        if (ptr != null) {
            defer qjs.JS_FreeCString(ctx, ptr);
            const slice = @as([*]const u8, @ptrCast(ptr))[0..len];
            return beam.make(.{ .@"error", beam.term{ .v = beam.make(slice, .{}).v } }, .{});
        }
        return beam.make(.{ .@"error", "disassembly failed" }, .{});
    }

    const term = js_to_beam.convert(ctx, result, env);
    return beam.make(.{ .ok, beam.term{ .v = term } }, .{});
}
