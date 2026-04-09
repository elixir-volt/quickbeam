const types = @import("types.zig");
const js = @import("js_helpers.zig");
const beam_to_js = @import("beam_to_js.zig");
const beam_helpers = @import("beam_helpers.zig");
const inspect_binary = beam_helpers.inspect_binary;
const existing_atom = beam_helpers.existing_atom;
const make_new_binary = beam_helpers.make_new_binary;
const map_iterator_create = beam_helpers.map_iterator_create;
const map_iterator_get_pair = beam_helpers.map_iterator_get_pair;
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;

pub var class_id: qjs.JSClassID = 0;

const BeamProxyData = struct {
    env: *e.ErlNifEnv,
    term: e.ErlNifTerm,
    overrides: qjs.JSValue,
};

fn lookupKey(data: *BeamProxyData, key: []const u8, result: *e.ErlNifTerm) bool {
    // Try binary key (Elixir string-keyed maps).
    // Use a scratch env so we don't mutate the proxy's env heap.
    const scratch = beam.alloc_env() orelse return false;
    defer beam.free_env(scratch);
    if (make_new_binary(scratch, key.len)) |bin| {
        const bin_ptr = bin.data;
        const bin_term = bin.term;
        if (key.len > 0) {
            @memcpy(bin_ptr[0..key.len], key);
        }
        const bin_in_env = e.enif_make_copy(data.env, bin_term);
        if (e.enif_get_map_value(data.env, data.term, bin_in_env, result) != 0) {
            return true;
        }
    }

    // Try atom key
    if (existing_atom(data.env, key)) |atom_key| {
        if (e.enif_get_map_value(data.env, data.term, atom_key, result) != 0) {
            return true;
        }
    }

    return false;
}

fn get_own_property(ctx: ?*qjs.JSContext, desc: ?*qjs.JSPropertyDescriptor, obj: qjs.JSValue, prop: qjs.JSAtom) callconv(.c) c_int {
    const data = @as(?*BeamProxyData, @ptrCast(@alignCast(qjs.JS_GetOpaque(obj, class_id)))) orelse return 0;

    // Check JS-side overrides first (properties set after proxy creation)
    if (qjs.JS_IsObject(data.overrides)) {
        const override = qjs.JS_GetProperty(ctx, data.overrides, prop);
        if (!qjs.JS_IsUndefined(override)) {
            if (desc) |d| {
                d.flags = qjs.JS_PROP_C_W_E;
                d.value = override;
                d.getter = js.JS_UNDEFINED;
                d.setter = js.JS_UNDEFINED;
            } else {
                qjs.JS_FreeValue(ctx, override);
            }
            return 1;
        }
        qjs.JS_FreeValue(ctx, override);
    }

    var len: usize = 0;
    const key_ptr = qjs.JS_AtomToCStringLen(ctx, &len, prop);
    if (key_ptr == null) return 0;
    defer qjs.JS_FreeCString(ctx, key_ptr);

    var result = std.mem.zeroes(e.ErlNifTerm);
    if (!lookupKey(data, key_ptr[0..len], &result)) return 0;

    if (desc) |d| {
        d.flags = qjs.JS_PROP_C_W_E;
        d.value = convertValue(ctx.?, data.env, result);
        d.getter = js.JS_UNDEFINED;
        d.setter = js.JS_UNDEFINED;
    }
    return 1;
}

fn get_own_property_names(ctx: ?*qjs.JSContext, ptab: [*c][*c]qjs.JSPropertyEnum, plen: [*c]u32, obj: qjs.JSValue) callconv(.c) c_int {
    const data = @as(?*BeamProxyData, @ptrCast(@alignCast(qjs.JS_GetOpaque(obj, class_id)))) orelse return -1;

    var map_size: usize = 0;
    if (e.enif_get_map_size(data.env, data.term, &map_size) == 0) return -1;

    // Count override keys (new keys not in the BEAM map)
    var override_count: u32 = 0;
    var override_ptab: ?*qjs.JSPropertyEnum = null;
    var override_plen: u32 = 0;
    if (qjs.JS_IsObject(data.overrides)) {
        _ = qjs.JS_GetOwnPropertyNames(ctx, &override_ptab, &override_plen, data.overrides, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY);
        override_count = override_plen;
    }
    defer if (override_ptab) |op| qjs.JS_FreePropertyEnum(ctx, op, override_plen);

    const total = map_size + override_count;
    const byte_size = total * @sizeOf(qjs.JSPropertyEnum);
    const raw = qjs.js_malloc(ctx, byte_size) orelse return -1;
    const tab: [*]qjs.JSPropertyEnum = @ptrCast(@alignCast(raw));

    var iter = map_iterator_create(data.env, data.term, e.ERL_NIF_MAP_ITERATOR_FIRST) orelse {
        qjs.js_free(ctx, raw);
        return -1;
    };
    defer e.enif_map_iterator_destroy(data.env, &iter);

    var idx: u32 = 0;

    while (map_iterator_get_pair(data.env, &iter)) |pair| : ({
        _ = e.enif_map_iterator_next(data.env, &iter);
    }) {
        var key_str: [256]u8 = undefined;
        var key_len: usize = 0;

        if (inspect_binary(data.env, pair.key)) |bin| {
            const copy_len = @min(bin.size, key_str.len);
            if (copy_len > 0) {
                @memcpy(key_str[0..copy_len], bin.data[0..copy_len]);
            }
            key_len = copy_len;
        } else {
            const alen = e.enif_get_atom(data.env, pair.key, &key_str, key_str.len, e.ERL_NIF_LATIN1);
            if (alen > 0) {
                key_len = @intCast(alen - 1);
            }
        }

        if (key_len > 0 and idx < total) {
            tab[idx] = .{
                .is_enumerable = true,
                .atom = qjs.JS_NewAtomLen(ctx, &key_str, key_len),
            };
            idx += 1;
        }
    }

    // Add override-only keys (keys not present in BEAM map)
    if (override_ptab) |op| {
        const otab: [*]qjs.JSPropertyEnum = @ptrCast(op);
        for (0..override_plen) |i| {
            var olen: usize = 0;
            const okey = qjs.JS_AtomToCStringLen(ctx, &olen, otab[i].atom);
            if (okey != null) {
                defer qjs.JS_FreeCString(ctx, okey);
                var dummy = std.mem.zeroes(e.ErlNifTerm);
                if (!lookupKey(data, okey[0..olen], &dummy)) {
                    if (idx < total) {
                        tab[idx] = .{
                            .is_enumerable = true,
                            .atom = qjs.JS_DupAtom(ctx, otab[i].atom),
                        };
                        idx += 1;
                    }
                }
            }
        }
    }

    ptab.* = tab;
    plen.* = idx;
    return 0;
}

fn define_own_property(ctx: ?*qjs.JSContext, obj: qjs.JSValue, prop: qjs.JSAtom, val: qjs.JSValue, getter: qjs.JSValue, setter: qjs.JSValue, flags: c_int) callconv(.c) c_int {
    _ = getter;
    _ = setter;
    _ = flags;
    const data = @as(?*BeamProxyData, @ptrCast(@alignCast(qjs.JS_GetOpaque(obj, class_id)))) orelse return -1;
    ensureOverrides(ctx, data);
    _ = qjs.JS_SetProperty(ctx, data.overrides, prop, qjs.JS_DupValue(ctx, val));
    return 1;
}

fn has_property(ctx: ?*qjs.JSContext, obj: qjs.JSValue, atom: qjs.JSAtom) callconv(.c) c_int {
    const data = @as(?*BeamProxyData, @ptrCast(@alignCast(qjs.JS_GetOpaque(obj, class_id)))) orelse return 0;

    // Check overrides first
    if (qjs.JS_IsObject(data.overrides)) {
        const override = qjs.JS_GetProperty(ctx, data.overrides, atom);
        if (!qjs.JS_IsUndefined(override)) {
            qjs.JS_FreeValue(ctx, override);
            return 1;
        }
        qjs.JS_FreeValue(ctx, override);
    }

    var len: usize = 0;
    const key_ptr = qjs.JS_AtomToCStringLen(ctx, &len, atom);
    if (key_ptr == null) return 0;
    defer qjs.JS_FreeCString(ctx, key_ptr);

    var result = std.mem.zeroes(e.ErlNifTerm);
    return if (lookupKey(data, key_ptr[0..len], &result)) 1 else 0;
}

fn set_property(ctx: ?*qjs.JSContext, obj: qjs.JSValue, atom: qjs.JSAtom, value: qjs.JSValue, receiver: qjs.JSValue, flags: c_int) callconv(.c) c_int {
    _ = receiver;
    _ = flags;
    const data = @as(?*BeamProxyData, @ptrCast(@alignCast(qjs.JS_GetOpaque(obj, class_id)))) orelse return -1;
    ensureOverrides(ctx, data);
    _ = qjs.JS_SetProperty(ctx, data.overrides, atom, qjs.JS_DupValue(ctx, value));
    return 1;
}

fn ensureOverrides(ctx: ?*qjs.JSContext, data: *BeamProxyData) void {
    if (!qjs.JS_IsObject(data.overrides)) {
        data.overrides = qjs.JS_NewObject(ctx);
    }
}

fn convertValue(ctx: *qjs.JSContext, env: *e.ErlNifEnv, term: e.ErlNifTerm) qjs.JSValue {
    if (e.enif_is_map(env, term) != 0) {
        return create(ctx, env, term);
    }
    return beam_to_js.convert(ctx, env, term);
}

fn finalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const data = @as(?*BeamProxyData, @ptrCast(@alignCast(qjs.JS_GetOpaque(val, class_id)))) orelse return;
    if (qjs.JS_IsObject(data.overrides)) {
        qjs.JS_FreeValueRT(rt, data.overrides);
    }
    beam.free_env(data.env);
    qjs.js_free_rt(rt, data);
}

fn gc_mark(rt: ?*qjs.JSRuntime, val: qjs.JSValue, mark_func: ?*const qjs.JS_MarkFunc) callconv(.c) void {
    const data = @as(?*BeamProxyData, @ptrCast(@alignCast(qjs.JS_GetOpaque(val, class_id)))) orelse return;
    if (qjs.JS_IsObject(data.overrides)) {
        qjs.JS_MarkValue(rt, data.overrides, mark_func);
    }
}

var exotic = qjs.JSClassExoticMethods{
    .get_own_property = &get_own_property,
    .get_own_property_names = &get_own_property_names,
    .delete_property = null,
    .define_own_property = &define_own_property,
    .has_property = &has_property,
    .get_property = null,
    .set_property = &set_property,
};

var class_def = qjs.JSClassDef{
    .class_name = "BeamMapProxy",
    .finalizer = &finalizer,
    .gc_mark = &gc_mark,
    .call = null,
    .exotic = &exotic,
};

pub fn initRuntime(rt: *qjs.JSRuntime) void {
    // class_id allocated under shared types.class_ids_mutex in worker.zig
    _ = qjs.JS_NewClass(rt, class_id, &class_def);
}

pub fn initContext(ctx: *qjs.JSContext) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const obj_ctor = qjs.JS_GetPropertyStr(ctx, global, "Object");
    defer qjs.JS_FreeValue(ctx, obj_ctor);
    const obj_proto = qjs.JS_GetPropertyStr(ctx, obj_ctor, "prototype");
    qjs.JS_SetClassProto(ctx, class_id, obj_proto);
}

pub fn create(ctx: *qjs.JSContext, _: ?*e.ErlNifEnv, term: e.ErlNifTerm) qjs.JSValue {
    const raw = qjs.js_mallocz(ctx, @sizeOf(BeamProxyData)) orelse return js.js_null();
    const data: *BeamProxyData = @ptrCast(@alignCast(raw));
    const new_env = beam.alloc_env() orelse {
        qjs.js_free(ctx, raw);
        return js.js_null();
    };
    data.env = new_env;
    data.term = e.enif_make_copy(new_env, term);
    data.overrides = js.JS_UNDEFINED;
    const obj = qjs.JS_NewObjectClass(ctx, @intCast(class_id));
    if (js.js_is_exception(obj)) {
        beam.free_env(new_env);
        qjs.js_free(ctx, raw);
        return js.js_exception();
    }
    _ = qjs.JS_SetOpaque(obj, data);
    return obj;
}

pub fn isProxy(val: qjs.JSValue) bool {
    return class_id != 0 and qjs.JS_GetClassID(val) == class_id;
}
