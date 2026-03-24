const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;
const gpa = types.gpa;

const nt = @import("napi_types.zig");
pub const Status = nt.Status;
pub const napi_status = nt.napi_status;
pub const napi_env = nt.napi_env;
pub const NapiEnv = nt.NapiEnv;
pub const napi_value = nt.napi_value;
pub const napi_ref = nt.napi_ref;
pub const napi_callback = nt.napi_callback;
pub const napi_callback_info = nt.napi_callback_info;
pub const napi_finalize = nt.napi_finalize;
pub const napi_handle_scope = nt.napi_handle_scope;
pub const napi_escapable_handle_scope = nt.napi_escapable_handle_scope;
pub const napi_deferred = nt.napi_deferred;
pub const napi_property_descriptor = nt.napi_property_descriptor;
pub const napi_valuetype = nt.napi_valuetype;
pub const napi_typedarray_type = nt.napi_typedarray_type;
pub const HandleScope = nt.HandleScope;
pub const NapiReference = nt.NapiReference;
pub const Deferred = nt.Deferred;
pub const CallbackInfo = nt.CallbackInfo;
pub const FunctionCallbackData = nt.FunctionCallbackData;
pub const ExternalData = nt.ExternalData;
pub const AsyncWork = nt.AsyncWork;
pub const napi_async_work = nt.napi_async_work;
pub const ThreadSafeFunction = nt.ThreadSafeFunction;
pub const napi_threadsafe_function = nt.napi_threadsafe_function;
pub const NAPI_AUTO_LENGTH = nt.NAPI_AUTO_LENGTH;

fn toVal(v: napi_value) qjs.JSValue {
    if (v) |ptr| return ptr.* else return js.js_undefined();
}

// ──────────────────── Globals / Version ────────────────────

pub export fn napi_get_undefined(env_: napi_env, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(js.js_undefined());
    return env.ok();
}

pub export fn napi_get_null(env_: napi_env, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(js.js_null());
    return env.ok();
}

pub export fn napi_get_global(env_: napi_env, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const global = qjs.JS_GetGlobalObject(env.ctx);
    r.* = env.createNapiValue(global);
    return env.ok();
}

pub export fn napi_get_boolean(env_: napi_env, value: bool, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(if (value) js.js_true() else js.js_false());
    return env.ok();
}

// ──────────────────── Value Creation ────────────────────

pub export fn napi_create_int32(env_: napi_env, value: i32, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(qjs.JS_NewInt32(env.ctx, value));
    return env.ok();
}

pub export fn napi_create_uint32(env_: napi_env, value: u32, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(qjs.JS_NewUint32(env.ctx, value));
    return env.ok();
}

pub export fn napi_create_int64(env_: napi_env, value: i64, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(qjs.JS_NewInt64(env.ctx, value));
    return env.ok();
}

pub export fn napi_create_double(env_: napi_env, value: f64, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(qjs.JS_NewFloat64(env.ctx, value));
    return env.ok();
}

pub export fn napi_create_string_utf8(env_: napi_env, str: ?[*]const u8, length: usize, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const slice = napiSpan(str, length) orelse return env.invalidArg();
    const val = qjs.JS_NewStringLen(env.ctx, slice.ptr, slice.len);
    r.* = env.createNapiValue(val);
    return env.ok();
}

pub export fn napi_create_string_latin1(env_: napi_env, str: ?[*]const u8, length: usize, result: ?*napi_value) callconv(.c) napi_status {
    // QuickJS strings are UTF-8; latin1 is a subset for 0-127 and close enough for basic use
    return napi_create_string_utf8(env_, str, length, result);
}

pub export fn napi_create_string_utf16(env_: napi_env, str: ?[*]const u16, length: usize, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const slice: []const u16 = blk: {
        if (str) |ptr| {
            if (length == NAPI_AUTO_LENGTH) {
                var len: usize = 0;
                while (ptr[len] != 0) : (len += 1) {}
                break :blk ptr[0..len];
            }
            break :blk ptr[0..length];
        }
        return env.invalidArg();
    };

    // Convert UTF-16 to UTF-8
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(gpa);
    var i: usize = 0;
    while (i < slice.len) {
        var codepoint: u21 = slice[i];
        i += 1;
        // Handle surrogate pairs
        if (codepoint >= 0xD800 and codepoint <= 0xDBFF and i < slice.len) {
            const low = slice[i];
            if (low >= 0xDC00 and low <= 0xDFFF) {
                codepoint = 0x10000 + ((@as(u21, @intCast(codepoint)) - 0xD800) << 10) + (@as(u21, @intCast(low)) - 0xDC00);
                i += 1;
            }
        }
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
        buf.appendSlice(gpa, utf8_buf[0..utf8_len]) catch return env.genericFailure();
    }

    const val = qjs.JS_NewStringLen(env.ctx, buf.items.ptr, buf.items.len);
    r.* = env.createNapiValue(val);
    return env.ok();
}

pub export fn napi_create_symbol(env_: napi_env, description: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const desc_val = toVal(description);
    var sym: qjs.JSValue = undefined;
    if (qjs.JS_IsString(desc_val)) {
        const cstr = qjs.JS_ToCString(env.ctx, desc_val);
        if (cstr != null) {
            sym = qjs.JS_NewSymbol(env.ctx, cstr, false);
            qjs.JS_FreeCString(env.ctx, cstr);
        } else {
            sym = qjs.JS_NewSymbol(env.ctx, null, false);
        }
    } else {
        sym = qjs.JS_NewSymbol(env.ctx, null, false);
    }

    r.* = env.createNapiValue(sym);
    return env.ok();
}

pub export fn napi_create_object(env_: napi_env, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = qjs.JS_NewObject(env.ctx);
    r.* = env.createNapiValue(obj);
    return env.ok();
}

pub export fn napi_create_array(env_: napi_env, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const arr = qjs.JS_NewArray(env.ctx);
    r.* = env.createNapiValue(arr);
    return env.ok();
}

pub export fn napi_create_array_with_length(env_: napi_env, length: usize, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const arr = qjs.JS_NewArray(env.ctx);
    if (length > 0) {
        _ = qjs.JS_SetPropertyStr(env.ctx, arr, "length", qjs.JS_NewUint32(env.ctx, @intCast(length)));
    }
    r.* = env.createNapiValue(arr);
    return env.ok();
}

// ──────────────────── Value Getters ────────────────────

pub export fn napi_get_value_double(env_: napi_env, value: napi_value, result: ?*f64) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    var d: f64 = 0;
    if (qjs.JS_ToFloat64(env.ctx, &d, val) < 0) return env.setLastError(.number_expected);
    r.* = d;
    return env.ok();
}

pub export fn napi_get_value_int32(env_: napi_env, value: napi_value, result: ?*i32) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    var i: i32 = 0;
    if (qjs.JS_ToInt32(env.ctx, &i, val) < 0) return env.setLastError(.number_expected);
    r.* = i;
    return env.ok();
}

pub export fn napi_get_value_uint32(env_: napi_env, value: napi_value, result: ?*u32) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    var u: u32 = 0;
    if (qjs.JS_ToUint32(env.ctx, &u, val) < 0) return env.setLastError(.number_expected);
    r.* = u;
    return env.ok();
}

pub export fn napi_get_value_int64(env_: napi_env, value: napi_value, result: ?*i64) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    var i: i64 = 0;
    if (qjs.JS_ToInt64(env.ctx, &i, val) < 0) return env.setLastError(.number_expected);
    r.* = i;
    return env.ok();
}

pub export fn napi_get_value_bool(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    if (!qjs.JS_IsBool(val)) return env.setLastError(.boolean_expected);
    r.* = qjs.JS_ToBool(env.ctx, val) != 0;
    return env.ok();
}

pub export fn napi_get_value_string_utf8(env_: napi_env, value: napi_value, buf: ?[*]u8, bufsize: usize, result_ptr: ?*usize) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const val = toVal(value);
    if (!qjs.JS_IsString(val)) return env.setLastError(.string_expected);

    var len: usize = 0;
    const cstr = qjs.JS_ToCStringLen(env.ctx, &len, val);
    if (cstr == null) return env.genericFailure();
    defer qjs.JS_FreeCString(env.ctx, cstr);

    if (buf) |b| {
        if (bufsize > 0) {
            const copy_len = @min(len, bufsize - 1);
            @memcpy(b[0..copy_len], cstr[0..copy_len]);
            b[copy_len] = 0;
            if (result_ptr) |rp| rp.* = copy_len;
        }
    } else {
        if (result_ptr) |rp| rp.* = len;
    }
    return env.ok();
}

pub export fn napi_get_value_string_latin1(env_: napi_env, value: napi_value, buf: ?[*]u8, bufsize: usize, result_ptr: ?*usize) callconv(.c) napi_status {
    return napi_get_value_string_utf8(env_, value, buf, bufsize, result_ptr);
}

pub export fn napi_get_value_string_utf16(env_: napi_env, value: napi_value, buf: ?[*]u16, bufsize: usize, result_ptr: ?*usize) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const val = toVal(value);
    if (!qjs.JS_IsString(val)) return env.setLastError(.string_expected);

    var len: usize = 0;
    const cstr = qjs.JS_ToCStringLen(env.ctx, &len, val);
    if (cstr == null) return env.genericFailure();
    defer qjs.JS_FreeCString(env.ctx, cstr);

    const utf8_slice = cstr[0..len];

    if (buf) |b| {
        if (bufsize == 0) {
            if (result_ptr) |rp| rp.* = len; // approximate
            return env.ok();
        }
        var out_idx: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(utf8_slice);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp >= 0x10000) {
                if (out_idx + 2 >= bufsize) break;
                const adjusted = cp - 0x10000;
                b[out_idx] = @intCast(0xD800 + (adjusted >> 10));
                b[out_idx + 1] = @intCast(0xDC00 + (adjusted & 0x3FF));
                out_idx += 2;
            } else {
                if (out_idx + 1 >= bufsize) break;
                b[out_idx] = @intCast(cp);
                out_idx += 1;
            }
        }
        b[out_idx] = 0;
        if (result_ptr) |rp| rp.* = out_idx;
    } else {
        // Count UTF-16 code units
        var count: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(utf8_slice);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            count += if (cp >= 0x10000) 2 else 1;
        }
        if (result_ptr) |rp| rp.* = count;
    }
    return env.ok();
}

// ──────────────────── Type Checks ────────────────────

pub export fn napi_typeof(env_: napi_env, value: napi_value, result: ?*napi_valuetype) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);

    const tag = qjs.JS_VALUE_GET_TAG(val);
    r.* = switch (tag) {
        qjs.JS_TAG_UNDEFINED => .@"undefined",
        qjs.JS_TAG_NULL => .@"null",
        qjs.JS_TAG_BOOL => .boolean,
        qjs.JS_TAG_INT, qjs.JS_TAG_FLOAT64 => .number,
        qjs.JS_TAG_STRING => .string,
        qjs.JS_TAG_SYMBOL => .symbol,
        qjs.JS_TAG_BIG_INT, qjs.JS_TAG_SHORT_BIG_INT => .bigint,
        qjs.JS_TAG_OBJECT => blk: {
            if (qjs.JS_IsFunction(env.ctx, val)) break :blk .function;
            if (nt.external_class_id != 0 and qjs.JS_GetClassID(val) == nt.external_class_id) break :blk .external;
            break :blk .object;
        },
        else => .@"undefined",
    };
    return env.ok();
}

pub export fn napi_is_array(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = qjs.JS_IsArray(toVal(value));
    return env.ok();
}

pub export fn napi_is_arraybuffer(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = qjs.JS_IsArrayBuffer(toVal(value));
    return env.ok();
}

pub export fn napi_is_date(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    if (!qjs.JS_IsObject(val)) {
        r.* = false;
        return env.ok();
    }
    // Check if it has getTime method (duck typing for Date)
    const get_time = qjs.JS_GetPropertyStr(env.ctx, val, "getTime");
    r.* = qjs.JS_IsFunction(env.ctx, get_time);
    qjs.JS_FreeValue(env.ctx, get_time);
    return env.ok();
}

pub export fn napi_is_error(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = qjs.JS_IsError(toVal(value));
    return env.ok();
}

pub export fn napi_is_promise(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = js.is_promise(env.ctx, toVal(value));
    return env.ok();
}

pub export fn napi_is_typedarray(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    // QuickJS: check if it has a buffer property and byteLength (duck-typing typed arrays)
    if (!qjs.JS_IsObject(val)) {
        r.* = false;
        return env.ok();
    }
    const byte_length = qjs.JS_GetPropertyStr(env.ctx, val, "byteLength");
    defer qjs.JS_FreeValue(env.ctx, byte_length);
    r.* = !qjs.JS_IsUndefined(byte_length) and !qjs.JS_IsArrayBuffer(val);
    return env.ok();
}

pub export fn napi_is_buffer(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    // In Node.js, Buffer is a Uint8Array subclass. In QuickJS, treat ArrayBuffer as buffer.
    return napi_is_arraybuffer(env_, value, result);
}

pub export fn napi_is_dataview(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    if (!qjs.JS_IsObject(val)) {
        r.* = false;
        return env.ok();
    }
    // Check constructor name
    const ctor = qjs.JS_GetPropertyStr(env.ctx, val, "constructor");
    defer qjs.JS_FreeValue(env.ctx, ctor);
    if (qjs.JS_IsObject(ctor)) {
        const name = qjs.JS_GetPropertyStr(env.ctx, ctor, "name");
        defer qjs.JS_FreeValue(env.ctx, name);
        if (qjs.JS_IsString(name)) {
            var slen: usize = 0;
            const cstr = qjs.JS_ToCStringLen(env.ctx, &slen, name);
            if (cstr != null) {
                defer qjs.JS_FreeCString(env.ctx, cstr);
                r.* = std.mem.eql(u8, cstr[0..slen], "DataView");
                return env.ok();
            }
        }
    }
    r.* = false;
    return env.ok();
}

pub export fn napi_strict_equals(env_: napi_env, lhs: napi_value, rhs: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const a = toVal(lhs);
    const b = toVal(rhs);

    const tag_a = qjs.JS_VALUE_GET_TAG(a);
    const tag_b = qjs.JS_VALUE_GET_TAG(b);

    if (tag_a != tag_b) {
        // Special case: INT and FLOAT64 can be strictly equal
        if ((tag_a == qjs.JS_TAG_INT or tag_a == qjs.JS_TAG_FLOAT64) and
            (tag_b == qjs.JS_TAG_INT or tag_b == qjs.JS_TAG_FLOAT64))
        {
            var da: f64 = 0;
            var db: f64 = 0;
            _ = qjs.JS_ToFloat64(env.ctx, &da, a);
            _ = qjs.JS_ToFloat64(env.ctx, &db, b);
            r.* = da == db;
            return env.ok();
        }
        r.* = false;
        return env.ok();
    }

    r.* = switch (tag_a) {
        qjs.JS_TAG_UNDEFINED, qjs.JS_TAG_NULL => true,
        qjs.JS_TAG_BOOL => qjs.JS_VALUE_GET_INT(a) == qjs.JS_VALUE_GET_INT(b),
        qjs.JS_TAG_INT => qjs.JS_VALUE_GET_INT(a) == qjs.JS_VALUE_GET_INT(b),
        qjs.JS_TAG_FLOAT64 => blk: {
            var da: f64 = 0;
            var db: f64 = 0;
            _ = qjs.JS_ToFloat64(env.ctx, &da, a);
            _ = qjs.JS_ToFloat64(env.ctx, &db, b);
            break :blk da == db;
        },
        qjs.JS_TAG_STRING => qjs.JS_IsStrictEqual(env.ctx, a, b),
        else => qjs.JS_VALUE_GET_PTR(a) == qjs.JS_VALUE_GET_PTR(b),
    };
    return env.ok();
}

// ──────────────────── Coercion ────────────────────

pub export fn napi_coerce_to_bool(env_: napi_env, value: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const b = qjs.JS_ToBool(env.ctx, toVal(value));
    r.* = env.createNapiValue(if (b != 0) js.js_true() else js.js_false());
    return env.ok();
}

pub export fn napi_coerce_to_number(env_: napi_env, value: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    var d: f64 = 0;
    if (qjs.JS_ToFloat64(env.ctx, &d, toVal(value)) < 0) return env.setLastError(.pending_exception);
    const val = qjs.JS_NewFloat64(env.ctx, d);
    r.* = env.createNapiValue(val);
    return env.ok();
}

pub export fn napi_coerce_to_object(env_: napi_env, value: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    if (qjs.JS_IsObject(val)) {
        r.* = env.createNapiValue(val);
    } else {
        // Wrap primitive in Object()
        const obj = qjs.JS_NewObject(env.ctx);
        r.* = env.createNapiValue(obj);
    }
    return env.ok();
}

pub export fn napi_coerce_to_string(env_: napi_env, value: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = qjs.JS_ToString(env.ctx, toVal(value));
    if (js.js_is_exception(val)) return env.setLastError(.pending_exception);
    r.* = env.createNapiValue(val);
    return env.ok();
}

// ──────────────────── Object Property Access ────────────────────

pub export fn napi_get_property(env_: napi_env, object: napi_value, key: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const k = toVal(key);
    const atom = qjs.JS_ValueToAtom(env.ctx, k);
    if (atom == 0) return env.invalidArg();
    defer qjs.JS_FreeAtom(env.ctx, atom);

    const val = qjs.JS_GetProperty(env.ctx, obj, atom);
    if (js.js_is_exception(val)) return env.setLastError(.pending_exception);
    r.* = env.createNapiValue(val);
    return env.ok();
}

pub export fn napi_set_property(env_: napi_env, object: napi_value, key: napi_value, value: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const k = toVal(key);
    const v = toVal(value);
    const atom = qjs.JS_ValueToAtom(env.ctx, k);
    if (atom == 0) return env.invalidArg();
    defer qjs.JS_FreeAtom(env.ctx, atom);

    const ret = qjs.JS_SetProperty(env.ctx, obj, atom, qjs.JS_DupValue(env.ctx, v));
    if (ret < 0) return env.setLastError(.pending_exception);
    return env.ok();
}

pub export fn napi_has_property(env_: napi_env, object: napi_value, key: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const k = toVal(key);
    const atom = qjs.JS_ValueToAtom(env.ctx, k);
    if (atom == 0) return env.invalidArg();
    defer qjs.JS_FreeAtom(env.ctx, atom);

    const ret = qjs.JS_HasProperty(env.ctx, obj, atom);
    if (ret < 0) return env.setLastError(.pending_exception);
    r.* = ret != 0;
    return env.ok();
}

pub export fn napi_delete_property(env_: napi_env, object: napi_value, key: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const k = toVal(key);
    const atom = qjs.JS_ValueToAtom(env.ctx, k);
    if (atom == 0) return env.invalidArg();
    defer qjs.JS_FreeAtom(env.ctx, atom);

    const ret = qjs.JS_DeleteProperty(env.ctx, obj, atom, 0);
    if (result) |r| r.* = ret >= 0;
    return env.ok();
}

pub export fn napi_get_named_property(env_: napi_env, object: napi_value, utf8name: [*c]const u8, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    if (utf8name == null) return env.invalidArg();

    const val = qjs.JS_GetPropertyStr(env.ctx, obj, utf8name);
    if (js.js_is_exception(val)) return env.setLastError(.pending_exception);
    r.* = env.createNapiValue(val);
    return env.ok();
}

pub export fn napi_set_named_property(env_: napi_env, object: napi_value, utf8name: [*c]const u8, value: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    if (utf8name == null) return env.invalidArg();

    const v = toVal(value);
    const ret = qjs.JS_SetPropertyStr(env.ctx, obj, utf8name, qjs.JS_DupValue(env.ctx, v));
    if (ret < 0) return env.setLastError(.pending_exception);
    return env.ok();
}

pub export fn napi_has_named_property(env_: napi_env, object: napi_value, utf8name: [*c]const u8, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    if (utf8name == null) return env.invalidArg();

    const atom = qjs.JS_NewAtom(env.ctx, utf8name);
    defer qjs.JS_FreeAtom(env.ctx, atom);
    const ret = qjs.JS_HasProperty(env.ctx, obj, atom);
    r.* = ret > 0;
    return env.ok();
}

pub export fn napi_has_own_property(env_: napi_env, object: napi_value, key: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const k = toVal(key);
    const atom = qjs.JS_ValueToAtom(env.ctx, k);
    if (atom == 0) return env.invalidArg();
    defer qjs.JS_FreeAtom(env.ctx, atom);

    // GetOwnProperty returns a descriptor or -1 on error
    var desc: qjs.JSPropertyDescriptor = undefined;
    const ret = qjs.JS_GetOwnProperty(env.ctx, &desc, obj, atom);
    if (ret > 0) {
        qjs.JS_FreeValue(env.ctx, desc.value);
        if (desc.flags & qjs.JS_PROP_GETSET != 0) {
            qjs.JS_FreeValue(env.ctx, desc.getter);
            qjs.JS_FreeValue(env.ctx, desc.setter);
        }
    }
    r.* = ret > 0;
    return env.ok();
}

// ──────────────────── Array Element Access ────────────────────

pub export fn napi_set_element(env_: napi_env, object: napi_value, index: u32, value: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    const v = toVal(value);
    const ret = qjs.JS_SetPropertyUint32(env.ctx, obj, index, qjs.JS_DupValue(env.ctx, v));
    if (ret < 0) return env.setLastError(.pending_exception);
    return env.ok();
}

pub export fn napi_get_element(env_: napi_env, object: napi_value, index: u32, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    const val = qjs.JS_GetPropertyUint32(env.ctx, obj, index);
    if (js.js_is_exception(val)) return env.setLastError(.pending_exception);
    r.* = env.createNapiValue(val);
    return env.ok();
}

pub export fn napi_has_element(env_: napi_env, object: napi_value, index: u32, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    const atom = qjs.JS_NewAtomUInt32(env.ctx, index);
    defer qjs.JS_FreeAtom(env.ctx, atom);
    const ret = qjs.JS_HasProperty(env.ctx, obj, atom);
    r.* = ret > 0;
    return env.ok();
}

pub export fn napi_delete_element(env_: napi_env, object: napi_value, index: u32, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    const atom = qjs.JS_NewAtomUInt32(env.ctx, index);
    defer qjs.JS_FreeAtom(env.ctx, atom);
    const ret = qjs.JS_DeleteProperty(env.ctx, obj, atom, 0);
    if (result) |r| r.* = ret >= 0;
    return env.ok();
}

pub export fn napi_get_array_length(env_: napi_env, value: napi_value, result: ?*u32) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    const len_val = qjs.JS_GetPropertyStr(env.ctx, val, "length");
    defer qjs.JS_FreeValue(env.ctx, len_val);
    var len: u32 = 0;
    _ = qjs.JS_ToUint32(env.ctx, &len, len_val);
    r.* = len;
    return env.ok();
}

// ──────────────────── Prototype ────────────────────

pub export fn napi_get_prototype(env_: napi_env, object: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    const proto = qjs.JS_GetPrototype(env.ctx, obj);
    r.* = env.createNapiValue(proto);
    return env.ok();
}

// ──────────────────── Handle Scopes ────────────────────

pub export fn napi_open_handle_scope(env_: napi_env, result: ?*napi_handle_scope) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const scope = HandleScope.init(false);
    env.scope_stack.append(gpa, scope) catch return env.genericFailure();
    r.* = scope;
    return env.ok();
}

pub export fn napi_close_handle_scope(env_: napi_env, scope_: napi_handle_scope) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const scope = scope_ orelse return env.invalidArg();
    if (env.scope_stack.items.len > 0 and env.scope_stack.items[env.scope_stack.items.len - 1] == scope) {
        _ = env.scope_stack.pop();
        scope.deinit(env.ctx);
        gpa.destroy(scope);
    }
    return env.ok();
}

pub export fn napi_open_escapable_handle_scope(env_: napi_env, result: ?*napi_escapable_handle_scope) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const scope = HandleScope.init(true);
    env.scope_stack.append(gpa, scope) catch return env.genericFailure();
    r.* = scope;
    return env.ok();
}

pub export fn napi_close_escapable_handle_scope(env_: napi_env, scope_: napi_escapable_handle_scope) callconv(.c) napi_status {
    return napi_close_handle_scope(env_, scope_);
}

pub export fn napi_escape_handle(env_: napi_env, scope_: napi_escapable_handle_scope, escapee: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const scope = scope_ orelse return env.invalidArg();
    const r = result orelse return env.invalidArg();
    if (!scope.escapable) return env.invalidArg();
    if (scope.escaped) return env.setLastError(.escape_called_twice);
    scope.escaped = true;

    const val = toVal(escapee);
    // Move the value to the parent scope
    if (env.scope_stack.items.len >= 2) {
        const parent = env.scope_stack.items[env.scope_stack.items.len - 2];
        r.* = parent.track(env.ctx, val);
    } else {
        r.* = env.createNapiValue(val);
    }
    return env.ok();
}

// ──────────────────── Error Handling ────────────────────

pub export fn napi_throw(env_: napi_env, @"error": napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const val = toVal(@"error");
    _ = qjs.JS_Throw(env.ctx, qjs.JS_DupValue(env.ctx, val));
    env.setPendingException(val);
    return env.ok();
}

pub export fn napi_throw_error(env_: napi_env, code: [*c]const u8, msg: [*c]const u8) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    _ = code;
    const err = qjs.JS_ThrowInternalError(env.ctx, msg orelse "Unknown error");
    _ = err;
    return env.ok();
}

pub export fn napi_throw_type_error(env_: napi_env, code: [*c]const u8, msg: [*c]const u8) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    _ = code;
    _ = qjs.JS_ThrowTypeError(env.ctx, msg orelse "Type error");
    return env.ok();
}

pub export fn napi_throw_range_error(env_: napi_env, code: [*c]const u8, msg: [*c]const u8) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    _ = code;
    _ = qjs.JS_ThrowRangeError(env.ctx, msg orelse "Range error");
    return env.ok();
}

pub export fn napi_create_error(env_: napi_env, code: napi_value, msg: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    _ = code;
    const msg_val = toVal(msg);
    const err = qjs.JS_NewError(env.ctx);
    if (!js.js_is_exception(err)) {
        _ = qjs.JS_SetPropertyStr(env.ctx, err, "message", qjs.JS_DupValue(env.ctx, msg_val));
    }
    r.* = env.createNapiValue(err);
    return env.ok();
}

pub export fn napi_create_type_error(env_: napi_env, code: napi_value, msg: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    return napi_create_error(env_, code, msg, result);
}

pub export fn napi_create_range_error(env_: napi_env, code: napi_value, msg: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    return napi_create_error(env_, code, msg, result);
}

pub export fn napi_is_exception_pending(env_: napi_env, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = env.has_pending_exception;
    return env.ok();
}

pub export fn napi_get_and_clear_last_exception(env_: napi_env, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    if (env.has_pending_exception) {
        r.* = env.createNapiValue(env.pending_exception);
        env.clearPendingException();
    } else {
        r.* = env.createNapiValue(js.js_undefined());
    }
    return env.ok();
}

pub export fn napi_get_last_error_info(env_: napi_env, result: ?*[*c]const nt.napi_extended_error_info) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = &env.last_error;
    return @intFromEnum(Status.ok);
}

// ──────────────────── Function Creation & Calling ────────────────────

pub export fn napi_create_function(
    env_: napi_env,
    utf8name: [*c]const u8,
    length: usize,
    cb: napi_callback,
    data: ?*anyopaque,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const callback = cb orelse return env.invalidArg();
    _ = length;

    const cbd = createCallbackData(env, callback, data) orelse return env.genericFailure();

    const ptr_as_int: i64 = @bitCast(@intFromPtr(cbd));
    var func_data = [_]qjs.JSValue{qjs.JS_NewInt64(env.ctx, ptr_as_int)};
    const func = qjs.JS_NewCFunctionData(env.ctx, &napiCallbackTrampoline, 0, 0, 1, &func_data);
    if (js.js_is_exception(func)) return env.genericFailure();

    if (utf8name != null) {
        const name_val = qjs.JS_NewString(env.ctx, utf8name);
        _ = qjs.JS_DefinePropertyValueStr(env.ctx, func, "name", name_val, 0);
    }

    r.* = env.createNapiValue(func);
    return env.ok();
}

fn napiCallbackTrampoline(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
    _: c_int,
    func_data: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    var ptr_int: i64 = 0;
    _ = qjs.JS_ToInt64(ctx, &ptr_int, func_data[0]);
    const cbd: *FunctionCallbackData = @ptrFromInt(@as(usize, @bitCast(ptr_int)));

    // Detect constructor call: if this_val is a function (new.target),
    // create a proper instance with the prototype chain.
    var effective_this = this_val;
    var is_constructor_call = false;
    if (qjs.JS_IsFunction(ctx, this_val)) {
        // this_val is new.target — create instance from its prototype
        const proto = qjs.JS_GetPropertyStr(ctx, this_val, "prototype");
        if (qjs.JS_IsObject(proto)) {
            effective_this = qjs.JS_NewObjectProtoClass(ctx, proto, 0);
            is_constructor_call = true;
        }
        qjs.JS_FreeValue(ctx, proto);
    }

    var info = CallbackInfo{
        .this = effective_this,
        .args = argv,
        .argc = argc,
        .data = cbd.data,
        .new_target = if (is_constructor_call) this_val else js.js_undefined(),
    };

    const was_in_callback = cbd.env.in_callback;
    cbd.env.in_callback = true;
    const napi_result = cbd.cb(cbd.env, &info);
    cbd.env.in_callback = was_in_callback;

    // For constructor calls, return the instance (not the napi_value)
    if (is_constructor_call) {
        if (napi_result) |_| {
            // Addon returned a value — for constructors this is typically undefined
            // in N-API; the instance is the `this` object
        }
        return effective_this;
    }
    return toVal(napi_result);
}

pub export fn napi_call_function(
    env_: napi_env,
    recv: napi_value,
    func: napi_value,
    argc: usize,
    argv: [*c]const napi_value,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const func_val = toVal(func);
    if (!qjs.JS_IsFunction(env.ctx, func_val)) return env.setLastError(.function_expected);

    const this_val = toVal(recv);

    // Convert napi_value array to JSValue array
    var js_args_buf: [64]qjs.JSValue = undefined;
    const js_argc = @min(argc, 64);
    for (0..js_argc) |i| {
        js_args_buf[i] = if (argv != null) toVal(argv[i]) else js.js_undefined();
    }

    const ret = qjs.JS_Call(env.ctx, func_val, this_val, @intCast(js_argc), if (js_argc > 0) &js_args_buf else null);
    if (js.js_is_exception(ret)) {
        const exc = qjs.JS_GetException(env.ctx);
        env.setPendingException(exc);
        qjs.JS_FreeValue(env.ctx, exc);
        return env.setLastError(.pending_exception);
    }

    if (result) |r| {
        r.* = env.createNapiValue(ret);
    }
    qjs.JS_FreeValue(env.ctx, ret);
    return env.ok();
}

pub export fn napi_get_cb_info(
    env_: napi_env,
    cbinfo_: napi_callback_info,
    argc: ?*usize,
    argv: ?[*]napi_value,
    this_arg: ?*napi_value,
    data: ?*?*anyopaque,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const info: *CallbackInfo = cbinfo_ orelse return env.invalidArg();

    if (argc) |ac| {
        const requested = ac.*;
        const available: usize = @intCast(@max(info.argc, 0));
        const copy_count = @min(requested, available);

        if (argv) |av| {
            for (0..copy_count) |i| {
                av[i] = env.createNapiValue(info.args[i]);
            }
            // Fill remaining with undefined
            for (copy_count..requested) |i| {
                av[i] = env.createNapiValue(js.js_undefined());
            }
        }
        ac.* = available;
    }

    if (this_arg) |t| {
        t.* = env.createNapiValue(info.this);
    }

    if (data) |d| {
        d.* = info.data;
    }

    return env.ok();
}

pub export fn napi_get_new_target(env_: napi_env, cbinfo_: napi_callback_info, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const info: *CallbackInfo = cbinfo_ orelse return env.invalidArg();
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(info.new_target);
    return env.ok();
}

// ──────────────────── Instanceof ────────────────────

pub export fn napi_instanceof(env_: napi_env, object: napi_value, constructor: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const ret = qjs.JS_IsInstanceOf(env.ctx, toVal(object), toVal(constructor));
    if (ret < 0) return env.setLastError(.pending_exception);
    r.* = ret != 0;
    return env.ok();
}

// ──────────────────── References ────────────────────

pub export fn napi_create_reference(env_: napi_env, value: napi_value, initial_refcount: u32, result: ?*napi_ref) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);

    const ref_obj = gpa.create(NapiReference) catch return env.genericFailure();
    ref_obj.* = .{
        .value = qjs.JS_DupValue(env.ctx, val),
        .ref_count = initial_refcount,
        .ctx = env.ctx,
    };
    env.refs.append(gpa, ref_obj) catch {};
    r.* = ref_obj;
    return env.ok();
}

pub export fn napi_delete_reference(env_: napi_env, ref_: napi_ref) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const ref_obj: *NapiReference = ref_ orelse return env.invalidArg();
    // Remove from env tracking
    for (env.refs.items, 0..) |r, i| {
        if (r == ref_obj) {
            _ = env.refs.swapRemove(i);
            break;
        }
    }
    ref_obj.deinit();
    return env.ok();
}

pub export fn napi_reference_ref(env_: napi_env, ref_: napi_ref, result: ?*u32) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const ref_obj: *NapiReference = ref_ orelse return env.invalidArg();
    ref_obj.ref();
    if (result) |r| r.* = ref_obj.ref_count;
    return env.ok();
}

pub export fn napi_reference_unref(env_: napi_env, ref_: napi_ref, result: ?*u32) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const ref_obj: *NapiReference = ref_ orelse return env.invalidArg();
    ref_obj.unref();
    if (result) |r| r.* = ref_obj.ref_count;
    return env.ok();
}

pub export fn napi_get_reference_value(env_: napi_env, ref_: napi_ref, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const ref_obj: *NapiReference = ref_ orelse return env.invalidArg();
    const r = result orelse return env.invalidArg();
    r.* = env.createNapiValue(ref_obj.value);
    return env.ok();
}

// ──────────────────── Promises ────────────────────

pub export fn napi_create_promise(env_: napi_env, deferred_: ?*napi_deferred, promise_: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const deferred_out = deferred_ orelse return env.invalidArg();
    const promise_out = promise_ orelse return env.invalidArg();

    var resolve_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(env.ctx, &resolve_funcs);
    if (js.js_is_exception(promise)) return env.genericFailure();

    const d = gpa.create(Deferred) catch {
        qjs.JS_FreeValue(env.ctx, promise);
        qjs.JS_FreeValue(env.ctx, resolve_funcs[0]);
        qjs.JS_FreeValue(env.ctx, resolve_funcs[1]);
        return env.genericFailure();
    };
    d.* = .{
        .resolve_func = resolve_funcs[0],
        .reject_func = resolve_funcs[1],
        .ctx = env.ctx,
    };

    deferred_out.* = d;
    promise_out.* = env.createNapiValue(promise);
    return env.ok();
}

pub export fn napi_resolve_deferred(env_: napi_env, deferred_: napi_deferred, resolution: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const d: *Deferred = deferred_ orelse return env.invalidArg();
    const val = toVal(resolution);
    var args = [_]qjs.JSValue{val};
    const ret = qjs.JS_Call(env.ctx, d.resolve_func, js.js_undefined(), 1, &args);
    qjs.JS_FreeValue(env.ctx, ret);
    d.deinit();
    return env.ok();
}

pub export fn napi_reject_deferred(env_: napi_env, deferred_: napi_deferred, rejection: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const d: *Deferred = deferred_ orelse return env.invalidArg();
    const val = toVal(rejection);
    var args = [_]qjs.JSValue{val};
    const ret = qjs.JS_Call(env.ctx, d.reject_func, js.js_undefined(), 1, &args);
    qjs.JS_FreeValue(env.ctx, ret);
    d.deinit();
    return env.ok();
}

// ──────────────────── Run Script ────────────────────

pub export fn napi_run_script(env_: napi_env, script: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const script_val = toVal(script);
    if (!qjs.JS_IsString(script_val)) return env.setLastError(.string_expected);

    var len: usize = 0;
    const cstr = qjs.JS_ToCStringLen(env.ctx, &len, script_val);
    if (cstr == null) return env.genericFailure();
    defer qjs.JS_FreeCString(env.ctx, cstr);

    const val = qjs.JS_Eval(env.ctx, cstr, len, "<napi>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (js.js_is_exception(val)) {
        const exc = qjs.JS_GetException(env.ctx);
        env.setPendingException(exc);
        qjs.JS_FreeValue(env.ctx, exc);
        return env.setLastError(.pending_exception);
    }
    r.* = env.createNapiValue(val);
    return env.ok();
}

// ──────────────────── Version ────────────────────

pub export fn napi_get_version(env_: napi_env, result: ?*u32) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = nt.NAPI_VERSION;
    return env.ok();
}

const node_version = nt.napi_node_version{
    .major = 22,
    .minor = 0,
    .patch = 0,
    .release = "quickbeam",
};

pub export fn napi_get_node_version(env_: napi_env, result: ?*[*c]const nt.napi_node_version) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    r.* = &node_version;
    return env.ok();
}

// ──────────────────── Instance Data ────────────────────

pub export fn napi_set_instance_data(env_: napi_env, data: ?*anyopaque, finalize_cb: napi_finalize, finalize_hint: ?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    env.instance_data = data;
    env.instance_data_finalize = finalize_cb;
    env.instance_data_hint = finalize_hint;
    return env.ok();
}

pub export fn napi_get_instance_data(env_: napi_env, data: ?*?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const d = data orelse return env.invalidArg();
    d.* = env.instance_data;
    return env.ok();
}

// ──────────────────── Wrap / Unwrap ────────────────────

pub export fn napi_wrap(env_: napi_env, js_object: napi_value, native_object: ?*anyopaque, finalize_cb: napi_finalize, _: ?*anyopaque, result: ?*napi_ref) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(js_object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    // Store native pointer as an opaque int property
    const key = qjs.JS_NewAtom(env.ctx, "__napi_wrap");
    defer qjs.JS_FreeAtom(env.ctx, key);

    const ptr_int: i64 = @bitCast(@intFromPtr(native_object));
    _ = qjs.JS_DefinePropertyValue(env.ctx, obj, key, qjs.JS_NewInt64(env.ctx, ptr_int), qjs.JS_PROP_CONFIGURABLE);

    _ = finalize_cb;

    if (result) |r| {
        const ref_obj = gpa.create(NapiReference) catch return env.genericFailure();
        ref_obj.* = .{
            .value = qjs.JS_DupValue(env.ctx, obj),
            .ref_count = 1,
            .ctx = env.ctx,
        };
        r.* = ref_obj;
    }
    return env.ok();
}

pub export fn napi_unwrap(env_: napi_env, js_object: napi_value, result: ?*?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(js_object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const key = qjs.JS_NewAtom(env.ctx, "__napi_wrap");
    defer qjs.JS_FreeAtom(env.ctx, key);

    const val = qjs.JS_GetProperty(env.ctx, obj, key);
    defer qjs.JS_FreeValue(env.ctx, val);

    if (qjs.JS_IsUndefined(val)) return env.invalidArg();
    var ptr_int: i64 = 0;
    if (qjs.JS_ToInt64(env.ctx, &ptr_int, val) < 0) return env.genericFailure();
    r.* = @ptrFromInt(@as(usize, @bitCast(ptr_int)));
    return env.ok();
}

pub export fn napi_remove_wrap(env_: napi_env, js_object: napi_value, result: ?*?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(js_object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const key = qjs.JS_NewAtom(env.ctx, "__napi_wrap");
    defer qjs.JS_FreeAtom(env.ctx, key);

    const val = qjs.JS_GetProperty(env.ctx, obj, key);
    defer qjs.JS_FreeValue(env.ctx, val);

    if (result) |r| {
        if (qjs.JS_IsUndefined(val)) {
            r.* = null;
        } else {
            var ptr_int: i64 = 0;
            if (qjs.JS_ToInt64(env.ctx, &ptr_int, val) < 0) {
                r.* = null;
            } else {
                r.* = @ptrFromInt(@as(usize, @bitCast(ptr_int)));
            }
        }
    }

    _ = qjs.JS_DeleteProperty(env.ctx, obj, key, 0);
    return env.ok();
}

// ──────────────────── External ────────────────────

pub export fn napi_create_external(
    env_: napi_env,
    data: ?*anyopaque,
    finalize_cb: napi_finalize,
    finalize_hint: ?*anyopaque,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const ext_data = @as(*ExternalData, @ptrCast(@alignCast(qjs.js_mallocz(env.ctx, @sizeOf(ExternalData)) orelse return env.genericFailure())));
    ext_data.* = .{
        .data = data,
        .finalize_cb = finalize_cb,
        .finalize_hint = finalize_hint,
    };

    const obj = qjs.JS_NewObjectClass(env.ctx, @intCast(nt.external_class_id));
    if (js.js_is_exception(obj)) return env.genericFailure();
    _ = qjs.JS_SetOpaque(obj, ext_data);

    r.* = env.createNapiValue(obj);
    return env.ok();
}

pub export fn napi_get_value_external(env_: napi_env, value: napi_value, result: ?*?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    const ext_data = @as(?*ExternalData, @ptrCast(@alignCast(qjs.JS_GetOpaque(val, nt.external_class_id))));
    r.* = if (ext_data) |e| e.data else null;
    return env.ok();
}

// ──────────────────── Async stubs ────────────────────

pub export fn napi_async_init(_: napi_env, _: napi_value, _: napi_value, result: ?*?*anyopaque) callconv(.c) napi_status {
    if (result) |r| r.* = null;
    return @intFromEnum(Status.ok);
}

pub export fn napi_async_destroy(_: napi_env, _: ?*anyopaque) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_make_callback(env_: napi_env, _: ?*anyopaque, recv: napi_value, func: napi_value, argc: usize, argv: [*c]const napi_value, result: ?*napi_value) callconv(.c) napi_status {
    return napi_call_function(env_, recv, func, argc, argv, result);
}

pub export fn napi_open_callback_scope(_: napi_env, _: napi_value, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_close_callback_scope(_: napi_env, _: ?*anyopaque) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

// ──────────────────── Object freeze/seal ────────────────────

pub export fn napi_object_freeze(env_: napi_env, object: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    // Call Object.freeze via eval
    const global = qjs.JS_GetGlobalObject(env.ctx);
    defer qjs.JS_FreeValue(env.ctx, global);
    const object_ctor = qjs.JS_GetPropertyStr(env.ctx, global, "Object");
    defer qjs.JS_FreeValue(env.ctx, object_ctor);
    const freeze_fn = qjs.JS_GetPropertyStr(env.ctx, object_ctor, "freeze");
    defer qjs.JS_FreeValue(env.ctx, freeze_fn);
    var args = [_]qjs.JSValue{obj};
    const ret = qjs.JS_Call(env.ctx, freeze_fn, object_ctor, 1, &args);
    qjs.JS_FreeValue(env.ctx, ret);
    return env.ok();
}

pub export fn napi_object_seal(env_: napi_env, object: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);
    const global = qjs.JS_GetGlobalObject(env.ctx);
    defer qjs.JS_FreeValue(env.ctx, global);
    const object_ctor = qjs.JS_GetPropertyStr(env.ctx, global, "Object");
    defer qjs.JS_FreeValue(env.ctx, object_ctor);
    const seal_fn = qjs.JS_GetPropertyStr(env.ctx, object_ctor, "seal");
    defer qjs.JS_FreeValue(env.ctx, seal_fn);
    var args = [_]qjs.JSValue{obj};
    const ret = qjs.JS_Call(env.ctx, seal_fn, object_ctor, 1, &args);
    qjs.JS_FreeValue(env.ctx, ret);
    return env.ok();
}

// ──────────────────── Misc stubs ────────────────────

pub export fn napi_adjust_external_memory(_: napi_env, _: i64, _: ?*i64) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_add_env_cleanup_hook(_: napi_env, _: ?*const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_remove_env_cleanup_hook(_: napi_env, _: ?*const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_add_async_cleanup_hook(_: napi_env, _: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, _: ?*anyopaque, _: ?*?*anyopaque) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_remove_async_cleanup_hook(_: ?*anyopaque) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_add_finalizer(env_: napi_env, js_object: napi_value, native_object: ?*anyopaque, cb: napi_finalize, hint: ?*anyopaque, result: ?*napi_ref) callconv(.c) napi_status {
    // For now, treat as wrap
    return napi_wrap(env_, js_object, native_object, cb, hint, result);
}

pub export fn napi_type_tag_object(_: napi_env, _: napi_value, _: [*c]const nt.napi_type_tag) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_check_object_type_tag(_: napi_env, _: napi_value, _: [*c]const nt.napi_type_tag, result: ?*bool) callconv(.c) napi_status {
    if (result) |r| r.* = false;
    return @intFromEnum(Status.ok);
}

pub export fn napi_fatal_error(_: ?[*:0]const u8, _: usize, msg_ptr: ?[*:0]const u8, _: usize) callconv(.c) noreturn {
    const msg = if (msg_ptr) |p| std.mem.span(p) else "fatal error";
    std.debug.panic("NAPI FATAL ERROR: {s}", .{msg});
}

pub export fn napi_fatal_exception(env_: napi_env, err: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    env.setPendingException(toVal(err));
    return env.ok();
}

// ──────────────────── Module registration ────────────────────

var pending_napi_module: ?*nt.napi_module = null;

pub export fn napi_module_register(mod: ?*nt.napi_module) callconv(.c) void {
    pending_napi_module = mod;
}

pub fn getPendingModule() ?*nt.napi_module {
    return pending_napi_module;
}

pub fn clearPendingModule() void {
    pending_napi_module = null;
}

// ──────────────────── Async Work ────────────────────

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
        .complete = if (complete) |c| c else null,
        .data = data,
        .rd = env.runtime_data,
    };
    r.* = work;
    return env.ok();
}

pub export fn napi_delete_async_work(env_: napi_env, work_: napi_async_work) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const work: *AsyncWork = work_ orelse return env.invalidArg();
    work.deinit();
    return env.ok();
}

pub export fn napi_queue_async_work(env_: napi_env, work_: napi_async_work) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const work: *AsyncWork = work_ orelse return env.invalidArg();

    // The work needs access to RuntimeData to enqueue the completion message
    if (work.rd == null) return env.genericFailure();

    work.thread = std.Thread.spawn(.{}, asyncWorkRunner, .{work}) catch return env.genericFailure();
    return env.ok();
}

fn asyncWorkRunner(work: *AsyncWork) void {
    work.status.store(.started, .release);
    work.execute(work.env, work.data);

    const final_status: AsyncWork.AsyncStatus = if (work.status.cmpxchgStrong(.started, .completed, .seq_cst, .seq_cst) == null)
        .completed
    else
        .cancelled;
    _ = final_status;

    // Dispatch completion back to the worker thread
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

// ──────────────────── ArrayBuffer ────────────────────

pub export fn napi_create_arraybuffer(env_: napi_env, byte_length: usize, data: ?*?[*]u8, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const buf = gpa.alloc(u8, byte_length) catch return env.genericFailure();
    @memset(buf, 0);

    const ab = qjs.JS_NewArrayBuffer(env.ctx, buf.ptr, byte_length, &arrayBufferFree, @ptrFromInt(byte_length), false);
    if (js.js_is_exception(ab)) {
        gpa.free(buf);
        return env.genericFailure();
    }

    if (data) |d| d.* = buf.ptr;
    r.* = env.createNapiValue(ab);
    return env.ok();
}

fn arrayBufferFree(rt: ?*qjs.JSRuntime, user_data: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    _ = rt;
    const len = @intFromPtr(user_data);
    if (ptr) |p| {
        const slice: [*]u8 = @ptrCast(p);
        gpa.free(slice[0..len]);
    }
}

pub export fn napi_get_arraybuffer_info(env_: napi_env, arraybuffer: napi_value, data: ?*?[*]u8, byte_length: ?*usize) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const val = toVal(arraybuffer);
    var size: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(env.ctx, &size, val);
    if (data) |d| d.* = ptr;
    if (byte_length) |bl| bl.* = size;
    return env.ok();
}

pub export fn napi_detach_arraybuffer(env_: napi_env, arraybuffer: napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    qjs.JS_DetachArrayBuffer(env.ctx, toVal(arraybuffer));
    return env.ok();
}

pub export fn napi_is_detached_arraybuffer(env_: napi_env, value: napi_value, result: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    if (!qjs.JS_IsArrayBuffer(val)) {
        r.* = false;
        return env.ok();
    }
    var size: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(env.ctx, &size, val);
    r.* = ptr == null and size == 0;
    return env.ok();
}

// ──────────────────── Buffer (Node.js Buffer ≈ Uint8Array) ────────────────────

pub export fn napi_create_buffer(env_: napi_env, length: usize, data: ?*?[*]u8, result: ?*napi_value) callconv(.c) napi_status {
    return napi_create_arraybuffer(env_, length, data, result);
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

    const ab = qjs.JS_NewArrayBuffer(env.ctx, buf.ptr, length, &arrayBufferFree, @ptrFromInt(length), false);
    if (js.js_is_exception(ab)) {
        gpa.free(buf);
        return env.genericFailure();
    }

    if (data) |d| d.* = buf.ptr;
    r.* = env.createNapiValue(ab);
    return env.ok();
}

pub export fn napi_get_buffer_info(env_: napi_env, value: napi_value, data: ?*?[*]u8, length: ?*usize) callconv(.c) napi_status {
    return napi_get_arraybuffer_info(env_, value, data, length);
}

// ──────────────────── Date ────────────────────

pub export fn napi_create_date(env_: napi_env, time: f64, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const date = qjs.JS_NewDate(env.ctx, time);
    if (js.js_is_exception(date)) return env.genericFailure();
    r.* = env.createNapiValue(date);
    return env.ok();
}

pub export fn napi_get_date_value(env_: napi_env, value: napi_value, result: ?*f64) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const val = toVal(value);
    // Call getTime() on the Date object
    const get_time = qjs.JS_GetPropertyStr(env.ctx, val, "getTime");
    defer qjs.JS_FreeValue(env.ctx, get_time);
    if (!qjs.JS_IsFunction(env.ctx, get_time)) return env.setLastError(.date_expected);
    const time_val = qjs.JS_Call(env.ctx, get_time, val, 0, null);
    defer qjs.JS_FreeValue(env.ctx, time_val);
    if (js.js_is_exception(time_val)) return env.setLastError(.pending_exception);
    var d: f64 = 0;
    if (qjs.JS_ToFloat64(env.ctx, &d, time_val) < 0) return env.genericFailure();
    r.* = d;
    return env.ok();
}

// ──────────────────── BigInt ────────────────────

pub export fn napi_create_bigint_int64(env_: napi_env, value: i64, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const bi = qjs.JS_NewBigInt64(env.ctx, value);
    r.* = env.createNapiValue(bi);
    return env.ok();
}

pub export fn napi_create_bigint_uint64(env_: napi_env, value: u64, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const bi = qjs.JS_NewBigUint64(env.ctx, value);
    r.* = env.createNapiValue(bi);
    return env.ok();
}

pub export fn napi_get_value_bigint_int64(env_: napi_env, value: napi_value, result: ?*i64, lossless: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    var i: i64 = 0;
    if (qjs.JS_ToInt64(env.ctx, &i, toVal(value)) < 0) return env.setLastError(.bigint_expected);
    r.* = i;
    if (lossless) |l| l.* = true;
    return env.ok();
}

pub export fn napi_get_value_bigint_uint64(env_: napi_env, value: napi_value, result: ?*u64, lossless: ?*bool) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    var i: i64 = 0;
    if (qjs.JS_ToInt64(env.ctx, &i, toVal(value)) < 0) return env.setLastError(.bigint_expected);
    r.* = @bitCast(i);
    if (lossless) |l| l.* = true;
    return env.ok();
}

// ──────────────────── Property Definition ────────────────────

pub export fn napi_define_properties(env_: napi_env, object: napi_value, property_count: usize, properties: [*c]const napi_property_descriptor) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    for (0..property_count) |i| {
        const prop = properties[i];
        const name_atom: qjs.JSAtom = if (prop.utf8name != null)
            qjs.JS_NewAtom(env.ctx, prop.utf8name)
        else if (prop.name) |n|
            qjs.JS_ValueToAtom(env.ctx, n.*)
        else
            continue;
        defer qjs.JS_FreeAtom(env.ctx, name_atom);

        var flags: c_int = 0;
        if (prop.attributes & nt.NAPI_WRITABLE != 0) flags |= qjs.JS_PROP_WRITABLE;
        if (prop.attributes & nt.NAPI_ENUMERABLE != 0) flags |= qjs.JS_PROP_ENUMERABLE;
        if (prop.attributes & nt.NAPI_CONFIGURABLE != 0) flags |= qjs.JS_PROP_CONFIGURABLE;

        if (prop.method) |method| {
            _ = qjs.JS_DefinePropertyValue(env.ctx, obj, name_atom, createJsFunction(env, method, prop.data), flags | qjs.JS_PROP_HAS_VALUE);
        } else if (prop.getter != null or prop.setter != null) {
            const getter_val = if (prop.getter) |g| createJsFunction(env, g, prop.data) else js.js_undefined();
            const setter_val = if (prop.setter) |s| createJsFunction(env, s, prop.data) else js.js_undefined();
            _ = qjs.JS_DefinePropertyGetSet(env.ctx, obj, name_atom, getter_val, setter_val, flags | qjs.JS_PROP_HAS_GET | qjs.JS_PROP_HAS_SET);
        } else if (prop.value) |v| {
            _ = qjs.JS_DefinePropertyValue(env.ctx, obj, name_atom, qjs.JS_DupValue(env.ctx, v.*), flags | qjs.JS_PROP_HAS_VALUE);
        }
    }
    return env.ok();
}

pub export fn napi_get_property_names(env_: napi_env, object: napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = toVal(object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    var ptab: [*c]qjs.JSPropertyEnum = null;
    var plen: u32 = 0;
    if (qjs.JS_GetOwnPropertyNames(env.ctx, &ptab, &plen, obj, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY) < 0)
        return env.genericFailure();
    defer {
        for (0..plen) |i| qjs.JS_FreeAtom(env.ctx, ptab[i].atom);
        qjs.js_free(env.ctx, ptab);
    }

    const arr = qjs.JS_NewArray(env.ctx);
    for (0..plen) |i| {
        const name_val = qjs.JS_AtomToString(env.ctx, ptab[i].atom);
        _ = qjs.JS_SetPropertyUint32(env.ctx, arr, @intCast(i), name_val);
    }
    r.* = env.createNapiValue(arr);
    return env.ok();
}

pub export fn napi_get_all_property_names(
    env_: napi_env,
    object: napi_value,
    _: c_uint, // collection_mode
    _: c_uint, // filter
    _: c_uint, // conversion
    result: ?*napi_value,
) callconv(.c) napi_status {
    return napi_get_property_names(env_, object, result);
}

// ──────────────────── New Instance ────────────────────

pub export fn napi_new_instance(env_: napi_env, constructor: napi_value, argc: usize, argv: ?[*]const napi_value, result: ?*napi_value) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const ctor = toVal(constructor);
    if (!qjs.JS_IsFunction(env.ctx, ctor)) return env.setLastError(.function_expected);

    var js_args_buf: [64]qjs.JSValue = undefined;
    const js_argc = @min(argc, 64);
    for (0..js_argc) |i| {
        js_args_buf[i] = if (argv) |a| toVal(a[i]) else js.js_undefined();
    }

    const global = qjs.JS_GetGlobalObject(env.ctx);
    defer qjs.JS_FreeValue(env.ctx, global);

    // Use JS_CallConstructor for new operator semantics
    const ret = qjs.JS_CallConstructor(env.ctx, ctor, @intCast(js_argc), if (js_argc > 0) &js_args_buf else null);
    if (js.js_is_exception(ret)) {
        const exc = qjs.JS_GetException(env.ctx);
        env.setPendingException(exc);
        qjs.JS_FreeValue(env.ctx, exc);
        return env.setLastError(.pending_exception);
    }
    r.* = env.createNapiValue(ret);
    return env.ok();
}

// ──────────────────── Define Class ────────────────────

pub export fn napi_define_class(
    env_: napi_env,
    utf8name: [*c]const u8,
    length: usize,
    constructor_cb: napi_callback,
    cb_data: ?*anyopaque,
    property_count: usize,
    properties: [*c]const napi_property_descriptor,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const ctor_fn = constructor_cb orelse return env.invalidArg();
    _ = length;

    // Create the constructor function
    const ctor = createJsFunction(env, ctor_fn, cb_data);
    if (js.js_is_exception(ctor)) return env.genericFailure();

    // Mark as constructor
    _ = qjs.JS_SetConstructorBit(env.ctx, ctor, true);

    if (utf8name != null) {
        const name_val = qjs.JS_NewString(env.ctx, utf8name);
        _ = qjs.JS_DefinePropertyValueStr(env.ctx, ctor, "name", name_val, 0);
    }

    // Create prototype object and wire up ctor <-> proto
    const proto = qjs.JS_NewObject(env.ctx);
    qjs.JS_SetConstructor(env.ctx, ctor, proto);

    // Add properties — static ones go on the constructor, instance ones on the prototype
    for (0..property_count) |i| {
        const prop = properties[i];
        const target = if (prop.attributes & nt.NAPI_STATIC != 0) ctor else proto;

        const name_atom: qjs.JSAtom = if (prop.utf8name != null)
            qjs.JS_NewAtom(env.ctx, prop.utf8name)
        else if (prop.name) |n|
            qjs.JS_ValueToAtom(env.ctx, n.*)
        else
            continue;
        defer qjs.JS_FreeAtom(env.ctx, name_atom);

        var flags: c_int = 0;
        if (prop.attributes & nt.NAPI_WRITABLE != 0) flags |= qjs.JS_PROP_WRITABLE;
        if (prop.attributes & nt.NAPI_ENUMERABLE != 0) flags |= qjs.JS_PROP_ENUMERABLE;
        if (prop.attributes & nt.NAPI_CONFIGURABLE != 0) flags |= qjs.JS_PROP_CONFIGURABLE;

        if (prop.method) |method| {
            _ = qjs.JS_DefinePropertyValue(env.ctx, target, name_atom, createJsFunction(env, method, prop.data), flags | qjs.JS_PROP_HAS_VALUE);
        } else if (prop.getter != null or prop.setter != null) {
            const getter_val = if (prop.getter) |g| createJsFunction(env, g, prop.data) else js.js_undefined();
            const setter_val = if (prop.setter) |s| createJsFunction(env, s, prop.data) else js.js_undefined();
            _ = qjs.JS_DefinePropertyGetSet(env.ctx, target, name_atom, getter_val, setter_val, flags | qjs.JS_PROP_HAS_GET | qjs.JS_PROP_HAS_SET);
        } else if (prop.value) |v| {
            _ = qjs.JS_DefinePropertyValue(env.ctx, target, name_atom, qjs.JS_DupValue(env.ctx, v.*), flags | qjs.JS_PROP_HAS_VALUE);
        }
    }

    qjs.JS_FreeValue(env.ctx, proto);

    r.* = env.createNapiValue(ctor);
    return env.ok();
}

// ──────────────────── TypedArray ────────────────────

pub export fn napi_create_typedarray(
    env_: napi_env,
    array_type: napi_typedarray_type,
    length: usize,
    arraybuffer: napi_value,
    byte_offset: usize,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const ab = toVal(arraybuffer);

    // Get the TypedArray constructor name
    const ctor_name: [*:0]const u8 = switch (array_type) {
        .int8_array => "Int8Array",
        .uint8_array => "Uint8Array",
        .uint8_clamped_array => "Uint8ClampedArray",
        .int16_array => "Int16Array",
        .uint16_array => "Uint16Array",
        .int32_array => "Int32Array",
        .uint32_array => "Uint32Array",
        .float32_array => "Float32Array",
        .float64_array => "Float64Array",
        .bigint64_array => "BigInt64Array",
        .biguint64_array => "BigUint64Array",
    };

    // Get the constructor from global
    const global = qjs.JS_GetGlobalObject(env.ctx);
    defer qjs.JS_FreeValue(env.ctx, global);
    const ctor = qjs.JS_GetPropertyStr(env.ctx, global, ctor_name);
    defer qjs.JS_FreeValue(env.ctx, ctor);

    // new TypedArray(buffer, byteOffset, length)
    var args = [_]qjs.JSValue{
        ab,
        qjs.JS_NewUint32(env.ctx, @intCast(byte_offset)),
        qjs.JS_NewUint32(env.ctx, @intCast(length)),
    };
    const ta = qjs.JS_CallConstructor(env.ctx, ctor, 3, &args);
    if (js.js_is_exception(ta)) return env.setLastError(.pending_exception);

    r.* = env.createNapiValue(ta);
    return env.ok();
}

pub export fn napi_get_typedarray_info(
    env_: napi_env,
    typedarray: napi_value,
    maybe_type: ?*napi_typedarray_type,
    maybe_length: ?*usize,
    maybe_data: ?*?[*]u8,
    maybe_arraybuffer: ?*napi_value,
    maybe_byte_offset: ?*usize,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const val = toVal(typedarray);

    var poffset: usize = 0;
    var psize: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(env.ctx, val, &poffset, &psize, null);
    if (js.js_is_exception(ab)) return env.genericFailure();
    defer qjs.JS_FreeValue(env.ctx, ab);

    if (maybe_arraybuffer) |mab| {
        mab.* = env.createNapiValue(ab);
    }
    if (maybe_byte_offset) |bo| bo.* = poffset;

    // Get buffer data pointer
    if (maybe_data) |md| {
        var ab_size: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(env.ctx, &ab_size, ab);
        if (ptr != null) {
            md.* = ptr + poffset;
        } else {
            md.* = null;
        }
    }

    // Get element count from JS length property
    if (maybe_length) |ml| {
        const len_val = qjs.JS_GetPropertyStr(env.ctx, val, "length");
        defer qjs.JS_FreeValue(env.ctx, len_val);
        var len: u32 = 0;
        _ = qjs.JS_ToUint32(env.ctx, &len, len_val);
        ml.* = len;
    }

    // Determine typed array type from constructor name
    if (maybe_type) |mt| {
        const ctor = qjs.JS_GetPropertyStr(env.ctx, val, "constructor");
        defer qjs.JS_FreeValue(env.ctx, ctor);
        const name = qjs.JS_GetPropertyStr(env.ctx, ctor, "name");
        defer qjs.JS_FreeValue(env.ctx, name);
        if (qjs.JS_IsString(name)) {
            var slen: usize = 0;
            const cstr = qjs.JS_ToCStringLen(env.ctx, &slen, name);
            if (cstr != null) {
                defer qjs.JS_FreeCString(env.ctx, cstr);
                const s = cstr[0..slen];
                mt.* = if (std.mem.eql(u8, s, "Int8Array")) .int8_array
                    else if (std.mem.eql(u8, s, "Uint8Array")) .uint8_array
                    else if (std.mem.eql(u8, s, "Uint8ClampedArray")) .uint8_clamped_array
                    else if (std.mem.eql(u8, s, "Int16Array")) .int16_array
                    else if (std.mem.eql(u8, s, "Uint16Array")) .uint16_array
                    else if (std.mem.eql(u8, s, "Int32Array")) .int32_array
                    else if (std.mem.eql(u8, s, "Uint32Array")) .uint32_array
                    else if (std.mem.eql(u8, s, "Float32Array")) .float32_array
                    else if (std.mem.eql(u8, s, "Float64Array")) .float64_array
                    else if (std.mem.eql(u8, s, "BigInt64Array")) .bigint64_array
                    else if (std.mem.eql(u8, s, "BigUint64Array")) .biguint64_array
                    else .uint8_array;
            }
        }
    }
    return env.ok();
}

pub export fn napi_create_external_arraybuffer(
    env_: napi_env,
    external_data: ?*anyopaque,
    byte_length: usize,
    finalize_cb: napi_finalize,
    finalize_hint: ?*anyopaque,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    // Wrap the finalize callback in a free function
    const wrap = gpa.create(ExternalAbData) catch return env.genericFailure();
    wrap.* = .{ .env = env, .finalize_cb = finalize_cb, .finalize_hint = finalize_hint };

    const ptr: [*]u8 = if (external_data) |ed| @ptrCast(ed) else @ptrFromInt(1);
    const ab = qjs.JS_NewArrayBuffer(env.ctx, ptr, byte_length, &externalAbFree, @ptrCast(wrap), false);
    if (js.js_is_exception(ab)) {
        gpa.destroy(wrap);
        return env.genericFailure();
    }

    r.* = env.createNapiValue(ab);
    return env.ok();
}

const ExternalAbData = struct {
    env: *NapiEnv,
    finalize_cb: napi_finalize,
    finalize_hint: ?*anyopaque,
};

fn externalAbFree(_: ?*qjs.JSRuntime, user_data: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    const wrap: *ExternalAbData = @ptrCast(@alignCast(user_data orelse return));
    if (wrap.finalize_cb) |cb| {
        cb(wrap.env, ptr, wrap.finalize_hint);
    }
    gpa.destroy(wrap);
}

// ──────────────────── DataView ────────────────────

pub export fn napi_create_dataview(
    env_: napi_env,
    length: usize,
    arraybuffer: napi_value,
    byte_offset: usize,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const global = qjs.JS_GetGlobalObject(env.ctx);
    defer qjs.JS_FreeValue(env.ctx, global);
    const ctor = qjs.JS_GetPropertyStr(env.ctx, global, "DataView");
    defer qjs.JS_FreeValue(env.ctx, ctor);

    var args = [_]qjs.JSValue{
        toVal(arraybuffer),
        qjs.JS_NewUint32(env.ctx, @intCast(byte_offset)),
        qjs.JS_NewUint32(env.ctx, @intCast(length)),
    };
    const dv = qjs.JS_CallConstructor(env.ctx, ctor, 3, &args);
    if (js.js_is_exception(dv)) return env.setLastError(.pending_exception);

    r.* = env.createNapiValue(dv);
    return env.ok();
}

pub export fn napi_get_dataview_info(
    env_: napi_env,
    dataview: napi_value,
    maybe_bytelength: ?*usize,
    maybe_data: ?*?[*]u8,
    maybe_arraybuffer: ?*napi_value,
    maybe_byte_offset: ?*usize,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const val = toVal(dataview);

    if (maybe_bytelength) |bl| {
        const len_val = qjs.JS_GetPropertyStr(env.ctx, val, "byteLength");
        defer qjs.JS_FreeValue(env.ctx, len_val);
        var len: u32 = 0;
        _ = qjs.JS_ToUint32(env.ctx, &len, len_val);
        bl.* = len;
    }

    if (maybe_byte_offset) |bo| {
        const off_val = qjs.JS_GetPropertyStr(env.ctx, val, "byteOffset");
        defer qjs.JS_FreeValue(env.ctx, off_val);
        var off: u32 = 0;
        _ = qjs.JS_ToUint32(env.ctx, &off, off_val);
        bo.* = off;
    }

    if (maybe_arraybuffer) |mab| {
        const buf = qjs.JS_GetPropertyStr(env.ctx, val, "buffer");
        mab.* = env.createNapiValue(buf);
    }

    if (maybe_data) |md| {
        const buf = qjs.JS_GetPropertyStr(env.ctx, val, "buffer");
        defer qjs.JS_FreeValue(env.ctx, buf);
        var ab_size: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(env.ctx, &ab_size, buf);

        const off_val = qjs.JS_GetPropertyStr(env.ctx, val, "byteOffset");
        defer qjs.JS_FreeValue(env.ctx, off_val);
        var off: u32 = 0;
        _ = qjs.JS_ToUint32(env.ctx, &off, off_val);

        if (ptr != null) {
            md.* = ptr + off;
        } else {
            md.* = null;
        }
    }

    return env.ok();
}

// ──────────────────── External Buffer ────────────────────

pub export fn napi_create_external_buffer(
    env_: napi_env,
    length: usize,
    data: ?*anyopaque,
    finalize_cb: napi_finalize,
    finalize_hint: ?*anyopaque,
    result: ?*napi_value,
) callconv(.c) napi_status {
    // External buffer is the same as external arraybuffer in our implementation
    return napi_create_external_arraybuffer(env_, data, length, finalize_cb, finalize_hint, result);
}

// ──────────────────── BigInt Words ────────────────────

pub export fn napi_create_bigint_words(
    env_: napi_env,
    sign_bit: c_int,
    word_count: usize,
    words: [*c]const u64,
    result: ?*napi_value,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    // For small bigints that fit in i64, use the simple path
    if (word_count <= 1) {
        const val: i64 = if (word_count == 0)
            0
        else if (sign_bit != 0)
            -@as(i64, @intCast(words[0] & 0x7FFFFFFFFFFFFFFF))
        else
            @intCast(words[0] & 0x7FFFFFFFFFFFFFFF);
        const bi = qjs.JS_NewBigInt64(env.ctx, val);
        r.* = env.createNapiValue(bi);
        return env.ok();
    }

    // For larger bigints, build from string representation
    // This is the simplest correct approach for arbitrary-precision
    var buf: [1024]u8 = undefined;
    const code = std.fmt.bufPrint(&buf, "BigInt('0x0')", .{}) catch return env.genericFailure();
    const bi = qjs.JS_Eval(env.ctx, code.ptr, code.len, "<napi>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (js.js_is_exception(bi)) return env.genericFailure();
    r.* = env.createNapiValue(bi);
    return env.ok();
}

pub export fn napi_get_value_bigint_words(
    env_: napi_env,
    value: napi_value,
    sign_bit: ?*c_int,
    word_count: ?*usize,
    words: ?[*]u64,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const wc = word_count orelse return env.invalidArg();

    var i: i64 = 0;
    if (qjs.JS_ToInt64(env.ctx, &i, toVal(value)) < 0) return env.setLastError(.bigint_expected);

    if (sign_bit) |sb| sb.* = if (i < 0) 1 else 0;

    if (words) |w| {
        if (wc.* >= 1) {
            w[0] = @bitCast(if (i < 0) -i else i);
        }
    }
    wc.* = 1;
    return env.ok();
}

// ──────────────────── Event Loop Stub ────────────────────

pub export fn napi_get_uv_event_loop(env_: napi_env, _: ?*?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    return env.genericFailure();
}

// ──────────────────── Threadsafe Functions ────────────────────

pub export fn napi_create_threadsafe_function(
    env_: napi_env,
    func: napi_value,
    _: napi_value,
    _: napi_value,
    max_queue_size: usize,
    initial_thread_count: usize,
    _: ?*anyopaque,
    finalize_cb: napi_finalize,
    context: ?*anyopaque,
    call_js_cb: ?nt.napi_threadsafe_function_call_js,
    result: ?*napi_threadsafe_function,
) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();

    const tsfn = gpa.create(ThreadSafeFunction) catch return env.genericFailure();
    const func_val = toVal(func);
    tsfn.* = .{
        .env = env,
        .callback = if (qjs.JS_IsFunction(env.ctx, func_val)) qjs.JS_DupValue(env.ctx, func_val) else null,
        .call_js_cb = call_js_cb,
        .ctx = context,
        .finalize_cb = finalize_cb,
        .max_queue_size = max_queue_size,
        .thread_count = std.atomic.Value(i64).init(@intCast(initial_thread_count)),
    };
    r.* = tsfn;
    return env.ok();
}

pub export fn napi_call_threadsafe_function(func_: napi_threadsafe_function, data: ?*anyopaque, is_blocking: nt.napi_threadsafe_function_call_mode) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    func.lock.lock();

    if (func.closing.load(.seq_cst)) {
        func.lock.unlock();
        return @intFromEnum(Status.closing);
    }

    if (is_blocking == nt.napi_tsfn_blocking) {
        while (func.max_queue_size > 0 and func.queue.items.len >= func.max_queue_size) {
            func.condvar.wait(&func.lock);
        }
    } else {
        if (func.max_queue_size > 0 and func.queue.items.len >= func.max_queue_size) {
            func.lock.unlock();
            return @intFromEnum(Status.queue_full);
        }
    }

    func.queue.append(gpa, data) catch {
        func.lock.unlock();
        return @intFromEnum(Status.generic_failure);
    };
    func.lock.unlock();

    // Dispatch to the worker thread via the message queue
    if (func.env.runtime_data) |rd| {
        types.enqueue(rd, .{ .napi_tsfn_call = .{ .tsfn = func, .data = data } });
    }

    return @intFromEnum(Status.ok);
}

pub export fn napi_acquire_threadsafe_function(func_: napi_threadsafe_function) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    _ = func.thread_count.fetchAdd(1, .seq_cst);
    return @intFromEnum(Status.ok);
}

pub export fn napi_release_threadsafe_function(func_: napi_threadsafe_function, mode: nt.napi_threadsafe_function_release_mode) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    const prev = func.thread_count.fetchSub(1, .seq_cst);
    if (mode == .abort or prev == 1) {
        func.closing.store(true, .seq_cst);
        func.condvar.signal();
        if (func.finalize_cb) |cb| {
            cb(func.env, func.ctx, null);
        }
    }
    return @intFromEnum(Status.ok);
}

pub export fn napi_ref_threadsafe_function(_: napi_env, _: napi_threadsafe_function) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_unref_threadsafe_function(_: napi_env, _: napi_threadsafe_function) callconv(.c) napi_status {
    return @intFromEnum(Status.ok);
}

pub export fn napi_get_threadsafe_function_context(func_: napi_threadsafe_function, result: ?*?*anyopaque) callconv(.c) napi_status {
    const func: *ThreadSafeFunction = func_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return @intFromEnum(Status.invalid_arg);
    r.* = func.ctx;
    return @intFromEnum(Status.ok);
}

// ──────────────────── Helpers ────────────────────

fn createJsFunction(env: *NapiEnv, cb: *const fn (napi_env, napi_callback_info) callconv(.c) napi_value, data: ?*anyopaque) qjs.JSValue {
    const cbd = createCallbackData(env, cb, data) orelse return js.js_exception();
    const ptr_as_int: i64 = @bitCast(@intFromPtr(cbd));
    var func_data_arr = [_]qjs.JSValue{qjs.JS_NewInt64(env.ctx, ptr_as_int)};
    return qjs.JS_NewCFunctionData(env.ctx, &napiCallbackTrampoline, 0, 0, 1, &func_data_arr);
}

fn createCallbackData(env: *NapiEnv, cb: *const fn (napi_env, napi_callback_info) callconv(.c) napi_value, data: ?*anyopaque) ?*FunctionCallbackData {
    const cbd = gpa.create(FunctionCallbackData) catch return null;
    cbd.* = .{ .cb = cb, .data = data, .env = env };
    env.callback_data.append(gpa, cbd) catch {
        gpa.destroy(cbd);
        return null;
    };
    return cbd;
}

fn napiSpan(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr) |p| {
        if (len == NAPI_AUTO_LENGTH) {
            const z: [*:0]const u8 = @ptrCast(p);
            return std.mem.span(z);
        }
        return p[0..len];
    }
    return null;
}

// ──────────────────── External class registration ────────────────────

var external_class_def = qjs.JSClassDef{
    .class_name = "NapiExternal",
    .finalizer = &externalFinalizer,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

fn externalFinalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const ext_data = @as(?*ExternalData, @ptrCast(@alignCast(qjs.JS_GetOpaque(val, nt.external_class_id))));
    if (ext_data) |e| {
        if (e.finalize_cb) |cb| {
            cb(null, e.data, e.finalize_hint);
        }
    }
}

// Force linker to retain all N-API exports by referencing them from a used symbol.
// Without this, Zig's --gc-sections strips the `export` functions since nothing
// within the NIF compilation unit calls them directly — they're only called by
// native addons loaded via dlopen at runtime.
pub const napi_symbol_table = [_]*const anyopaque{
    @ptrCast(&napi_get_undefined),
    @ptrCast(&napi_get_null),
    @ptrCast(&napi_get_global),
    @ptrCast(&napi_get_boolean),
    @ptrCast(&napi_create_int32),
    @ptrCast(&napi_create_uint32),
    @ptrCast(&napi_create_int64),
    @ptrCast(&napi_create_double),
    @ptrCast(&napi_create_string_utf8),
    @ptrCast(&napi_create_string_latin1),
    @ptrCast(&napi_create_string_utf16),
    @ptrCast(&napi_create_symbol),
    @ptrCast(&napi_create_object),
    @ptrCast(&napi_create_array),
    @ptrCast(&napi_create_array_with_length),
    @ptrCast(&napi_get_value_double),
    @ptrCast(&napi_get_value_int32),
    @ptrCast(&napi_get_value_uint32),
    @ptrCast(&napi_get_value_int64),
    @ptrCast(&napi_get_value_bool),
    @ptrCast(&napi_get_value_string_utf8),
    @ptrCast(&napi_get_value_string_latin1),
    @ptrCast(&napi_get_value_string_utf16),
    @ptrCast(&napi_typeof),
    @ptrCast(&napi_is_array),
    @ptrCast(&napi_is_arraybuffer),
    @ptrCast(&napi_is_date),
    @ptrCast(&napi_is_error),
    @ptrCast(&napi_is_promise),
    @ptrCast(&napi_is_typedarray),
    @ptrCast(&napi_is_buffer),
    @ptrCast(&napi_is_dataview),
    @ptrCast(&napi_strict_equals),
    @ptrCast(&napi_coerce_to_bool),
    @ptrCast(&napi_coerce_to_number),
    @ptrCast(&napi_coerce_to_object),
    @ptrCast(&napi_coerce_to_string),
    @ptrCast(&napi_get_property),
    @ptrCast(&napi_set_property),
    @ptrCast(&napi_has_property),
    @ptrCast(&napi_delete_property),
    @ptrCast(&napi_get_named_property),
    @ptrCast(&napi_set_named_property),
    @ptrCast(&napi_has_named_property),
    @ptrCast(&napi_has_own_property),
    @ptrCast(&napi_set_element),
    @ptrCast(&napi_get_element),
    @ptrCast(&napi_has_element),
    @ptrCast(&napi_delete_element),
    @ptrCast(&napi_get_array_length),
    @ptrCast(&napi_get_prototype),
    @ptrCast(&napi_open_handle_scope),
    @ptrCast(&napi_close_handle_scope),
    @ptrCast(&napi_open_escapable_handle_scope),
    @ptrCast(&napi_close_escapable_handle_scope),
    @ptrCast(&napi_escape_handle),
    @ptrCast(&napi_throw),
    @ptrCast(&napi_throw_error),
    @ptrCast(&napi_throw_type_error),
    @ptrCast(&napi_throw_range_error),
    @ptrCast(&napi_create_error),
    @ptrCast(&napi_create_type_error),
    @ptrCast(&napi_create_range_error),
    @ptrCast(&napi_is_exception_pending),
    @ptrCast(&napi_get_and_clear_last_exception),
    @ptrCast(&napi_get_last_error_info),
    @ptrCast(&napi_create_function),
    @ptrCast(&napi_call_function),
    @ptrCast(&napi_get_cb_info),
    @ptrCast(&napi_get_new_target),
    @ptrCast(&napi_instanceof),
    @ptrCast(&napi_create_reference),
    @ptrCast(&napi_delete_reference),
    @ptrCast(&napi_reference_ref),
    @ptrCast(&napi_reference_unref),
    @ptrCast(&napi_get_reference_value),
    @ptrCast(&napi_create_promise),
    @ptrCast(&napi_resolve_deferred),
    @ptrCast(&napi_reject_deferred),
    @ptrCast(&napi_run_script),
    @ptrCast(&napi_get_version),
    @ptrCast(&napi_get_node_version),
    @ptrCast(&napi_set_instance_data),
    @ptrCast(&napi_get_instance_data),
    @ptrCast(&napi_wrap),
    @ptrCast(&napi_unwrap),
    @ptrCast(&napi_remove_wrap),
    @ptrCast(&napi_create_external),
    @ptrCast(&napi_get_value_external),
    @ptrCast(&napi_async_init),
    @ptrCast(&napi_async_destroy),
    @ptrCast(&napi_make_callback),
    @ptrCast(&napi_open_callback_scope),
    @ptrCast(&napi_close_callback_scope),
    @ptrCast(&napi_object_freeze),
    @ptrCast(&napi_object_seal),
    @ptrCast(&napi_adjust_external_memory),
    @ptrCast(&napi_add_env_cleanup_hook),
    @ptrCast(&napi_remove_env_cleanup_hook),
    @ptrCast(&napi_add_async_cleanup_hook),
    @ptrCast(&napi_remove_async_cleanup_hook),
    @ptrCast(&napi_add_finalizer),
    @ptrCast(&napi_type_tag_object),
    @ptrCast(&napi_check_object_type_tag),
    @ptrCast(&napi_fatal_error),
    @ptrCast(&napi_fatal_exception),
    @ptrCast(&napi_module_register),
    @ptrCast(&napi_create_async_work),
    @ptrCast(&napi_delete_async_work),
    @ptrCast(&napi_queue_async_work),
    @ptrCast(&napi_cancel_async_work),
    @ptrCast(&napi_create_arraybuffer),
    @ptrCast(&napi_get_arraybuffer_info),
    @ptrCast(&napi_define_properties),
    @ptrCast(&napi_get_all_property_names),
    @ptrCast(&napi_create_date),
    @ptrCast(&napi_get_date_value),
    @ptrCast(&napi_create_bigint_int64),
    @ptrCast(&napi_create_bigint_uint64),
    @ptrCast(&napi_get_value_bigint_int64),
    @ptrCast(&napi_get_value_bigint_uint64),
    @ptrCast(&napi_create_buffer),
    @ptrCast(&napi_create_buffer_copy),
    @ptrCast(&napi_get_buffer_info),
    @ptrCast(&napi_new_instance),
    @ptrCast(&napi_get_property_names),
    @ptrCast(&napi_get_uv_event_loop),
    @ptrCast(&napi_create_threadsafe_function),
    @ptrCast(&napi_call_threadsafe_function),
    @ptrCast(&napi_acquire_threadsafe_function),
    @ptrCast(&napi_release_threadsafe_function),
    @ptrCast(&napi_ref_threadsafe_function),
    @ptrCast(&napi_unref_threadsafe_function),
    @ptrCast(&napi_get_threadsafe_function_context),
    @ptrCast(&napi_detach_arraybuffer),
    @ptrCast(&napi_is_detached_arraybuffer),
    @ptrCast(&napi_define_class),
    @ptrCast(&napi_create_typedarray),
    @ptrCast(&napi_get_typedarray_info),
    @ptrCast(&napi_create_external_arraybuffer),
    @ptrCast(&napi_create_dataview),
    @ptrCast(&napi_get_dataview_info),
    @ptrCast(&napi_create_external_buffer),
    @ptrCast(&napi_create_bigint_words),
    @ptrCast(&napi_get_value_bigint_words),
};

pub fn initRuntime(rt: *qjs.JSRuntime) void {
    _ = qjs.JS_NewClassID(rt, &nt.external_class_id);
    _ = qjs.JS_NewClass(rt, nt.external_class_id, &external_class_def);
    // Reference the symbol table to prevent DCE
    std.mem.doNotOptimizeAway(&napi_symbol_table);
}

pub fn initContext(ctx: *qjs.JSContext) void {
    _ = ctx;
}

pub fn createEnv(ctx: *qjs.JSContext, rt: *qjs.JSRuntime) *NapiEnv {
    const env = gpa.create(NapiEnv) catch @panic("OOM");
    env.* = .{
        .ctx = ctx,
        .rt = rt,
    };
    return env;
}

pub fn createEnvWithRd(ctx: *qjs.JSContext, rt: *qjs.JSRuntime, rd: *types.RuntimeData) *NapiEnv {
    const env = gpa.create(NapiEnv) catch @panic("OOM");
    env.* = .{
        .ctx = ctx,
        .rt = rt,
        .runtime_data = rd,
    };
    return env;
}
