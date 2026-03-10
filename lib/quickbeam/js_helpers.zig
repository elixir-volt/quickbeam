const types = @import("types.zig");
const std = types.std;
const qjs = types.qjs;
const gpa = types.gpa;

pub fn js_undefined() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_UNDEFINED, .u = .{ .int32 = 0 } };
}

pub fn js_null() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_NULL, .u = .{ .int32 = 0 } };
}

pub fn js_true() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_BOOL, .u = .{ .int32 = 1 } };
}

pub fn js_false() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_BOOL, .u = .{ .int32 = 0 } };
}

pub fn js_exception() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_EXCEPTION, .u = .{ .int32 = 0 } };
}

pub fn js_is_exception(v: qjs.JSValue) bool {
    return v.tag == qjs.JS_TAG_EXCEPTION;
}

pub fn json_parse(ctx: *qjs.JSContext, json: []const u8) qjs.JSValue {
    const json_str = qjs.JS_NewStringLen(ctx, json.ptr, json.len);
    defer qjs.JS_FreeValue(ctx, json_str);

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const json_obj = qjs.JS_GetPropertyStr(ctx, global, "JSON");
    defer qjs.JS_FreeValue(ctx, json_obj);

    const parse_fn = qjs.JS_GetPropertyStr(ctx, json_obj, "parse");
    defer qjs.JS_FreeValue(ctx, parse_fn);

    var args = [_]qjs.JSValue{json_str};
    const result = qjs.JS_Call(ctx, parse_fn, json_obj, 1, &args);

    if (js_is_exception(result)) {
        const exc = qjs.JS_GetException(ctx);
        qjs.JS_FreeValue(ctx, exc);
        return qjs.JS_NewStringLen(ctx, json.ptr, json.len);
    }

    return result;
}

pub fn js_to_string(ctx: *qjs.JSContext, val: qjs.JSValue) []const u8 {
    if (qjs.JS_IsUndefined(val) or qjs.JS_IsNull(val)) return "";
    const ptr = qjs.JS_ToCString(ctx, val);
    if (ptr == null) return "";
    const s = std.mem.span(ptr);
    const copy = gpa.dupe(u8, s) catch "";
    qjs.JS_FreeCString(ctx, ptr);
    return copy;
}

pub fn is_promise(ctx: *qjs.JSContext, val: qjs.JSValue) bool {
    if (!qjs.JS_IsObject(val)) return false;
    const then_prop = qjs.JS_GetPropertyStr(ctx, val, "then");
    const result = qjs.JS_IsFunction(ctx, then_prop);
    qjs.JS_FreeValue(ctx, then_prop);
    return result;
}

pub fn cleanup_globals(ctx: *qjs.JSContext, global: qjs.JSValue, status_key: []const u8, value_key: []const u8) void {
    const undef = js_undefined();
    const s_atom = qjs.JS_NewAtomLen(ctx, status_key.ptr, status_key.len);
    _ = qjs.JS_SetProperty(ctx, global, s_atom, undef);
    qjs.JS_FreeAtom(ctx, s_atom);

    const v_atom = qjs.JS_NewAtomLen(ctx, value_key.ptr, value_key.len);
    _ = qjs.JS_SetProperty(ctx, global, v_atom, undef);
    qjs.JS_FreeAtom(ctx, v_atom);
}
