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

// ── Resources ───────────────────────────────────────────

pub const WasmModuleResource = beam.Resource(?*wamr.WamrModule, @import("root"), .{});

pub const WasmInstanceResource = beam.Resource(?*wamr.WamrInstance, @import("root"), .{});

// ── NIF functions ───────────────────────────────────────

pub fn wasm_compile(wasm_bytes: []const u8) beam.term {
    if (!ensure_init())
        return beam.make(.{ .@"error", "WAMR initialization failed" }, .{});

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

    const mod_opt: ?*wamr.WamrModule = mod orelse return beam.make(.{ .@"error", "null module" }, .{});
    return beam.make(.{ .ok, WasmModuleResource.create(mod_opt, .{}) catch return beam.make(.{ .@"error", "resource alloc failed" }, .{}) }, .{});
}

pub fn wasm_start(mod_res: WasmModuleResource, stack_size: u32, heap_size: u32) beam.term {
    var err_buf: [256]u8 = undefined;
    const inst = wamr.wamr_bridge_start(
        mod_res.unpack() orelse return beam.make(.{ .@"error", "module freed" }, .{}),
        stack_size,
        heap_size,
        &err_buf,
        err_buf.len,
    );
    if (inst == null) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    const inst_nn: ?*wamr.WamrInstance = inst orelse return beam.make(.{ .@"error", "null instance" }, .{});
    return beam.make(.{ .ok, WasmInstanceResource.create(inst_nn, .{}) catch return beam.make(.{ .@"error", "resource alloc failed" }, .{}) }, .{});
}

pub fn wasm_stop(inst_res: WasmInstanceResource) beam.term {
    const maybe_inst = inst_res.unpack();
    if (maybe_inst) |inst| {
        wamr.wamr_bridge_stop(inst);
    }
    return beam.make(.ok, .{});
}

pub fn wasm_call(inst_res: WasmInstanceResource, func_name: []const u8, params: []const u32) beam.term {
    const inst = inst_res.unpack() orelse return beam.make(.{ .@"error", "instance stopped" }, .{});

    var err_buf: [256]u8 = undefined;
    var results: [8]u32 = undefined;

    const name_z = std.heap.c_allocator.dupeZ(u8, func_name) catch
        return beam.make(.{ .@"error", "out of memory" }, .{});
    defer std.heap.c_allocator.free(name_z);

    if (!wamr.wamr_bridge_call(
        inst,
        name_z.ptr,
        @constCast(params.ptr),
        @intCast(params.len),
        &results,
        1,
        &err_buf,
        err_buf.len,
    )) {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        return beam.make(.{ .@"error", err_msg }, .{});
    }

    return beam.make(.{ .ok, @as(i64, @bitCast(@as(u64, results[0]))) }, .{});
}

pub fn wasm_memory_size(inst_res: WasmInstanceResource) beam.term {
    const size = wamr.wamr_bridge_memory_size(inst_res.unpack() orelse return beam.make(.{ .@"error", "instance stopped" }, .{}));
    return beam.make(.{ .ok, @as(u64, size) }, .{});
}

pub fn wasm_memory_grow(inst_res: WasmInstanceResource, delta: u32) beam.term {
    const result = wamr.wamr_bridge_memory_grow(inst_res.unpack() orelse return beam.make(.{ .@"error", "instance stopped" }, .{}), delta);
    if (result < 0)
        return beam.make(.{ .@"error", "memory grow failed" }, .{});
    return beam.make(.{ .ok, @as(i64, result) }, .{});
}

pub fn wasm_read_memory(inst_res: WasmInstanceResource, offset: u32, length: u32) beam.term {
    const env = beam.context.env orelse return beam.make(.{ .@"error", "no env" }, .{});
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_alloc_binary(length, &bin) == 0)
        return beam.make(.{ .@"error", "out of memory" }, .{});

    if (!wamr.wamr_bridge_read_memory(inst_res.unpack() orelse return beam.make(.{ .@"error", "instance stopped" }, .{}), offset, bin.data, length)) {
        e.enif_release_binary(&bin);
        return beam.make(.{ .@"error", "out of bounds" }, .{});
    }

    return beam.make(.{ .ok, beam.term{ .v = e.enif_make_binary(env, &bin) } }, .{});
}

pub fn wasm_write_memory(inst_res: WasmInstanceResource, offset: u32, data: []const u8) beam.term {
    if (!wamr.wamr_bridge_write_memory(inst_res.unpack() orelse return beam.make(.{ .@"error", "instance stopped" }, .{}), offset, data.ptr, @intCast(data.len)))
        return beam.make(.{ .@"error", "out of bounds" }, .{});
    return beam.make(.ok, .{});
}
