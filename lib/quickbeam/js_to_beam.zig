const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;

const DEFAULT_MAX_DEPTH: u32 = 32;
const DEFAULT_MAX_NODES: u32 = 10_000;

const Env = struct { env: ?*e.ErlNifEnv };

const VisitedSet = std.AutoHashMap(*anyopaque, void);

pub const ConvertLimits = struct {
    max_depth: u32 = DEFAULT_MAX_DEPTH,
    max_nodes: u32 = DEFAULT_MAX_NODES,
};

const ConvertState = struct {
    opts: Env,
    limits: ConvertLimits,
    visited: VisitedSet,
    node_count: u32 = 0,

    fn budgetExceeded(self: *ConvertState) bool {
        return self.node_count >= self.limits.max_nodes;
    }

    fn depthExceeded(self: *ConvertState, depth: u32) bool {
        return depth > self.limits.max_depth;
    }

    fn countNode(self: *ConvertState) void {
        self.node_count +|= 1;
    }
};

pub fn convert(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    return convert_with_limits(ctx, val, env, .{});
}

pub fn convert_with_limits(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv, limits: ConvertLimits) e.ErlNifTerm {
    var state = ConvertState{
        .opts = Env{ .env = env },
        .limits = limits,
        .visited = VisitedSet.init(gpa),
    };
    defer state.visited.deinit();
    return convert_recursive(ctx, val, &state, 0);
}

pub fn convert_error(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    return convert_error_with_limits(ctx, val, env, .{});
}

pub fn convert_error_with_limits(ctx: *qjs.JSContext, val: qjs.JSValue, env: ?*e.ErlNifEnv, limits: ConvertLimits) e.ErlNifTerm {
    if (!qjs.JS_IsObject(val)) return convert_with_limits(ctx, val, env, limits);

    const msg_val = qjs.JS_GetPropertyStr(ctx, val, "message");
    defer qjs.JS_FreeValue(ctx, msg_val);

    if (qjs.JS_IsUndefined(msg_val)) return convert_with_limits(ctx, val, env, limits);

    const name_val = qjs.JS_GetPropertyStr(ctx, val, "name");
    defer qjs.JS_FreeValue(ctx, name_val);
    const stack_val = qjs.JS_GetPropertyStr(ctx, val, "stack");
    defer qjs.JS_FreeValue(ctx, stack_val);

    const opts = Env{ .env = env };
    var state = ConvertState{
        .opts = opts,
        .limits = limits,
        .visited = VisitedSet.init(gpa),
    };
    defer state.visited.deinit();
    return beam.make(.{
        .message = beam.term{ .v = convert_recursive(ctx, msg_val, &state, 0) },
        .name = beam.term{ .v = convert_recursive(ctx, name_val, &state, 0) },
        .stack = beam.term{ .v = convert_recursive(ctx, stack_val, &state, 0) },
    }, opts).v;
}

fn convert_recursive(ctx: *qjs.JSContext, val: qjs.JSValue, state: *ConvertState, depth: u32) e.ErlNifTerm {
    if (state.depthExceeded(depth) or state.budgetExceeded()) return beam.make_into_atom("nil", state.opts).v;
    state.countNode();

    if (qjs.JS_IsUndefined(val) or qjs.JS_IsNull(val)) {
        return beam.make_into_atom("nil", state.opts).v;
    }

    if (qjs.JS_IsBool(val)) {
        const b = qjs.JS_ToBool(ctx, val);
        return if (b != 0) beam.make_into_atom("true", state.opts).v else beam.make_into_atom("false", state.opts).v;
    }

    if (qjs.JS_IsNumber(val)) {
        return convert_number(ctx, val, state.opts);
    }

    if (qjs.JS_IsBigInt(val)) {
        const ptr = qjs.JS_ToCString(ctx, val);
        if (ptr != null) {
            defer qjs.JS_FreeCString(ctx, ptr);
            return beam.make(std.mem.span(ptr), state.opts).v;
        }
        return beam.make_into_atom("nil", state.opts).v;
    }

    if (qjs.JS_IsSymbol(val)) {
        return convert_symbol(ctx, val, state.opts);
    }

    if (qjs.JS_IsString(val)) {
        var len: usize = 0;
        const ptr = qjs.JS_ToCStringLen(ctx, &len, val);
        if (ptr == null) return beam.make(@as([]const u8, ""), state.opts).v;
        defer qjs.JS_FreeCString(ctx, ptr);
        return beam.make(@as([*]const u8, @ptrCast(ptr))[0..len], state.opts).v;
    }

    if (qjs.JS_IsArrayBuffer(val)) {
        var buf_size: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, val);
        if (ptr == null) return beam.make(@as([]const u8, ""), state.opts).v;
        return beam.make(ptr[0..buf_size], state.opts).v;
    }

    if (is_typed_array(ctx, val)) {
        return convert_typed_array(ctx, val, state.opts);
    }

    if (qjs.JS_IsArray(val)) {
        return convert_array(ctx, val, state, depth);
    }

    if (qjs.JS_IsObject(val)) {
        return convert_object_to_map(ctx, val, state, depth);
    }

    return beam.make_into_atom("nil", state.opts).v;
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

fn convert_array(ctx: *qjs.JSContext, val: qjs.JSValue, state: *ConvertState, depth: u32) e.ErlNifTerm {
    const obj_ptr = obj_identity(val) orelse return beam.make_empty_list(state.opts).v;
    if (state.visited.contains(obj_ptr)) return beam.make_into_atom("nil", state.opts).v;
    state.visited.put(obj_ptr, {}) catch return beam.make_empty_list(state.opts).v;
    defer _ = state.visited.remove(obj_ptr);

    const len_val = qjs.JS_GetPropertyStr(ctx, val, "length");
    defer qjs.JS_FreeValue(ctx, len_val);

    var len: i64 = 0;
    _ = qjs.JS_ToInt64(ctx, &len, len_val);
    if (len < 0) len = 0;
    const ulen: usize = @intCast(len);

    var list = beam.make_empty_list(state.opts);
    var i: usize = ulen;
    while (i > 0) {
        i -= 1;
        const elem = qjs.JS_GetPropertyUint32(ctx, val, @intCast(i));
        defer qjs.JS_FreeValue(ctx, elem);
        const term = beam.term{ .v = convert_recursive(ctx, elem, state, depth + 1) };
        list = beam.make_list_cell(term, list, state.opts);
    }
    return list.v;
}

fn convert_object_to_map(ctx: *qjs.JSContext, val: qjs.JSValue, state: *ConvertState, depth: u32) e.ErlNifTerm {
    const type_val = qjs.JS_GetPropertyStr(ctx, val, "__beam_type__");
    if (!qjs.JS_IsUndefined(type_val)) {
        qjs.JS_FreeValue(ctx, type_val);
        const data_val = qjs.JS_GetPropertyStr(ctx, val, "__beam_data__");
        defer qjs.JS_FreeValue(ctx, data_val);
        if (!qjs.JS_IsUndefined(data_val)) {
            return decode_beam_term(ctx, data_val, state.opts);
        }
    } else {
        qjs.JS_FreeValue(ctx, type_val);
    }

    const obj_ptr = obj_identity(val) orelse return empty_map(state.opts);
    if (state.visited.contains(obj_ptr)) return beam.make_into_atom("nil", state.opts).v;
    state.visited.put(obj_ptr, {}) catch return empty_map(state.opts);
    defer _ = state.visited.remove(obj_ptr);

    var ptab: ?*qjs.JSPropertyEnum = null;
    var plen: u32 = 0;

    if (qjs.JS_GetOwnPropertyNames(ctx, &ptab, &plen, val, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY) != 0) {
        return empty_map(state.opts);
    }

    if (plen == 0) {
        if (ptab) |p| qjs.js_free(ctx, p);
        return empty_map(state.opts);
    }

    const tab_single = ptab orelse return empty_map(state.opts);
    defer qjs.js_free(ctx, tab_single);
    const tab: [*]qjs.JSPropertyEnum = @ptrCast(tab_single);

    const keys = gpa.alloc(e.ErlNifTerm, plen) catch return empty_map(state.opts);
    defer gpa.free(keys);
    const vals = gpa.alloc(e.ErlNifTerm, plen) catch return empty_map(state.opts);
    defer gpa.free(vals);

    for (0..plen) |i| {
        const atom = tab[i].atom;

        var key_len: usize = 0;
        const key_ptr = qjs.JS_AtomToCStringLen(ctx, &key_len, atom);
        if (key_ptr != null) {
            const src = @as([*]const u8, @ptrCast(key_ptr))[0..key_len];
            // SAFETY: enif_make_new_binary initializes bin_term before it is read.
            var bin_term: e.ErlNifTerm = undefined;
            const bin_ptr = e.enif_make_new_binary(state.opts.env, key_len, &bin_term);
            if (bin_ptr != null) {
                @memcpy(bin_ptr[0..key_len], src);
                keys[i] = bin_term;
            } else {
                keys[i] = beam.make(@as([]const u8, ""), state.opts).v;
            }
            qjs.JS_FreeCString(ctx, key_ptr);
        } else {
            keys[i] = beam.make(@as([]const u8, ""), state.opts).v;
        }

        const prop = qjs.JS_GetProperty(ctx, val, atom);
        defer qjs.JS_FreeValue(ctx, prop);
        vals[i] = convert_recursive(ctx, prop, state, depth + 1);
    }

    for (0..plen) |i| {
        qjs.JS_FreeAtom(ctx, tab[i].atom);
    }

    // SAFETY: enif_make_map_from_arrays initializes result on success before it is read.
    var result: e.ErlNifTerm = undefined;
    if (e.enif_make_map_from_arrays(state.opts.env, keys.ptr, vals.ptr, plen, &result) != 0) {
        return result;
    }
    return empty_map(state.opts);
}

fn obj_identity(val: qjs.JSValue) ?*anyopaque {
    if (val.tag != qjs.JS_TAG_OBJECT) return null;
    return val.u.ptr;
}

fn empty_map(opts: Env) e.ErlNifTerm {
    // SAFETY: enif_make_map_from_arrays initializes result before it is returned.
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

fn decode_beam_term(ctx: *qjs.JSContext, data_val: qjs.JSValue, opts: Env) e.ErlNifTerm {
    var byte_offset: usize = 0;
    var byte_len: usize = 0;
    var bytes_per_element: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(ctx, data_val, &byte_offset, &byte_len, &bytes_per_element);
    if (js.js_is_exception(ab)) {
        const exc = qjs.JS_GetException(ctx);
        qjs.JS_FreeValue(ctx, exc);
        return beam.make_into_atom("nil", opts).v;
    }
    defer qjs.JS_FreeValue(ctx, ab);

    var buf_size: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, ab);
    if (ptr == null) return beam.make_into_atom("nil", opts).v;

    // SAFETY: enif_binary_to_term initializes result on success before it is read.
    var result: e.ErlNifTerm = undefined;
    if (e.enif_binary_to_term(opts.env, ptr + byte_offset, byte_len, &result, 0) == 0) {
        return beam.make_into_atom("nil", opts).v;
    }
    return result;
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
