const c = @import("common.zig");

const qjs = c.qjs;
const gpa = c.gpa;
const js = c.js_helpers;
const Status = c.Status;
pub const napi_status = c.napi_status;
pub const napi_env = c.napi_env;
pub const napi_value = c.napi_value;
pub const NapiEnv = c.NapiEnv;
pub const napi_typedarray_type = c.napi_typedarray_type;

pub const ArrayBufferFreeFn = *const fn (?*qjs.JSRuntime, ?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const Uint8ArrayInfo = struct {
    arraybuffer: qjs.JSValue,
    data: ?[*]u8,
    byte_offset: usize,
    byte_length: usize,
};

pub fn isTypedArray(env: *NapiEnv, val: qjs.JSValue) bool {
    if (!qjs.JS_IsObject(val)) return false;
    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(env.ctx, val, &byte_offset, &byte_length, null);
    if (js.js_is_exception(ab)) {
        const exc = qjs.JS_GetException(env.ctx);
        qjs.JS_FreeValue(env.ctx, exc);
        return false;
    }
    qjs.JS_FreeValue(env.ctx, ab);
    return true;
}

pub fn isUint8Array(env: *NapiEnv, val: qjs.JSValue) bool {
    if (!isTypedArray(env, val)) return false;
    const ctor = qjs.JS_GetPropertyStr(env.ctx, val, "constructor");
    defer qjs.JS_FreeValue(env.ctx, ctor);
    if (!qjs.JS_IsObject(ctor)) return false;
    const name = qjs.JS_GetPropertyStr(env.ctx, ctor, "name");
    defer qjs.JS_FreeValue(env.ctx, name);
    if (!qjs.JS_IsString(name)) return false;
    var len: usize = 0;
    const cstr = qjs.JS_ToCStringLen(env.ctx, &len, name);
    if (cstr == null) return false;
    defer qjs.JS_FreeCString(env.ctx, cstr);
    return c.std.mem.eql(u8, cstr[0..len], "Uint8Array");
}

pub fn createUint8ArrayFromArrayBuffer(env: *NapiEnv, ab: qjs.JSValue) !qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(env.ctx);
    defer qjs.JS_FreeValue(env.ctx, global);
    const ctor = qjs.JS_GetPropertyStr(env.ctx, global, "Uint8Array");
    defer qjs.JS_FreeValue(env.ctx, ctor);

    var args = [_]qjs.JSValue{ab};
    const ta = qjs.JS_CallConstructor(env.ctx, ctor, 1, &args);
    if (js.js_is_exception(ta)) return error.Uint8ArrayCreateFailed;
    return ta;
}

pub fn createUint8ArrayFromBuffer(
    env: *NapiEnv,
    ptr: [*]u8,
    length: usize,
    free_fn: ?ArrayBufferFreeFn,
    user_data: ?*anyopaque,
) !qjs.JSValue {
    const ab = qjs.JS_NewArrayBuffer(env.ctx, ptr, length, free_fn, user_data, false);
    if (js.js_is_exception(ab)) return error.ArrayBufferCreateFailed;
    errdefer qjs.JS_FreeValue(env.ctx, ab);
    return createUint8ArrayFromArrayBuffer(env, ab);
}

pub fn getTypedArrayInfo(env: *NapiEnv, value: qjs.JSValue) ?Uint8ArrayInfo {
    if (!isTypedArray(env, value)) return null;

    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(env.ctx, value, &byte_offset, &byte_length, null);
    if (js.js_is_exception(ab)) {
        const exc = qjs.JS_GetException(env.ctx);
        qjs.JS_FreeValue(env.ctx, exc);
        return null;
    }

    var ab_size: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(env.ctx, &ab_size, ab);
    return .{
        .arraybuffer = ab,
        .data = ptr,
        .byte_offset = byte_offset,
        .byte_length = byte_length,
    };
}

pub fn getUint8ArrayInfo(env: *NapiEnv, value: qjs.JSValue, data: ?*?[*]u8, length: ?*usize) napi_status {
    if (!isUint8Array(env, value)) return env.setLastError(.arraybuffer_expected);
    const info = getTypedArrayInfo(env, value) orelse return env.setLastError(.arraybuffer_expected);
    defer qjs.JS_FreeValue(env.ctx, info.arraybuffer);

    if (data) |d| d.* = if (info.data != null) info.data.? + info.byte_offset else null;
    if (length) |l| l.* = info.byte_length;
    return env.ok();
}

pub fn arrayBufferFree(rt: ?*qjs.JSRuntime, user_data: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    _ = rt;
    const len = @intFromPtr(user_data);
    if (ptr) |p| {
        const slice: [*]u8 = @ptrCast(p);
        gpa.free(slice[0..len]);
    }
}

pub export fn napi_is_typedarray(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = isTypedArray(env, c.toVal(value));
    return env.ok();
}

pub export fn napi_is_buffer(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = isUint8Array(env, c.toVal(value));
    return env.ok();
}

pub export fn napi_create_buffer(env_: napi_env, length: usize, data: ?*?[*]u8, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const buf = gpa.alloc(u8, length) catch return env.genericFailure();
    @memset(buf, 0);

    const ta = createUint8ArrayFromBuffer(env, buf.ptr, length, &arrayBufferFree, @ptrFromInt(length)) catch {
        gpa.free(buf);
        return env.genericFailure();
    };

    if (data) |d| d.* = buf.ptr;
    r.* = env.createNapiValue(ta);
    return env.ok();
}

pub export fn napi_create_buffer_copy(env_: napi_env, length: usize, src: ?[*]const u8, data: ?*?[*]u8, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const buf = gpa.alloc(u8, length) catch return env.genericFailure();
    if (src) |s| {
        @memcpy(buf, s[0..length]);
    } else {
        @memset(buf, 0);
    }

    const ta = createUint8ArrayFromBuffer(env, buf.ptr, length, &arrayBufferFree, @ptrFromInt(length)) catch {
        gpa.free(buf);
        return env.genericFailure();
    };

    if (data) |d| d.* = buf.ptr;
    r.* = env.createNapiValue(ta);
    return env.ok();
}

pub export fn napi_get_buffer_info(env_: napi_env, value: napi_value, data: ?*?[*]u8, length: ?*usize) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    return getUint8ArrayInfo(env, c.toVal(value), data, length);
}
