const types = @import("types.zig");
const js = @import("js_helpers.zig");
const wasm_host_imports = @import("wasm_host_imports.zig");
const wasm_common = @import("wasm_common.zig");

const std = types.std;
const qjs = types.qjs;
const gpa = types.gpa;

const wamr = @import("wamr.zig").wamr;

const InstanceEntry = struct {
    mod: *wamr.WamrModule,
    managed: *wasm_common.ManagedInstance,
};

const ContextState = struct {
    next_instance_id: u64 = 1,
    max_reductions: i64 = 0,
    instances: std.AutoHashMapUnmanaged(u64, InstanceEntry) = .{},

    fn deinit(self: *ContextState) void {
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.managed.destroy();
            wamr.wamr_bridge_free_module(entry.value_ptr.mod);
        }
        self.instances.deinit(gpa);
    }
};

const ParsedHostImport = wasm_host_imports.ImportSpec;

var states_mutex: std.Thread.Mutex = .{};
var states: std.AutoHashMapUnmanaged(usize, *ContextState) = .{};

fn throw_error(ctx: *qjs.JSContext, msg: []const u8) qjs.JSValue {
    const err = qjs.JS_NewError(ctx);
    if (!js.js_is_exception(err)) {
        _ = qjs.JS_SetPropertyStr(ctx, err, "message", qjs.JS_NewStringLen(ctx, msg.ptr, msg.len));
    }
    return qjs.JS_Throw(ctx, err);
}

fn context_key(ctx: *qjs.JSContext) usize {
    return @intFromPtr(ctx);
}

fn ensure_context_state(ctx: *qjs.JSContext, max_reductions: i64) ?*ContextState {
    states_mutex.lock();
    defer states_mutex.unlock();

    const key = context_key(ctx);
    if (states.get(key)) |state| {
        state.max_reductions = max_reductions;
        return state;
    }

    const state = gpa.create(ContextState) catch return null;
    state.* = .{ .max_reductions = max_reductions };
    states.put(gpa, key, state) catch {
        gpa.destroy(state);
        return null;
    };
    return state;
}

fn get_context_state(ctx: *qjs.JSContext) ?*ContextState {
    states_mutex.lock();
    defer states_mutex.unlock();
    return states.get(context_key(ctx));
}

pub fn destroy_context(ctx: *qjs.JSContext) void {
    states_mutex.lock();
    const removed = states.fetchRemove(context_key(ctx));
    states_mutex.unlock();

    if (removed) |entry| {
        entry.value.deinit();
        gpa.destroy(entry.value);
    }
}

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue, max_reductions: i64) void {
    _ = ensure_context_state(ctx, max_reductions) orelse return;

    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_wasm_start", qjs.JS_NewCFunction(ctx, &wasm_start_impl, "__qb_wasm_start", 3));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_wasm_call", qjs.JS_NewCFunction(ctx, &wasm_call_impl, "__qb_wasm_call", 3));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_wasm_memory_size", qjs.JS_NewCFunction(ctx, &wasm_memory_size_impl, "__qb_wasm_memory_size", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_wasm_memory_grow", qjs.JS_NewCFunction(ctx, &wasm_memory_grow_impl, "__qb_wasm_memory_grow", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_wasm_read_memory", qjs.JS_NewCFunction(ctx, &wasm_read_memory_impl, "__qb_wasm_read_memory", 3));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_wasm_read_global", qjs.JS_NewCFunction(ctx, &wasm_read_global_impl, "__qb_wasm_read_global", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_wasm_write_global", qjs.JS_NewCFunction(ctx, &wasm_write_global_impl, "__qb_wasm_write_global", 3));
}

fn copy_js_string(ctx: *qjs.JSContext, value: qjs.JSValue) ?[]u8 {
    const ptr = qjs.JS_ToCString(ctx, value) orelse return null;
    defer qjs.JS_FreeCString(ctx, ptr);
    return gpa.dupe(u8, std.mem.span(ptr)) catch null;
}

fn get_property_string(ctx: *qjs.JSContext, obj: qjs.JSValue, name: [*:0]const u8) ?[]u8 {
    const prop = qjs.JS_GetPropertyStr(ctx, obj, name);
    defer qjs.JS_FreeValue(ctx, prop);
    return copy_js_string(ctx, prop);
}

fn get_array_length(ctx: *qjs.JSContext, value: qjs.JSValue) usize {
    const len_val = qjs.JS_GetPropertyStr(ctx, value, "length");
    defer qjs.JS_FreeValue(ctx, len_val);
    var len: i64 = 0;
    _ = qjs.JS_ToInt64(ctx, &len, len_val);
    if (len < 0) return 0;
    return @intCast(len);
}

fn get_bytes_view(ctx: *qjs.JSContext, value: qjs.JSValue) ![]const u8 {
    var buf_size: usize = 0;
    const direct = qjs.JS_GetArrayBuffer(ctx, &buf_size, value);
    if (direct != null) return direct[0..buf_size];

    var byte_offset: usize = 0;
    var byte_len: usize = 0;
    var bytes_per_element: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(ctx, value, &byte_offset, &byte_len, &bytes_per_element);
    if (js.js_is_exception(ab)) {
        const exc = qjs.JS_GetException(ctx);
        qjs.JS_FreeValue(ctx, exc);
        return error.BadArg;
    }
    defer qjs.JS_FreeValue(ctx, ab);

    const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, ab);
    if (ptr == null) return error.BadArg;
    return ptr[byte_offset .. byte_offset + byte_len];
}

fn make_uint8array(ctx: *qjs.JSContext, data: [*]u8, size: usize) qjs.JSValue {
    const ab = qjs.JS_NewArrayBufferCopy(ctx, data, size);
    if (js.js_is_exception(ab)) return js.js_exception();
    defer qjs.JS_FreeValue(ctx, ab);

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, "Uint8Array");
    defer qjs.JS_FreeValue(ctx, ctor);

    var args = [_]qjs.JSValue{ab};
    return qjs.JS_CallConstructor(ctx, ctor, 1, &args);
}

fn parse_host_imports(ctx: *qjs.JSContext, imports_val: qjs.JSValue) ![]ParsedHostImport {
    if (qjs.JS_IsUndefined(imports_val) or qjs.JS_IsNull(imports_val)) {
        return gpa.alloc(ParsedHostImport, 0);
    }

    const len = get_array_length(ctx, imports_val);
    const imports = try gpa.alloc(ParsedHostImport, len);
    var parsed_count: usize = 0;
    errdefer {
        for (imports[0..parsed_count]) |item| {
            gpa.free(item.module_name);
            gpa.free(item.symbol);
            gpa.free(item.signature);
            gpa.free(item.callback_name);
        }
        gpa.free(imports);
    }

    for (imports, 0..) |*import, index| {
        const item = qjs.JS_GetPropertyUint32(ctx, imports_val, @intCast(index));
        defer qjs.JS_FreeValue(ctx, item);

        import.module_name = get_property_string(ctx, item, "module_name") orelse return error.BadArg;
        import.symbol = get_property_string(ctx, item, "symbol") orelse return error.BadArg;
        import.signature = get_property_string(ctx, item, "signature") orelse return error.BadArg;
        import.callback_name = get_property_string(ctx, item, "callback_name") orelse return error.BadArg;
        parsed_count += 1;
    }

    return imports;
}

fn free_host_imports(imports: []ParsedHostImport) void {
    for (imports) |import| {
        gpa.free(import.module_name);
        gpa.free(import.symbol);
        gpa.free(import.signature);
        gpa.free(import.callback_name);
    }
    gpa.free(imports);
}

fn parse_memory_initializers(ctx: *qjs.JSContext, values: qjs.JSValue) ![][]u8 {
    if (qjs.JS_IsUndefined(values) or qjs.JS_IsNull(values)) {
        return gpa.alloc([]u8, 0);
    }

    const len = get_array_length(ctx, values);
    const initializers = try gpa.alloc([]u8, len);
    var parsed_count: usize = 0;
    errdefer {
        for (initializers[0..parsed_count]) |bytes| gpa.free(bytes);
        gpa.free(initializers);
    }

    for (initializers, 0..) |*entry, index| {
        const item = qjs.JS_GetPropertyUint32(ctx, values, @intCast(index));
        defer qjs.JS_FreeValue(ctx, item);
        const bytes = try get_bytes_view(ctx, item);
        entry.* = try gpa.dupe(u8, bytes);
        parsed_count += 1;
    }

    return initializers;
}

fn free_memory_initializers(initializers: [][]u8) void {
    for (initializers) |bytes| gpa.free(bytes);
    gpa.free(initializers);
}

fn get_instance_entry(state: *ContextState, instance_id: u64) ?*InstanceEntry {
    return state.instances.getPtr(instance_id);
}

fn instruction_limit(ctx: *qjs.JSContext, state: *ContextState) c_int {
    if (state.max_reductions <= 0) return -1;

    const used = qjs.JS_GetContextReductionCount(ctx);
    const remaining = state.max_reductions - used;
    if (remaining <= 0) return 1;

    const fuel = @as(i128, remaining) * 100;
    return if (fuel > std.math.maxInt(c_int)) std.math.maxInt(c_int) else @intCast(fuel);
}

fn js_value_to_wasm(ctx: *qjs.JSContext, value: qjs.JSValue, kind: wamr.wasm_valkind_t) !wamr.wasm_val_t {
    var result: wamr.wasm_val_t = undefined;
    result.kind = kind;
    result._paddings = [_]u8{0} ** 7;

    switch (kind) {
        wamr.WASM_I32 => {
            var v: i32 = 0;
            if (qjs.JS_IsBigInt(value)) {
                var big: i64 = 0;
                if (qjs.JS_ToBigInt64(ctx, &big, value) != 0) return error.BadArg;
                if (big < std.math.minInt(i32) or big > std.math.maxInt(i32)) return error.BadArg;
                v = @intCast(big);
            } else if (qjs.JS_ToInt32(ctx, &v, value) != 0) return error.BadArg;
            result.of.i32 = v;
        },
        wamr.WASM_I64 => {
            var v: i64 = 0;
            if (qjs.JS_IsBigInt(value)) {
                if (qjs.JS_ToBigInt64(ctx, &v, value) != 0) return error.BadArg;
            } else if (qjs.JS_ToInt64(ctx, &v, value) != 0) return error.BadArg;
            result.of.i64 = v;
        },
        wamr.WASM_F32 => {
            var v: f64 = 0;
            if (qjs.JS_ToFloat64(ctx, &v, value) != 0) return error.BadArg;
            result.of.f32 = @floatCast(v);
        },
        wamr.WASM_F64 => {
            var v: f64 = 0;
            if (qjs.JS_ToFloat64(ctx, &v, value) != 0) return error.BadArg;
            result.of.f64 = v;
        },
        else => return error.UnsupportedType,
    }

    return result;
}

fn wasm_to_js_value(ctx: *qjs.JSContext, value: wamr.wasm_val_t) qjs.JSValue {
    return switch (value.kind) {
        wamr.WASM_I32 => qjs.JS_NewInt32(ctx, value.of.i32),
        wamr.WASM_I64 => qjs.JS_NewBigInt64(ctx, value.of.i64),
        wamr.WASM_F32 => qjs.JS_NewFloat64(ctx, @as(f64, value.of.f32)),
        wamr.WASM_F64 => qjs.JS_NewFloat64(ctx, value.of.f64),
        else => js.js_undefined(),
    };
}

fn wasm_start_impl(
    ctx_opt: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = ctx_opt orelse return js.js_exception();
    if (argc < 1) return throw_error(ctx, "WebAssembly start requires bytes");
    if (!wasm_common.ensure_init()) return throw_error(ctx, "WAMR initialization failed");

    const state = get_context_state(ctx) orelse return throw_error(ctx, "missing wasm context state");
    const bytes = get_bytes_view(ctx, argv[0]) catch return throw_error(ctx, "invalid wasm bytes");
    const host_imports = parse_host_imports(ctx, if (argc > 1) argv[1] else js.js_undefined()) catch return throw_error(ctx, "invalid host imports");
    defer free_host_imports(host_imports);
    const memory_initializers = parse_memory_initializers(ctx, if (argc > 2) argv[2] else js.js_undefined()) catch return throw_error(ctx, "invalid memory initializers");
    defer free_memory_initializers(memory_initializers);

    var err_buf: [256]u8 = undefined;
    const mod = wamr.wamr_bridge_compile(bytes.ptr, @intCast(bytes.len), &err_buf, err_buf.len);
    if (mod == null) return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    errdefer wamr.wamr_bridge_free_module(mod);

    var import_specs: []wasm_host_imports.ImportSpec = if (host_imports.len > 0)
        gpa.alloc(wasm_host_imports.ImportSpec, host_imports.len) catch return throw_error(ctx, "out of memory")
    else
        @constCast(&[_]wasm_host_imports.ImportSpec{});
    defer if (host_imports.len > 0) gpa.free(import_specs);

    for (host_imports, 0..) |import, index| {
        import_specs[index] = .{
            .module_name = import.module_name,
            .symbol = import.symbol,
            .signature = import.signature,
            .callback_name = import.callback_name,
        };
    }

    var prepared_imports = if (import_specs.len > 0)
        wasm_host_imports.prepare(import_specs, ctx, .js) catch return throw_error(ctx, "out of memory")
    else
        wasm_host_imports.PreparedImports.empty();
    errdefer prepared_imports.deinit();

    const managed = wasm_common.start_managed_instance(mod orelse return throw_error(ctx, "null module"), 65_536, 65_536, if (prepared_imports.registrations.len > 0) &prepared_imports else null, &err_buf) orelse return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    const mod_nn = mod orelse return throw_error(ctx, "null module");
    errdefer managed.destroy();

    if (memory_initializers.len > 1) return throw_error(ctx, "multiple memory imports are not supported yet");
    if (memory_initializers.len == 1) {
        if (!wamr.wamr_bridge_write_memory(managed.inst, 0, memory_initializers[0].ptr, @intCast(memory_initializers[0].len))) {
            return throw_error(ctx, "failed to initialize imported memory");
        }
    }

    const instance_id = state.next_instance_id;
    state.next_instance_id += 1;
    state.instances.put(gpa, instance_id, .{ .mod = mod_nn, .managed = managed }) catch return throw_error(ctx, "out of memory");

    return qjs.JS_NewInt64(ctx, @intCast(instance_id));
}

fn wasm_call_impl(
    ctx_opt: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = ctx_opt orelse return js.js_exception();
    if (argc < 2) return throw_error(ctx, "WebAssembly call requires instance id and function name");

    const state = get_context_state(ctx) orelse return throw_error(ctx, "missing wasm context state");

    var instance_id_i64: i64 = 0;
    if (qjs.JS_ToInt64(ctx, &instance_id_i64, argv[0]) != 0 or instance_id_i64 < 0) return throw_error(ctx, "invalid instance handle");
    const entry = get_instance_entry(state, @intCast(instance_id_i64)) orelse return throw_error(ctx, "instance not found");

    const func_name_ptr = qjs.JS_ToCString(ctx, argv[1]) orelse return throw_error(ctx, "invalid function name");
    defer qjs.JS_FreeCString(ctx, func_name_ptr);

    var err_buf: [256]u8 = undefined;
    var param_count: u32 = 0;
    var result_count: u32 = 0;
    if (!wamr.wamr_bridge_function_signature(entry.managed.inst, func_name_ptr, &param_count, null, &result_count, null, &err_buf, err_buf.len)) {
        return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    }

    const arg_array = if (argc > 2) argv[2] else js.js_undefined();
    const arg_len = if (qjs.JS_IsUndefined(arg_array) or qjs.JS_IsNull(arg_array)) 0 else get_array_length(ctx, arg_array);
    if (arg_len != param_count) return throw_error(ctx, "arity mismatch");

    const param_types = std.heap.c_allocator.alloc(wamr.wasm_valkind_t, param_count) catch return throw_error(ctx, "out of memory");
    defer std.heap.c_allocator.free(param_types);
    const result_types = std.heap.c_allocator.alloc(wamr.wasm_valkind_t, result_count) catch return throw_error(ctx, "out of memory");
    defer std.heap.c_allocator.free(result_types);

    if (!wamr.wamr_bridge_function_signature(entry.managed.inst, func_name_ptr, &param_count, if (param_count > 0) param_types.ptr else null, &result_count, if (result_count > 0) result_types.ptr else null, &err_buf, err_buf.len)) {
        return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    }

    const params = std.heap.c_allocator.alloc(wamr.wasm_val_t, param_count) catch return throw_error(ctx, "out of memory");
    defer std.heap.c_allocator.free(params);
    for (0..param_count) |index| {
        const arg = qjs.JS_GetPropertyUint32(ctx, arg_array, @intCast(index));
        defer qjs.JS_FreeValue(ctx, arg);
        params[index] = js_value_to_wasm(ctx, arg, param_types[index]) catch return throw_error(ctx, "invalid argument type");
    }

    const results = std.heap.c_allocator.alloc(wamr.wasm_val_t, result_count) catch return throw_error(ctx, "out of memory");
    defer std.heap.c_allocator.free(results);

    const limit = instruction_limit(ctx, state);
    wamr.wamr_bridge_set_instruction_limit(entry.managed.inst, limit);

    if (!wamr.wamr_bridge_call_typed(entry.managed.inst, func_name_ptr, if (param_count > 0) params.ptr else null, param_count, if (result_count > 0) results.ptr else null, result_count, &err_buf, err_buf.len)) {
        return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    }

    if (result_count == 0) return js.js_undefined();
    if (result_count == 1) return wasm_to_js_value(ctx, results[0]);

    const array = qjs.JS_NewArray(ctx);
    for (0..result_count) |index| {
        _ = qjs.JS_SetPropertyUint32(ctx, array, @intCast(index), wasm_to_js_value(ctx, results[index]));
    }
    return array;
}

fn wasm_memory_size_impl(
    ctx_opt: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = ctx_opt orelse return js.js_exception();
    if (argc < 1) return throw_error(ctx, "instance id required");
    const state = get_context_state(ctx) orelse return throw_error(ctx, "missing wasm context state");
    var instance_id_i64: i64 = 0;
    if (qjs.JS_ToInt64(ctx, &instance_id_i64, argv[0]) != 0 or instance_id_i64 < 0) return throw_error(ctx, "invalid instance handle");
    const entry = get_instance_entry(state, @intCast(instance_id_i64)) orelse return throw_error(ctx, "instance not found");
    return qjs.JS_NewInt64(ctx, wamr.wamr_bridge_memory_size(entry.managed.inst));
}

fn wasm_memory_grow_impl(
    ctx_opt: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = ctx_opt orelse return js.js_exception();
    if (argc < 2) return throw_error(ctx, "instance id and delta required");
    const state = get_context_state(ctx) orelse return throw_error(ctx, "missing wasm context state");
    var instance_id_i64: i64 = 0;
    var delta: i32 = 0;
    if (qjs.JS_ToInt64(ctx, &instance_id_i64, argv[0]) != 0 or instance_id_i64 < 0) return throw_error(ctx, "invalid instance handle");
    if (qjs.JS_ToInt32(ctx, &delta, argv[1]) != 0 or delta < 0) return throw_error(ctx, "invalid memory grow delta");
    const entry = get_instance_entry(state, @intCast(instance_id_i64)) orelse return throw_error(ctx, "instance not found");
    const grown = wamr.wamr_bridge_memory_grow(entry.managed.inst, @intCast(delta));
    if (grown < 0) return throw_error(ctx, "memory grow failed");
    return qjs.JS_NewInt64(ctx, grown);
}

fn wasm_read_memory_impl(
    ctx_opt: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = ctx_opt orelse return js.js_exception();
    if (argc < 3) return throw_error(ctx, "instance id, offset, and length required");
    const state = get_context_state(ctx) orelse return throw_error(ctx, "missing wasm context state");
    var instance_id_i64: i64 = 0;
    var offset: i64 = 0;
    var length: i64 = 0;
    if (qjs.JS_ToInt64(ctx, &instance_id_i64, argv[0]) != 0 or instance_id_i64 < 0) return throw_error(ctx, "invalid instance handle");
    if (qjs.JS_ToInt64(ctx, &offset, argv[1]) != 0 or offset < 0) return throw_error(ctx, "invalid memory offset");
    if (qjs.JS_ToInt64(ctx, &length, argv[2]) != 0 or length < 0) return throw_error(ctx, "invalid memory length");
    const entry = get_instance_entry(state, @intCast(instance_id_i64)) orelse return throw_error(ctx, "instance not found");

    const bytes = gpa.alloc(u8, @intCast(length)) catch return throw_error(ctx, "out of memory");
    defer gpa.free(bytes);

    if (!wamr.wamr_bridge_read_memory(entry.managed.inst, @intCast(offset), bytes.ptr, @intCast(length))) {
        return throw_error(ctx, "out of bounds");
    }

    return make_uint8array(ctx, bytes.ptr, bytes.len);
}

fn wasm_read_global_impl(
    ctx_opt: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = ctx_opt orelse return js.js_exception();
    if (argc < 2) return throw_error(ctx, "instance id and global name required");
    const state = get_context_state(ctx) orelse return throw_error(ctx, "missing wasm context state");
    var instance_id_i64: i64 = 0;
    if (qjs.JS_ToInt64(ctx, &instance_id_i64, argv[0]) != 0 or instance_id_i64 < 0) return throw_error(ctx, "invalid instance handle");
    const entry = get_instance_entry(state, @intCast(instance_id_i64)) orelse return throw_error(ctx, "instance not found");

    const name_ptr = qjs.JS_ToCString(ctx, argv[1]) orelse return throw_error(ctx, "invalid global name");
    defer qjs.JS_FreeCString(ctx, name_ptr);

    var err_buf: [256]u8 = undefined;
    var value: wamr.wasm_val_t = undefined;
    if (!wamr.wamr_bridge_read_global(entry.managed.inst, name_ptr, &value, &err_buf, err_buf.len)) {
        return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    }

    return wasm_to_js_value(ctx, value);
}

fn wasm_write_global_impl(
    ctx_opt: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = ctx_opt orelse return js.js_exception();
    if (argc < 3) return throw_error(ctx, "instance id, global name, and value required");
    const state = get_context_state(ctx) orelse return throw_error(ctx, "missing wasm context state");
    var instance_id_i64: i64 = 0;
    if (qjs.JS_ToInt64(ctx, &instance_id_i64, argv[0]) != 0 or instance_id_i64 < 0) return throw_error(ctx, "invalid instance handle");
    const entry = get_instance_entry(state, @intCast(instance_id_i64)) orelse return throw_error(ctx, "instance not found");

    const name_ptr = qjs.JS_ToCString(ctx, argv[1]) orelse return throw_error(ctx, "invalid global name");
    defer qjs.JS_FreeCString(ctx, name_ptr);

    var err_buf: [256]u8 = undefined;
    var current: wamr.wasm_val_t = undefined;
    if (!wamr.wamr_bridge_read_global(entry.managed.inst, name_ptr, &current, &err_buf, err_buf.len)) {
        return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    }

    const value = js_value_to_wasm(ctx, argv[2], current.kind) catch return throw_error(ctx, "invalid global value");
    if (!wamr.wamr_bridge_write_global(entry.managed.inst, name_ptr, &value, &err_buf, err_buf.len)) {
        return throw_error(ctx, std.mem.sliceTo(&err_buf, 0));
    }

    return argv[2];
}
