const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const e = types.e;
const qjs = types.qjs;

const MAX_DEPTH = 32;

pub fn convert(ctx: *qjs.JSContext, env: ?*e.ErlNifEnv, term: e.ErlNifTerm) qjs.JSValue {
    return convert_recursive(ctx, env, term, 0);
}

fn convert_recursive(ctx: *qjs.JSContext, env: ?*e.ErlNifEnv, term: e.ErlNifTerm, depth: u32) qjs.JSValue {
    if (depth > MAX_DEPTH) return js.js_null();

    // Atom: nil, true, false, or atom string
    var atom_buf: [256]u8 = undefined;
    const atom_len = e.enif_get_atom(env, term, &atom_buf, atom_buf.len, e.ERL_NIF_LATIN1);
    if (atom_len > 0) {
        const name = atom_buf[0..@intCast(atom_len - 1)]; // exclude null terminator
        if (std.mem.eql(u8, name, "nil") or std.mem.eql(u8, name, "undefined")) return js.js_null();
        if (std.mem.eql(u8, name, "true")) return js.js_true();
        if (std.mem.eql(u8, name, "false")) return js.js_false();
        return qjs.JS_NewStringLen(ctx, name.ptr, name.len);
    }

    // Integer
    var i64_val: i64 = 0;
    if (e.enif_get_int64(env, term, &i64_val) != 0) {
        if (i64_val >= std.math.minInt(i32) and i64_val <= std.math.maxInt(i32)) {
            return qjs.JS_NewInt32(ctx, @intCast(i64_val));
        }
        return qjs.JS_NewInt64(ctx, i64_val);
    }

    // Float
    var f64_val: f64 = 0;
    if (e.enif_get_double(env, term, &f64_val) != 0) {
        return qjs.JS_NewFloat64(ctx, f64_val);
    }

    // Binary → string (UTF-8 text)
    // SAFETY: immediately filled by enif_inspect_binary or enif_alloc_binary
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_inspect_binary(env, term, &bin) != 0) {
        return qjs.JS_NewStringLen(ctx, bin.data, bin.size);
    }

    // List → Array
    // List check: try to get list length
    var list_len: c_uint = 0;
    if (e.enif_get_list_length(env, term, &list_len) != 0) {
        return convert_list(ctx, env, term, depth);
    }

    // Map → Object
    if (e.enif_is_map(env, term) != 0) {
        return convert_map(ctx, env, term, depth);
    }

    // Tuple
    var tuple_arity: c_int = 0;
    // SAFETY: immediately filled by enif_get_tuple
    var tuple_elems: [*c]const e.ErlNifTerm = undefined;
    if (e.enif_get_tuple(env, term, &tuple_arity, &tuple_elems) != 0) {
        // {:bytes, binary} → Uint8Array
        if (tuple_arity == 2) {
            var tag_buf: [16]u8 = undefined;
            const tag_len = e.enif_get_atom(env, tuple_elems[0], &tag_buf, tag_buf.len, e.ERL_NIF_LATIN1);
            if (tag_len > 0 and std.mem.eql(u8, tag_buf[0..@intCast(tag_len - 1)], "bytes")) {
                // SAFETY: immediately filled by enif_inspect_binary
                var bbin: e.ErlNifBinary = undefined;
                if (e.enif_inspect_binary(env, tuple_elems[1], &bbin) != 0) {
                    return make_uint8array(ctx, bbin.data, bbin.size);
                }
            }
        }
        // Generic tuple → Array
        const arr = qjs.JS_NewArray(ctx);
        for (0..@intCast(tuple_arity)) |idx| {
            const elem = convert_recursive(ctx, env, tuple_elems[idx], depth + 1);
            _ = qjs.JS_SetPropertyUint32(ctx, arr, @intCast(idx), elem);
        }
        return arr;
    }

    return js.js_null();
}

fn make_uint8array(ctx: *qjs.JSContext, data: [*c]u8, size: usize) qjs.JSValue {
    const ab = qjs.JS_NewArrayBufferCopy(ctx, data, size);
    if (js.js_is_exception(ab)) return js.js_exception();

    const g = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, g);
    const ctor = qjs.JS_GetPropertyStr(ctx, g, "Uint8Array");
    defer qjs.JS_FreeValue(ctx, ctor);

    var args = [_]qjs.JSValue{ab};
    const result = qjs.JS_CallConstructor(ctx, ctor, 1, &args);
    qjs.JS_FreeValue(ctx, ab);
    return result;
}

fn convert_list(ctx: *qjs.JSContext, env: ?*e.ErlNifEnv, term: e.ErlNifTerm, depth: u32) qjs.JSValue {
    // Check if it's an iolist-like structure (list of binaries/integers)
    // For now, convert as a regular JS array
    const arr = qjs.JS_NewArray(ctx);
    var current = term;
    var idx: u32 = 0;

    while (true) {
        // SAFETY: head and tail immediately filled by enif_get_list_cell
        var head: e.ErlNifTerm = undefined;
        // SAFETY: see above
        var tail: e.ErlNifTerm = undefined;
        if (e.enif_get_list_cell(env, current, &head, &tail) == 0) break;

        const elem = convert_recursive(ctx, env, head, depth + 1);
        _ = qjs.JS_SetPropertyUint32(ctx, arr, idx, elem);
        idx += 1;
        current = tail;
    }

    return arr;
}

fn convert_map(ctx: *qjs.JSContext, env: ?*e.ErlNifEnv, term: e.ErlNifTerm, depth: u32) qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);

    // SAFETY: immediately filled by enif_map_iterator_create
    var iter: e.ErlNifMapIterator = undefined;
    if (e.enif_map_iterator_create(env, term, &iter, e.ERL_NIF_MAP_ITERATOR_FIRST) == 0) {
        return obj;
    }
    defer e.enif_map_iterator_destroy(env, &iter);

    // SAFETY: key and val immediately filled by enif_map_iterator_get_pair
    var key: e.ErlNifTerm = undefined;
    // SAFETY: see above
    var val: e.ErlNifTerm = undefined;

    while (e.enif_map_iterator_get_pair(env, &iter, &key, &val) != 0) {
        // Keys must be strings (binaries) or atoms
        var key_str: [256]u8 = undefined;
        var key_len: usize = 0;

        // SAFETY: immediately filled by enif_inspect_binary or enif_alloc_binary
        var bin: e.ErlNifBinary = undefined;
        if (e.enif_inspect_binary(env, key, &bin) != 0) {
            if (bin.size > 0) {
                @memcpy(key_str[0..bin.size], bin.data[0..bin.size]);
            }
            key_len = bin.size;
        } else {
            const alen = e.enif_get_atom(env, key, &key_str, key_str.len, e.ERL_NIF_LATIN1);
            if (alen > 0) {
                key_len = @intCast(alen - 1);
            }
        }

        if (key_len > 0 and key_len < key_str.len) {
            key_str[key_len] = 0;
            const js_val = convert_recursive(ctx, env, val, depth + 1);
            _ = qjs.JS_SetPropertyStr(ctx, obj, @ptrCast(key_str[0..key_len :0].ptr), js_val);
        }

        _ = e.enif_map_iterator_next(env, &iter);
    }

    return obj;
}
