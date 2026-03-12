const types = @import("types.zig");
const worker = @import("worker.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    install_crypto(ctx, global);
    install_performance(ctx, global);
    install_queue_microtask(ctx, global);
    install_structured_clone(ctx, global);
}

// ──────────────────── crypto.getRandomValues ────────────────────

fn install_crypto(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const crypto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, crypto, "getRandomValues", qjs.JS_NewCFunction(ctx, &get_random_values, "getRandomValues", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "crypto", crypto);
}

fn get_random_values(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "crypto.getRandomValues requires 1 argument");

    // Reject non-integer typed arrays per spec
    if (!is_integer_typed_array(ctx, argv[0])) {
        return throw_dom_exception(ctx, "The provided ArrayBufferView is not an integer array type", "TypeMismatchError");
    }

    var byte_offset: usize = 0;
    var byte_len: usize = 0;
    var total_size: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(ctx, argv[0], &byte_offset, &byte_len, &total_size);
    if (js.js_is_exception(ab)) {
        return throw_dom_exception(ctx, "The provided ArrayBufferView is not an integer array type", "TypeMismatchError");
    }
    defer qjs.JS_FreeValue(ctx, ab);

    if (byte_len > 65536) {
        return qjs.JS_ThrowRangeError(ctx, "The ArrayBufferView's byte length (%zu) exceeds the number of bytes of entropy available via this API (65536)", byte_len);
    }

    var buf_size: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, ab) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to get ArrayBuffer data");

    const slice = ptr[byte_offset .. byte_offset + byte_len];
    std.crypto.random.bytes(slice);

    return qjs.JS_DupValue(ctx, argv[0]);
}

fn is_integer_typed_array(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    if (!qjs.JS_IsObject(val)) return false;

    const ctor = qjs.JS_GetPropertyStr(ctx, val, "constructor");
    defer qjs.JS_FreeValue(ctx, ctor);
    if (!qjs.JS_IsFunction(ctx, ctor)) return false;

    const name_val = qjs.JS_GetPropertyStr(ctx, ctor, "name");
    defer qjs.JS_FreeValue(ctx, name_val);

    const name_ptr = qjs.JS_ToCString(ctx, name_val) orelse return false;
    defer qjs.JS_FreeCString(ctx, name_ptr);
    const name = std.mem.span(name_ptr);

    const allowed = [_][]const u8{
        "Int8Array",   "Uint8Array",  "Uint8ClampedArray",
        "Int16Array",  "Uint16Array", "Int32Array",
        "Uint32Array",
    };
    for (allowed) |a| {
        if (std.mem.eql(u8, name, a)) return true;
    }
    return false;
}

fn throw_dom_exception(ctx: ?*qjs.JSContext, message: [*:0]const u8, name: [*:0]const u8) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, "DOMException");
    defer qjs.JS_FreeValue(ctx, ctor);

    if (qjs.JS_IsFunction(ctx, ctor)) {
        var args = [_]qjs.JSValue{
            qjs.JS_NewString(ctx, message),
            qjs.JS_NewString(ctx, name),
        };
        const exc = qjs.JS_CallConstructor(ctx, ctor, 2, &args);
        qjs.JS_FreeValue(ctx, args[0]);
        qjs.JS_FreeValue(ctx, args[1]);
        if (!js.js_is_exception(exc)) return qjs.JS_Throw(ctx, exc);
    }

    return qjs.JS_ThrowTypeError(ctx, message);
}

// ──────────────────── performance.now ────────────────────

fn install_performance(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const perf = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, perf, "now", qjs.JS_NewCFunction(ctx, &performance_now, "now", 0));
    _ = qjs.JS_SetPropertyStr(ctx, global, "performance", perf);
}

fn performance_now(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));
    const now = std.time.nanoTimestamp();
    const elapsed_ns = now - self.start_time;
    const ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    return qjs.JS_NewFloat64(ctx, ms);
}

// ──────────────────── queueMicrotask ────────────────────

fn install_queue_microtask(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    _ = qjs.JS_SetPropertyStr(ctx, global, "queueMicrotask", qjs.JS_NewCFunction(ctx, &queue_microtask_impl, "queueMicrotask", 1));
}

fn queue_microtask_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1 or !qjs.JS_IsFunction(ctx, argv[0])) {
        return qjs.JS_ThrowTypeError(ctx, "queueMicrotask requires a function argument");
    }
    _ = qjs.JS_EnqueueJob(ctx, &microtask_trampoline, 1, argv);
    return js.js_undefined();
}

fn microtask_trampoline(
    ctx: ?*qjs.JSContext,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = argc;
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const result = qjs.JS_Call(ctx, argv[0], global, 0, null);
    if (js.js_is_exception(result)) {
        const exc = qjs.JS_GetException(ctx);
        qjs.JS_FreeValue(ctx, exc);
        return js.js_undefined();
    }
    qjs.JS_FreeValue(ctx, result);
    return js.js_undefined();
}

// ──────────────────── structuredClone ────────────────────

fn install_structured_clone(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    _ = qjs.JS_SetPropertyStr(ctx, global, "structuredClone", qjs.JS_NewCFunction(ctx, &structured_clone_impl, "structuredClone", 1));
}

fn structured_clone_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "structuredClone requires 1 argument");

    var buf_len: usize = 0;
    const buf = qjs.JS_WriteObject(ctx, &buf_len, argv[0], qjs.JS_WRITE_OBJ_REFERENCE);
    if (buf == null) return js.js_exception();
    defer qjs.js_free(ctx, buf);

    const result = qjs.JS_ReadObject(ctx, buf, buf_len, qjs.JS_READ_OBJ_REFERENCE);
    return result;
}
