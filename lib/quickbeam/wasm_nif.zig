const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");

const wamr = @cImport({
    @cDefine("WASM_ENABLE_INTERP", "1");
    @cDefine("WASM_ENABLE_AOT", "0");
    @cDefine("WASM_ENABLE_FAST_INTERP", "0");
    @cDefine("WASM_ENABLE_LIBC_BUILTIN", "0");
    @cDefine("WASM_ENABLE_LIBC_WASI", "0");
    @cDefine("WASM_ENABLE_MULTI_MODULE", "0");
    @cDefine("WASM_ENABLE_BULK_MEMORY", "1");
    @cDefine("WASM_ENABLE_REF_TYPES", "1");
    @cDefine("WASM_ENABLE_SIMD", "0");
    @cDefine("WASM_ENABLE_TAIL_CALL", "1");
    @cDefine("WASM_ENABLE_MEMORY64", "0");
    @cDefine("WASM_ENABLE_GC", "0");
    @cDefine("WASM_ENABLE_THREAD_MGR", "0");
    @cDefine("WASM_ENABLE_SHARED_MEMORY", "0");
    @cDefine("WASM_ENABLE_EXCE_HANDLING", "0");
    @cDefine("WASM_ENABLE_MINI_LOADER", "0");
    @cDefine("WASM_ENABLE_WAMR_COMPILER", "0");
    @cDefine("WASM_ENABLE_JIT", "0");
    @cDefine("WASM_ENABLE_FAST_JIT", "0");
    @cDefine("WASM_ENABLE_DEBUG_INTERP", "0");
    @cDefine("WASM_ENABLE_DUMP_CALL_STACK", "0");
    @cDefine("WASM_ENABLE_PERF_PROFILING", "0");
    @cDefine("WASM_ENABLE_LOAD_CUSTOM_SECTION", "0");
    @cDefine("WASM_ENABLE_CUSTOM_NAME_SECTION", "1");
    @cDefine("WASM_ENABLE_GLOBAL_HEAP_POOL", "0");
    @cDefine("WASM_ENABLE_SPEC_TEST", "0");
    @cDefine("WASM_ENABLE_LABELS_AS_VALUES", "1");
    @cDefine("WASM_ENABLE_WASM_CACHE", "0");
    @cDefine("WASM_ENABLE_STRINGREF", "0");
    @cDefine("WASM_MEM_ALLOC_WITH_SYSTEM_ALLOCATOR", "1");
    @cDefine("WASM_RUNTIME_API_EXTERN", "");
    @cDefine("BH_MALLOC", "malloc");
    @cDefine("BH_FREE", "free");
    @cInclude("wamr_bridge.h");
});

var wamr_initialized = false;

fn ensure_init() bool {
    if (wamr_initialized) return true;
    if (wamr.wamr_bridge_init()) {
        wamr_initialized = true;
        return true;
    }
    return false;
}

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

pub const WasmInstanceResource = beam.Resource(?*wamr.WamrInstance, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(ptr: *?*wamr.WamrInstance) void {
            if (ptr.*) |inst| {
                wamr.wamr_bridge_stop(inst);
                ptr.* = null;
            }
        }
    },
});

// ── NIF functions ───────────────────────────────────────

pub fn wasm_compile(wasm_bytes: []const u8) beam.term {
    if (!ensure_init()) return make_error("WAMR initialization failed");

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
    const inst = wamr.wamr_bridge_start(
        mod_res.unpack() orelse return make_error("module freed"),
        stack_size,
        heap_size,
        &err_buf,
        err_buf.len,
    );
    if (inst == null) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    const inst_nn: ?*wamr.WamrInstance = inst orelse return make_error("null instance");
    return beam.make(.{ .ok, WasmInstanceResource.create(inst_nn, .{}) catch return make_error("resource alloc failed") }, .{});
}

pub fn wasm_stop(inst_res: WasmInstanceResource) beam.term {
    const maybe_inst = inst_res.unpack();
    if (maybe_inst) |inst| {
        wamr.wamr_bridge_stop(inst);
        inst_res.update(null);
    }
    return beam.make(.ok, .{});
}

pub fn wasm_call(inst_res: WasmInstanceResource, func_name: []const u8, params: []const beam.term) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    const inst = inst_res.unpack() orelse return make_error("instance stopped");

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
    const size = wamr.wamr_bridge_memory_size(inst_res.unpack() orelse return make_error("instance stopped"));
    return beam.make(.{ .ok, @as(u64, size) }, .{});
}

pub fn wasm_memory_grow(inst_res: WasmInstanceResource, delta: u32) beam.term {
    const result = wamr.wamr_bridge_memory_grow(inst_res.unpack() orelse return make_error("instance stopped"), delta);
    if (result < 0) return make_error("memory grow failed");
    return beam.make(.{ .ok, @as(i64, result) }, .{});
}

pub fn wasm_read_memory(inst_res: WasmInstanceResource, offset: u32, length: u32) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_alloc_binary(length, &bin) == 0) return make_error("out of memory");

    if (!wamr.wamr_bridge_read_memory(inst_res.unpack() orelse return make_error("instance stopped"), offset, bin.data, length)) {
        e.enif_release_binary(&bin);
        return make_error("out of bounds");
    }

    return beam.make(.{ .ok, beam.term{ .v = e.enif_make_binary(env, &bin) } }, .{});
}

pub fn wasm_write_memory(inst_res: WasmInstanceResource, offset: u32, data: []const u8) beam.term {
    if (!wamr.wamr_bridge_write_memory(inst_res.unpack() orelse return make_error("instance stopped"), offset, data.ptr, @intCast(data.len))) {
        return make_error("out of bounds");
    }
    return beam.make(.ok, .{});
}

pub fn wasm_read_global(inst_res: WasmInstanceResource, name: []const u8) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    const inst = inst_res.unpack() orelse return make_error("instance stopped");

    const name_z = std.heap.c_allocator.dupeZ(u8, name) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(name_z);

    var err_buf: [256]u8 = undefined;
    var value: wamr.wasm_val_t = undefined;

    if (!wamr.wamr_bridge_read_global(inst, name_z.ptr, &value, &err_buf, err_buf.len)) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    return beam.make(.{ .ok, beam.term{ .v = wasm_val_to_term(env, value) } }, .{});
}

pub fn wasm_write_global(inst_res: WasmInstanceResource, name: []const u8, value_term: beam.term) beam.term {
    const env = beam.context.env orelse return make_error("no env");
    const inst = inst_res.unpack() orelse return make_error("instance stopped");

    const name_z = std.heap.c_allocator.dupeZ(u8, name) catch return make_error("out of memory");
    defer std.heap.c_allocator.free(name_z);

    var err_buf: [256]u8 = undefined;
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
