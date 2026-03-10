const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;

const MAX_DEPTH = 32;

const Env = struct { env: ?*e.ErlNifEnv };

pub fn convert(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    return convert_recursive(ctx, val, Env{ .env = env }, 0);
}

pub fn convert_error(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    if (!qjs.JS_IsObject(val)) return convert(ctx, val, env);

    const msg_val = qjs.JS_GetPropertyStr(ctx, val, "message");
    defer qjs.JS_FreeValue(ctx, msg_val);

    if (qjs.JS_IsUndefined(msg_val)) return convert(ctx, val, env);

    const name_val = qjs.JS_GetPropertyStr(ctx, val, "name");
    defer qjs.JS_FreeValue(ctx, name_val);
    const stack_val = qjs.JS_GetPropertyStr(ctx, val, "stack");
    defer qjs.JS_FreeValue(ctx, stack_val);

    const opts = Env{ .env = env };
    return beam.make(.{
        .message = beam.term{ .v = convert_recursive(ctx, msg_val, opts, 0) },
        .name = beam.term{ .v = convert_recursive(ctx, name_val, opts, 0) },
        .stack = beam.term{ .v = convert_recursive(ctx, stack_val, opts, 0) },
    }, opts).v;
}

fn convert_recursive(ctx: *qjs.JSContext, val: qjs.JSValue, opts: Env, depth: u32) e.ErlNifTerm {
    if (depth > MAX_DEPTH) return beam.make_into_atom("nil", opts).v;

    if (qjs.JS_IsUndefined(val) or qjs.JS_IsNull(val)) {
        return beam.make_into_atom("nil", opts).v;
    }

    if (qjs.JS_IsBool(val)) {
        const b = qjs.JS_ToBool(ctx, val);
        return if (b != 0) beam.make_into_atom("true", opts).v else beam.make_into_atom("false", opts).v;
    }

    if (qjs.JS_IsNumber(val)) {
        return convert_number(ctx, val, opts);
    }

    if (qjs.JS_IsBigInt(val)) {
        const ptr = qjs.JS_ToCString(ctx, val);
        if (ptr != null) {
            defer qjs.JS_FreeCString(ctx, ptr);
            return beam.make(std.mem.span(ptr), opts).v;
        }
        return beam.make_into_atom("nil", opts).v;
    }

    if (qjs.JS_IsSymbol(val)) {
        return convert_symbol(ctx, val, opts);
    }

    if (qjs.JS_IsString(val)) {
        var len: usize = 0;
        const ptr = qjs.JS_ToCStringLen(ctx, &len, val);
        if (ptr == null) return beam.make(@as([]const u8, ""), opts).v;
        defer qjs.JS_FreeCString(ctx, ptr);
        return beam.make(@as([*]const u8, @ptrCast(ptr))[0..len], opts).v;
    }

    if (qjs.JS_IsArrayBuffer(val)) {
        var buf_size: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, val);
        if (ptr == null) return beam.make(@as([]const u8, ""), opts).v;
        return beam.make(ptr[0..buf_size], opts).v;
    }

    if (is_typed_array(ctx, val)) {
        return convert_typed_array(ctx, val, opts);
    }

    if (qjs.JS_IsArray(val)) {
        return convert_array(ctx, val, opts, depth);
    }

    if (qjs.JS_IsObject(val)) {
        return convert_object_to_map(ctx, val, opts, depth);
    }

    return beam.make_into_atom("nil", opts).v;
}

fn convert_number(ctx: *qjs.JSContext, val: qjs.JSValue, opts: Env) e.ErlNifTerm {
    if (val.tag == qjs.JS_TAG_INT) {
        var i: i32 = 0;
        _ = qjs.JS_ToInt32(ctx, &i, val);
        return beam.make(i, opts).v;
    }
    var d: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx, &d, val);
    if (!std.math.isFinite(d)) {
        if (std.math.isNan(d)) return beam.make_into_atom("NaN", opts).v;
        if (d > 0) return beam.make_into_atom("Infinity", opts).v;
        return beam.make_into_atom("-Infinity", opts).v;
    }
    if (d == @trunc(d) and d >= -9007199254740991 and d <= 9007199254740991) {
        return beam.make(@as(i64, @intFromFloat(d)), opts).v;
    }
    return beam.make(d, opts).v;
}

fn convert_typed_array(ctx: *qjs.JSContext, val: qjs.JSValue, opts: Env) e.ErlNifTerm {
    var byte_offset: usize = 0;
    var byte_len: usize = 0;
    var bytes_per_element: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(ctx, val, &byte_offset, &byte_len, &bytes_per_element);
    if (!js.js_is_exception(ab)) {
        defer qjs.JS_FreeValue(ctx, ab);
        var buf_size: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, ab);
        if (ptr != null) {
            return beam.make(ptr[byte_offset .. byte_offset + byte_len], opts).v;
        }
    }
    return beam.make(@as([]const u8, ""), opts).v;
}

fn convert_array(ctx: *qjs.JSContext, val: qjs.JSValue, opts: Env, depth: u32) e.ErlNifTerm {
    const len_val = qjs.JS_GetPropertyStr(ctx, val, "length");
    defer qjs.JS_FreeValue(ctx, len_val);

    var len: i64 = 0;
    _ = qjs.JS_ToInt64(ctx, &len, len_val);
    if (len < 0) len = 0;
    const ulen: usize = @intCast(len);

    var list = beam.make_empty_list(opts);
    var i: usize = ulen;
    while (i > 0) {
        i -= 1;
        const elem = qjs.JS_GetPropertyUint32(ctx, val, @intCast(i));
        defer qjs.JS_FreeValue(ctx, elem);
        const term = beam.term{ .v = convert_recursive(ctx, elem, opts, depth + 1) };
        list = beam.make_list_cell(term, list, opts);
    }
    return list.v;
}

fn convert_object_to_map(ctx: *qjs.JSContext, val: qjs.JSValue, opts: Env, depth: u32) e.ErlNifTerm {
    var ptab: ?*qjs.JSPropertyEnum = null;
    var plen: u32 = 0;

    if (qjs.JS_GetOwnPropertyNames(ctx, &ptab, &plen, val, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY) != 0) {
        return empty_map(opts);
    }

    if (plen == 0) {
        if (ptab) |p| qjs.js_free(ctx, p);
        return empty_map(opts);
    }

    const tab_single = ptab orelse return empty_map(opts);
    defer qjs.js_free(ctx, tab_single);
    const tab: [*]qjs.JSPropertyEnum = @ptrCast(tab_single);

    const keys = gpa.alloc(e.ErlNifTerm, plen) catch return empty_map(opts);
    defer gpa.free(keys);
    const vals = gpa.alloc(e.ErlNifTerm, plen) catch return empty_map(opts);
    defer gpa.free(vals);

    for (0..plen) |i| {
        const atom = tab[i].atom;

        const key_val = qjs.JS_AtomToString(ctx, atom);
        defer qjs.JS_FreeValue(ctx, key_val);
        var key_len: usize = 0;
        const key_ptr = qjs.JS_ToCStringLen(ctx, &key_len, key_val);
        if (key_ptr != null) {
            keys[i] = beam.make(@as([*]const u8, @ptrCast(key_ptr))[0..key_len], opts).v;
            qjs.JS_FreeCString(ctx, key_ptr);
        } else {
            keys[i] = beam.make(@as([]const u8, ""), opts).v;
        }

        const prop = qjs.JS_GetProperty(ctx, val, atom);
        defer qjs.JS_FreeValue(ctx, prop);
        vals[i] = convert_recursive(ctx, prop, opts, depth + 1);
    }

    for (0..plen) |i| {
        qjs.JS_FreeAtom(ctx, tab[i].atom);
    }

    // SAFETY: immediately filled by enif_make_map_from_arrays
    var result: e.ErlNifTerm = undefined;
    if (e.enif_make_map_from_arrays(opts.env, keys.ptr, vals.ptr, plen, &result) != 0) {
        return result;
    }
    return empty_map(opts);
}

fn empty_map(opts: Env) e.ErlNifTerm {
    // SAFETY: immediately filled by enif_make_map_from_arrays
    var result: e.ErlNifTerm = undefined;
    _ = e.enif_make_map_from_arrays(opts.env, null, null, 0, &result);
    return result;
}

fn convert_symbol(ctx: *qjs.JSContext, val: qjs.JSValue, opts: Env) e.ErlNifTerm {
    const desc_val = qjs.JS_GetPropertyStr(ctx, val, "description");
    defer qjs.JS_FreeValue(ctx, desc_val);

    if (qjs.JS_IsString(desc_val)) {
        const ptr = qjs.JS_ToCString(ctx, desc_val);
        if (ptr != null) {
            defer qjs.JS_FreeCString(ctx, ptr);
            return beam.make_into_atom(std.mem.span(ptr), opts).v;
        }
    }
    return beam.make_into_atom("symbol", opts).v;
}

fn is_typed_array(ctx: *qjs.JSContext, val: qjs.JSValue) bool {
    if (!qjs.JS_IsObject(val)) return false;
    var byte_offset: usize = 0;
    var byte_len: usize = 0;
    var bytes_per_element: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(ctx, val, &byte_offset, &byte_len, &bytes_per_element);
    if (js.js_is_exception(ab)) {
        const exc = qjs.JS_GetException(ctx);
        qjs.JS_FreeValue(ctx, exc);
        return false;
    }
    qjs.JS_FreeValue(ctx, ab);
    return true;
}
