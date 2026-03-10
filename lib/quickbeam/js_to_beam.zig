const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;

const MAX_DEPTH = 32;

pub fn convert(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    return convert_recursive(ctx, val, env, 0);
}

fn convert_recursive(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv, depth: u32) e.ErlNifTerm {
    if (depth > MAX_DEPTH) return make_atom(env, "nil");

    // undefined / null → nil
    if (qjs.JS_IsUndefined(val) or qjs.JS_IsNull(val)) {
        return make_atom(env, "nil");
    }

    // boolean
    if (qjs.JS_IsBool(val)) {
        const b = qjs.JS_ToBool(ctx, val);
        return if (b != 0) make_atom(env, "true") else make_atom(env, "false");
    }

    // number
    if (qjs.JS_IsNumber(val)) {
        // Try integer first
        if (val.tag == qjs.JS_TAG_INT) {
            var i: i32 = 0;
            _ = qjs.JS_ToInt32(ctx, &i, val);
            return e.enif_make_int(env, i);
        }
        var d: f64 = 0;
        _ = qjs.JS_ToFloat64(ctx, &d, val);
        if (!std.math.isFinite(d)) {
            if (std.math.isNan(d)) return make_atom(env, "NaN");
            if (d > 0) return make_atom(env, "Infinity");
            return make_atom(env, "-Infinity");
        }
        // If it's a whole number that fits in i64, return as integer
        if (d == @trunc(d) and d >= -9007199254740991 and d <= 9007199254740991) {
            return e.enif_make_int64(env, @intFromFloat(d));
        }
        return e.enif_make_double(env, d);
    }

    // BigInt → integer (as string, let Elixir parse)
    if (qjs.JS_IsBigInt(val)) {
        const ptr = qjs.JS_ToCString(ctx, val);
        if (ptr != null) {
            defer qjs.JS_FreeCString(ctx, ptr);
            const s = std.mem.span(ptr);
            return make_binary_term(env, s);
        }
        return make_atom(env, "nil");
    }

    // string
    if (qjs.JS_IsString(val)) {
        var len: usize = 0;
        const ptr = qjs.JS_ToCStringLen(ctx, &len, val);
        if (ptr == null) return make_binary_term(env, "");
        defer qjs.JS_FreeCString(ctx, ptr);
        return make_binary_term(env, @as([*]const u8, @ptrCast(ptr))[0..len]);
    }

    // ArrayBuffer → raw binary
    if (qjs.JS_IsArrayBuffer(val)) {
        var buf_size: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, val);
        if (ptr == null) return make_binary_term(env, "");
        return make_binary_term(env, ptr[0..buf_size]);
    }

    // TypedArray (Uint8Array, etc.) → raw binary
    if (is_typed_array(ctx, val)) {
        var byte_offset: usize = 0;
        var byte_len: usize = 0;
        var bytes_per_element: usize = 0;
        const ab = qjs.JS_GetTypedArrayBuffer(ctx, val, &byte_offset, &byte_len, &bytes_per_element);
        if (!js.js_is_exception(ab)) {
            defer qjs.JS_FreeValue(ctx, ab);
            var buf_size: usize = 0;
            const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, ab);
            if (ptr != null) {
                return make_binary_term(env, ptr[byte_offset .. byte_offset + byte_len]);
            }
        }
        return make_binary_term(env, "");
    }

    // Array → list
    if (qjs.JS_IsArray(val)) {
        const len_val = qjs.JS_GetPropertyStr(ctx, val, "length");
        defer qjs.JS_FreeValue(ctx, len_val);

        var len: i64 = 0;
        _ = qjs.JS_ToInt64(ctx, &len, len_val);
        if (len < 0) len = 0;
        const ulen: usize = @intCast(len);

        // Build list in reverse using enif_make_list_cell
        var list = e.enif_make_list_from_array(env, null, 0);
        var i: usize = ulen;
        while (i > 0) {
            i -= 1;
            const elem = qjs.JS_GetPropertyUint32(ctx, val, @intCast(i));
            defer qjs.JS_FreeValue(ctx, elem);
            const term = convert_recursive(ctx, elem, env, depth + 1);
            list = e.enif_make_list_cell(env, term, list);
        }
        return list;
    }

    // Object → map
    if (qjs.JS_IsObject(val)) {
        return convert_object_to_map(ctx, val, env, depth);
    }

    return make_atom(env, "nil");
}

fn convert_object_to_map(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv, depth: u32) e.ErlNifTerm {
    var ptab: ?*qjs.JSPropertyEnum = null;
    var plen: u32 = 0;

    if (qjs.JS_GetOwnPropertyNames(ctx, &ptab, &plen, val, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY) != 0) {
        return make_empty_map(env);
    }

    if (plen == 0) {
        if (ptab) |p| qjs.js_free(ctx, p);
        return make_empty_map(env);
    }

    const tab_single = ptab orelse return make_empty_map(env);
    defer qjs.js_free(ctx, tab_single);
    const tab: [*]qjs.JSPropertyEnum = @ptrCast(tab_single);

    const keys = gpa.alloc(e.ErlNifTerm, plen) catch return make_empty_map(env);
    defer gpa.free(keys);
    const vals = gpa.alloc(e.ErlNifTerm, plen) catch return make_empty_map(env);
    defer gpa.free(vals);

    for (0..plen) |i| {
        const atom = tab[i].atom;

        const key_val = qjs.JS_AtomToString(ctx, atom);
        defer qjs.JS_FreeValue(ctx, key_val);
        var key_len: usize = 0;
        const key_ptr = qjs.JS_ToCStringLen(ctx, &key_len, key_val);
        if (key_ptr != null) {
            keys[i] = make_binary_term(env, @as([*]const u8, @ptrCast(key_ptr))[0..key_len]);
            qjs.JS_FreeCString(ctx, key_ptr);
        } else {
            keys[i] = make_binary_term(env, "");
        }

        const prop = qjs.JS_GetProperty(ctx, val, atom);
        defer qjs.JS_FreeValue(ctx, prop);
        vals[i] = convert_recursive(ctx, prop, env, depth + 1);
    }

    // Free atoms
    for (0..plen) |i| {
        qjs.JS_FreeAtom(ctx, tab[i].atom);
    }

    // SAFETY: immediately filled by enif_make_map_from_arrays
    var result: e.ErlNifTerm = undefined;
    if (e.enif_make_map_from_arrays(env, keys.ptr, vals.ptr, plen, &result) != 0) {
        return result;
    }
    return make_empty_map(env);
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

fn make_empty_map(env: ?*e.ErlNifEnv) e.ErlNifTerm {
    // SAFETY: immediately filled by enif_make_map_from_arrays
    var result: e.ErlNifTerm = undefined;
    _ = e.enif_make_map_from_arrays(env, null, null, 0, &result);
    return result;
}

fn make_atom(env: ?*e.ErlNifEnv, name: []const u8) e.ErlNifTerm {
    return e.enif_make_atom_len(env, name.ptr, name.len);
}

fn make_binary_term(env: ?*e.ErlNifEnv, data: []const u8) e.ErlNifTerm {
    // SAFETY: immediately filled by enif_inspect_binary or enif_alloc_binary
    var bin: e.ErlNifBinary = undefined;
    _ = e.enif_alloc_binary(data.len, &bin);
    if (data.len > 0) {
        @memcpy(bin.data[0..data.len], data);
    }
    return e.enif_make_binary(env, &bin);
}
