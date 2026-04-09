const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const types = @import("types.zig");
const wasm_host_imports = @import("wasm_host_imports.zig");
const wasm_common = @import("wasm_common.zig");

const wamr = @import("wamr.zig").wamr;

fn make_error(msg: []const u8) beam.term {
    return beam.make(.{ .@"error", msg }, .{});
}

fn valkind_name(kind: wamr.wasm_valkind_t) []const u8 {
    return switch (kind) {
        wamr.WASM_I32 => "i32",
        wamr.WASM_I64 => "i64",
        wamr.WASM_F32 => "f32",
        wamr.WASM_F64 => "f64",
        wamr.WASM_FUNCREF => "funcref",
        wamr.WASM_EXTERNREF => "externref",
        wamr.WASM_V128 => "v128",
        else => "unknown",
    };
}

const HostImportSpec = wasm_host_imports.ImportSpec;

fn get_map_binary(env: *e.ErlNifEnv, map: e.ErlNifTerm, key: [:0]const u8) ![]const u8 {
    const key_term = beam.make_into_atom(key, .{ .env = env });
    // SAFETY: `enif_get_map_value` initializes `value_term` before it is read.
    var value_term: e.ErlNifTerm = undefined;
    if (e.enif_get_map_value(env, map, key_term.v, &value_term) == 0) return error.BadArg;
    return beam.get([]const u8, .{ .v = value_term }, .{ .env = env });
}

fn parse_host_imports(env: *e.ErlNifEnv, imports: beam.term) ![]HostImportSpec {
    var length: c_uint = 0;
    if (e.enif_get_list_length(env, imports.v, &length) == 0) return error.BadArg;

    const result = try std.heap.c_allocator.alloc(HostImportSpec, length);
    errdefer std.heap.c_allocator.free(result);

    var list = imports.v;
    var index: usize = 0;
    while (index < result.len) : (index += 1) {
        // SAFETY: `enif_get_list_cell` initializes `head` and `tail` on success before use.
        var head: e.ErlNifTerm = undefined;
        // SAFETY: `enif_get_list_cell` initializes `head` and `tail` on success before use.
        var tail: e.ErlNifTerm = undefined;
        if (e.enif_get_list_cell(env, list, &head, &tail) == 0) return error.BadArg;

        result[index] = .{
            .module_name = try get_map_binary(env, head, "module_name"),
            .symbol = try get_map_binary(env, head, "symbol"),
            .signature = try get_map_binary(env, head, "signature"),
            .callback_name = try get_map_binary(env, head, "callback_name"),
        };

        list = tail;
    }

    return result;
}

var host_call_id = std.atomic.Value(u64).init(1);

fn next_host_call_id() u64 {
    return host_call_id.fetchAdd(1, .monotonic);
}

fn extract_error_message(env: *e.ErlNifEnv, term: e.ErlNifTerm, fallback: []const u8) []const u8 {
    // SAFETY: `enif_inspect_binary` initializes `bin` on success before it is read.
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_inspect_binary(env, term, &bin) != 0 and bin.size > 0) {
        return bin.data[0..bin.size];
    }
    return fallback;
}

fn build_host_args_term(env: *e.ErlNifEnv, signature: []const u8, raw_args: [*]u64) !e.ErlNifTerm {
    const close_idx = std.mem.indexOfScalar(u8, signature, ')') orelse return error.BadArg;

    var list = beam.make_empty_list(.{ .env = env }).v;
    var i = close_idx;
    while (i > 1) {
        i -= 1;
        const sig = signature[i];
        const raw = raw_args[i - 1];
        const term = switch (sig) {
            'i' => beam.make(@as(i32, @bitCast(@as(u32, @truncate(raw)))), .{ .env = env }).v,
            'I' => blk: {
                var buf: [32]u8 = undefined;
                const rendered = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @bitCast(raw))}) catch return error.BadArg;
                break :blk beam.make(rendered, .{ .env = env }).v;
            },
            'f' => beam.make(@as(f64, @floatCast(@as(f32, @bitCast(@as(u32, @truncate(raw)))))), .{ .env = env }).v,
            'F' => beam.make(@as(f64, @bitCast(raw)), .{ .env = env }).v,
            else => return error.UnsupportedType,
        };
        list = beam.make_list_cell(beam.term{ .v = term }, beam.term{ .v = list }, .{ .env = env }).v;
    }

    return list;
}

fn write_host_result(env: *e.ErlNifEnv, term: e.ErlNifTerm, signature: []const u8, raw_args: [*]u64) !void {
    const close_idx = std.mem.indexOfScalar(u8, signature, ')') orelse return error.BadArg;
    if (close_idx + 1 >= signature.len) return;

    switch (signature[close_idx + 1]) {
        'i' => {
            const value = try parse_i64_term(env, .{ .v = term });
            raw_args[0] = @as(u64, @as(u32, @bitCast(@as(i32, @intCast(value)))));
        },
        'I' => {
            const value = try parse_i64_term(env, .{ .v = term });
            raw_args[0] = @bitCast(value);
        },
        'f' => {
            const value = try parse_f64_term(env, .{ .v = term });
            raw_args[0] = @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(value)))));
        },
        'F' => {
            const value = try parse_f64_term(env, .{ .v = term });
            raw_args[0] = @bitCast(value);
        },
        else => return error.UnsupportedType,
    }
}

fn call_runtime_function_sync(rd: *types.RuntimeData, name: []const u8, args_env: *e.ErlNifEnv, args_term: e.ErlNifTerm, timeout_ns: u64) types.SyncCallSlot {
    const call_id = next_host_call_id();
    var slot = types.SyncCallSlot{};

    rd.sync_slots_mutex.lock();
    rd.sync_slots.put(types.gpa, call_id, &slot) catch {
        rd.sync_slots_mutex.unlock();
        beam.free_env(args_env);
        slot.ok = false;
        slot.result_json = "out of memory";
        slot.done.set();
        return slot;
    };
    rd.sync_slots_mutex.unlock();

    const name_copy = types.gpa.dupe(u8, name) catch {
        rd.sync_slots_mutex.lock();
        _ = rd.sync_slots.remove(call_id);
        rd.sync_slots_mutex.unlock();
        beam.free_env(args_env);
        slot.ok = false;
        slot.result_json = "out of memory";
        slot.done.set();
        return slot;
    };

    types.enqueue(rd, .{ .call_fn_sync = .{
        .id = call_id,
        .name = name_copy,
        .args_env = args_env,
        .args_term = args_term,
        .timeout_ns = timeout_ns,
    } });

    while (!slot.done.isSet()) {
        if (rd.shutting_down.load(.acquire)) {
            break;
        }
        slot.done.timedWait(1_000_000) catch |err| switch (err) {
            error.Timeout => {},
        };
    }

    rd.sync_slots_mutex.lock();
    _ = rd.sync_slots.remove(call_id);
    rd.sync_slots_mutex.unlock();

    if (!slot.done.isSet()) {
        slot.ok = false;
        slot.result_json = "runtime shutting down";
        slot.done.set();
    }

    return slot;
}

pub export fn quickbeam_wasm_host_invoke(runtime_data: ?*anyopaque, callback_name_z: [*:0]const u8, signature_z: [*:0]const u8, raw_args: [*]u64, err_buf: [*]u8, err_buf_size: u32) bool {
    const rd = runtime_data orelse {
        std.mem.copyForwards(u8, err_buf[0..@min(err_buf_size, 21)], "runtime not available");
        return false;
    };

    const runtime: *types.RuntimeData = @ptrCast(@alignCast(rd));
    const callback_name = std.mem.span(callback_name_z);
    const signature = std.mem.span(signature_z);
    const args_env = beam.alloc_env() orelse {
        const msg = "out of memory";
        const copy_len = @min(err_buf_size - 1, msg.len);
        std.mem.copyForwards(u8, err_buf[0..copy_len], msg[0..copy_len]);
        err_buf[copy_len] = 0;
        return false;
    };
    const args_term = build_host_args_term(args_env, signature, raw_args) catch {
        beam.free_env(args_env);
        std.mem.copyForwards(u8, err_buf[0..@min(err_buf_size, 24)], "invalid host import args");
        return false;
    };

    const slot = call_runtime_function_sync(runtime, callback_name, args_env, args_term, 30_000_000_000);

    if (!slot.ok) {
        if (slot.result_env) |result_env| {
            defer beam.free_env(result_env);
            const msg = extract_error_message(result_env, slot.result_term.?, "host import failed");
            const copy_len = @min(err_buf_size - 1, msg.len);
            std.mem.copyForwards(u8, err_buf[0..copy_len], msg[0..copy_len]);
            err_buf[copy_len] = 0;
        } else {
            const msg = if (slot.result_json.len > 0) slot.result_json else "host import failed";
            const copy_len = @min(err_buf_size - 1, msg.len);
            std.mem.copyForwards(u8, err_buf[0..copy_len], msg[0..copy_len]);
            err_buf[copy_len] = 0;
        }
        return false;
    }

    if (slot.result_env) |result_env| {
        defer beam.free_env(result_env);
        write_host_result(result_env, slot.result_term.?, signature, raw_args) catch {
            const msg = "invalid host import result";
            const copy_len = @min(err_buf_size - 1, msg.len);
            std.mem.copyForwards(u8, err_buf[0..copy_len], msg[0..copy_len]);
            err_buf[copy_len] = 0;
            return false;
        };
    }

    return true;
}

fn parse_i64_term(env: *e.ErlNifEnv, term: beam.term) !i64 {
    var value: i64 = 0;
    if (e.enif_get_int64(env, term.v, &value) != 0) {
        return value;
    }

    const value_str = beam.get([]const u8, term, .{}) catch return error.BadArg;
    return std.fmt.parseInt(i64, value_str, 10) catch error.BadArg;
}

fn parse_f64_term(env: *e.ErlNifEnv, term: beam.term) !f64 {
    var value: f64 = 0;
    if (e.enif_get_double(env, term.v, &value) != 0) {
        return value;
    }

    const int_value = try parse_i64_term(env, term);
    return @floatFromInt(int_value);
}

fn term_to_wasm_val(env: *e.ErlNifEnv, term: beam.term, kind: wamr.wasm_valkind_t) !wamr.wasm_val_t {
    // SAFETY: `value` is fully populated in the kind-specific branch before it is returned.
    var value: wamr.wasm_val_t = undefined;
    value.kind = kind;
    value._paddings = [_]u8{0} ** 7;

    switch (kind) {
        wamr.WASM_I32 => {
            const int_value = try parse_i64_term(env, term);
            if (int_value < std.math.minInt(i32) or int_value > std.math.maxInt(i32)) {
                return error.BadArg;
            }
            value.of.i32 = @intCast(int_value);
        },
        wamr.WASM_I64 => {
            value.of.i64 = try parse_i64_term(env, term);
        },
        wamr.WASM_F32 => {
            const float_value = try parse_f64_term(env, term);
            value.of.f32 = @floatCast(float_value);
        },
        wamr.WASM_F64 => {
            value.of.f64 = try parse_f64_term(env, term);
        },
        else => return error.UnsupportedType,
    }

    return value;
}

fn wasm_val_to_term(env: *e.ErlNifEnv, value: wamr.wasm_val_t) e.ErlNifTerm {
    return switch (value.kind) {
        wamr.WASM_I32 => beam.make(value.of.i32, .{ .env = env }).v,
        wamr.WASM_I64 => beam.make(value.of.i64, .{ .env = env }).v,
        wamr.WASM_F32 => beam.make(@as(f64, value.of.f32), .{ .env = env }).v,
        wamr.WASM_F64 => beam.make(value.of.f64, .{ .env = env }).v,
        else => beam.make_into_atom("nil", .{ .env = env }).v,
    };
}

fn kind_mismatch_error(kind: wamr.wasm_valkind_t, index: usize) beam.term {
    return beam.make(.{ .@"error", std.fmt.allocPrint(std.heap.c_allocator, "unsupported or invalid argument at index {d} for type {s}", .{ index, valkind_name(kind) }) catch "invalid argument" }, .{});
}

// ── Resources ───────────────────────────────────────────

pub const WasmModuleResource = beam.Resource(?*wamr.WamrModule, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(ptr: *?*wamr.WamrModule) void {
            if (ptr.*) |mod| {
                wamr.wamr_bridge_free_module(mod);
                ptr.* = null;
            }
        }
    },
});

pub const WasmInstanceResource = beam.Resource(?*wasm_common.ManagedInstance, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(ptr: *?*wasm_common.ManagedInstance) void {
            if (ptr.*) |inst| {
                inst.destroy();
                ptr.* = null;
            }
        }
    },
});

// ── NIF functions ───────────────────────────────────────

pub fn wasm_compile(wasm_bytes: []const u8) beam.term {
    if (!wasm_common.ensure_init()) return make_error("WAMR initialization failed");

    var err_buf: [256]u8 = undefined;
    const mod = wamr.wamr_bridge_compile(
        wasm_bytes.ptr,
        @intCast(wasm_bytes.len),
        &err_buf,
        err_buf.len,
    );
    if (mod == null) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    const mod_opt: ?*wamr.WamrModule = mod orelse return make_error("null module");
    return beam.make(.{ .ok, WasmModuleResource.create(mod_opt, .{}) catch return make_error("resource alloc failed") }, .{});
}

pub fn wasm_start(mod_res: WasmModuleResource, stack_size: u32, heap_size: u32) beam.term {
    var err_buf: [256]u8 = undefined;
    const managed = wasm_common.start_managed_instance(
        mod_res.unpack() orelse return make_error("module freed"),
        stack_size,
        heap_size,
        null,
        &err_buf,
    ) orelse {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    };
    return beam.make(.{ .ok, WasmInstanceResource.create(managed, .{}) catch return make_error("resource alloc failed") }, .{});
}

pub fn wasm_start_with_imports_internal(mod_res: WasmModuleResource, runtime_data: *types.RuntimeData, imports: beam.term, stack_size: u32, heap_size: u32) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    const host_imports = parse_host_imports(env, imports) catch return make_error("invalid host imports");
    defer std.heap.c_allocator.free(host_imports);
    if (host_imports.len == 0) return make_error("invalid host imports");

    var import_specs = std.heap.c_allocator.alloc(wasm_host_imports.ImportSpec, host_imports.len) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(import_specs);

    for (host_imports, 0..) |host_import, index| {
        import_specs[index] = .{
            .module_name = host_import.module_name,
            .symbol = host_import.symbol,
            .signature = host_import.signature,
            .callback_name = host_import.callback_name,
        };
    }

    var prepared_imports = wasm_host_imports.prepare(import_specs, runtime_data, .beam) catch return make_error("out of memory");
    errdefer prepared_imports.deinit();

    var err_buf: [256]u8 = undefined;
    const managed = wasm_common.start_managed_instance(
        mod_res.unpack() orelse return make_error("module freed"),
        stack_size,
        heap_size,
        &prepared_imports,
        &err_buf,
    ) orelse {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    };
    return beam.make(.{ .ok, WasmInstanceResource.create(managed, .{}) catch return make_error("resource alloc failed") }, .{});
}

pub fn wasm_stop(inst_res: WasmInstanceResource) beam.term {
    const maybe_inst = inst_res.unpack();
    if (maybe_inst) |inst| {
        inst.destroy();
        inst_res.update(null);
    }
    return beam.make(.ok, .{});
}

pub fn wasm_call(inst_res: WasmInstanceResource, func_name: []const u8, params: []const beam.term) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    const managed = inst_res.unpack() orelse return make_error("instance stopped");
    const inst = managed.inst;

    const name_z = std.heap.c_allocator.dupeZ(u8, func_name) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(name_z);

    var err_buf: [256]u8 = undefined;
    var param_count: u32 = 0;
    var result_count: u32 = 0;

    if (!wamr.wamr_bridge_function_signature(
        inst,
        name_z.ptr,
        &param_count,
        null,
        &result_count,
        null,
        &err_buf,
        err_buf.len,
    )) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    if (params.len != param_count) {
        return beam.make(.{ .@"error", std.fmt.allocPrint(std.heap.c_allocator, "arity mismatch: expected {d}, got {d}", .{ param_count, params.len }) catch "arity mismatch" }, .{});
    }

    const param_types = std.heap.c_allocator.alloc(wamr.wasm_valkind_t, param_count) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(param_types);

    const result_types = std.heap.c_allocator.alloc(wamr.wasm_valkind_t, result_count) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(result_types);

    if (!wamr.wamr_bridge_function_signature(
        inst,
        name_z.ptr,
        &param_count,
        if (param_count > 0) param_types.ptr else null,
        &result_count,
        if (result_count > 0) result_types.ptr else null,
        &err_buf,
        err_buf.len,
    )) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    const wasm_params = std.heap.c_allocator.alloc(wamr.wasm_val_t, param_count) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(wasm_params);

    for (params, 0..) |param, index| {
        wasm_params[index] = term_to_wasm_val(env, param, param_types[index]) catch return kind_mismatch_error(param_types[index], index);
    }

    const wasm_results = std.heap.c_allocator.alloc(wamr.wasm_val_t, result_count) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(wasm_results);

    if (!wamr.wamr_bridge_call_typed(
        inst,
        name_z.ptr,
        if (param_count > 0) wasm_params.ptr else null,
        param_count,
        if (result_count > 0) wasm_results.ptr else null,
        result_count,
        &err_buf,
        err_buf.len,
    )) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    if (result_count == 0) {
        return beam.make(.{ .ok, beam.term{ .v = beam.make_into_atom("nil", .{ .env = env }).v } }, .{});
    }

    if (result_count == 1) {
        return beam.make(.{ .ok, beam.term{ .v = wasm_val_to_term(env, wasm_results[0]) } }, .{});
    }

    var list = e.enif_make_list(env, 0);
    var i = result_count;
    while (i > 0) {
        i -= 1;
        list = e.enif_make_list_cell(env, wasm_val_to_term(env, wasm_results[i]), list);
    }

    return beam.make(.{ .ok, beam.term{ .v = list } }, .{});
}

pub fn wasm_memory_size(inst_res: WasmInstanceResource) beam.term {
    const managed = inst_res.unpack() orelse return make_error("instance stopped");
    const size = wamr.wamr_bridge_memory_size(managed.inst);
    return beam.make(.{ .ok, @as(u64, size) }, .{});
}

pub fn wasm_memory_grow(inst_res: WasmInstanceResource, delta: u32) beam.term {
    const managed = inst_res.unpack() orelse return make_error("instance stopped");
    const result = wamr.wamr_bridge_memory_grow(managed.inst, delta);
    if (result < 0) return make_error("memory grow failed");
    return beam.make(.{ .ok, @as(i64, result) }, .{});
}

pub fn wasm_read_memory(inst_res: WasmInstanceResource, offset: u32, length: u32) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    // SAFETY: `enif_alloc_binary` initializes `bin` on success before it is passed on.
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_alloc_binary(length, &bin) == 0) return make_error("out of memory");

    const managed = inst_res.unpack() orelse return make_error("instance stopped");
    if (!wamr.wamr_bridge_read_memory(managed.inst, offset, bin.data, length)) {
        e.enif_release_binary(&bin);
        return make_error("out of bounds");
    }

    return beam.make(.{ .ok, beam.term{ .v = e.enif_make_binary(env, &bin) } }, .{});
}

pub fn wasm_write_memory(inst_res: WasmInstanceResource, offset: u32, data: []const u8) beam.term {
    const managed = inst_res.unpack() orelse return make_error("instance stopped");
    if (!wamr.wamr_bridge_write_memory(managed.inst, offset, data.ptr, @intCast(data.len))) {
        return make_error("out of bounds");
    }
    return beam.make(.ok, .{});
}

pub fn wasm_read_global(inst_res: WasmInstanceResource, name: []const u8) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    const managed = inst_res.unpack() orelse return make_error("instance stopped");
    const inst = managed.inst;

    const name_z = std.heap.c_allocator.dupeZ(u8, name) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(name_z);

    var err_buf: [256]u8 = undefined;
    // SAFETY: WAMR initializes `value` on successful global reads before it is used.
    var value: wamr.wasm_val_t = undefined;

    if (!wamr.wamr_bridge_read_global(inst, name_z.ptr, &value, &err_buf, err_buf.len)) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    return beam.make(.{ .ok, beam.term{ .v = wasm_val_to_term(env, value) } }, .{});
}

pub fn wasm_write_global(inst_res: WasmInstanceResource, name: []const u8, value_term: beam.term) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    const managed = inst_res.unpack() orelse return make_error("instance stopped");
    const inst = managed.inst;

    const name_z = std.heap.c_allocator.dupeZ(u8, name) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(name_z);

    var err_buf: [256]u8 = undefined;
    // SAFETY: WAMR initializes `current` on successful global reads before it is inspected.
    var current: wamr.wasm_val_t = undefined;

    if (!wamr.wamr_bridge_read_global(inst, name_z.ptr, &current, &err_buf, err_buf.len)) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    const value = term_to_wasm_val(env, value_term, current.kind) catch return make_error("invalid global value");

    if (!wamr.wamr_bridge_write_global(inst, name_z.ptr, &value, &err_buf, err_buf.len)) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    return beam.make(.ok, .{});
}
