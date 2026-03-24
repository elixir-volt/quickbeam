const c = @import("common.zig");

const qjs = c.qjs;
const gpa = c.gpa;
const js = c.js_helpers;
const Status = c.Status;
pub const napi_status = c.napi_status;
pub const napi_env = c.napi_env;
pub const napi_value = c.napi_value;
pub const napi_ref = c.napi_ref;
pub const napi_finalize = c.napi_finalize;
pub const NapiEnv = c.NapiEnv;
pub const NapiReference = c.NapiReference;

pub const WrapData = struct {
    env: *NapiEnv,
    native_object: ?*anyopaque,
    finalize_cb: napi_finalize,
    finalize_hint: ?*anyopaque,
    removed: bool = false,
};

pub const WrappedPointerHolder = struct {
    wrap: *WrapData,
};

pub var wrap_class_id: qjs.JSClassID = 0;

pub var wrap_class_def = qjs.JSClassDef{
    .class_name = "NapiWrap",
    .finalizer = &wrapFinalizer,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

pub fn wrapFinalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const holder = @as(?*WrappedPointerHolder, @ptrCast(@alignCast(qjs.JS_GetOpaque(val, wrap_class_id))));
    if (holder) |h| {
        const wrap = h.wrap;
        if (!wrap.removed) {
            if (wrap.finalize_cb) |cb| {
                cb(wrap.env, wrap.native_object, wrap.finalize_hint);
            }
        }
        gpa.destroy(h);
        gpa.destroy(wrap);
    }
}

pub fn wrapAtom(env: *NapiEnv) qjs.JSAtom {
    return qjs.JS_NewAtom(env.ctx, "__napi_wrap");
}

pub fn createObjectWrapper(env: *NapiEnv, native_object: ?*anyopaque, finalize_cb: napi_finalize, finalize_hint: ?*anyopaque) !qjs.JSValue {
    const wrap = try gpa.create(WrapData);
    wrap.* = .{
        .env = env,
        .native_object = native_object,
        .finalize_cb = finalize_cb,
        .finalize_hint = finalize_hint,
    };

    const holder = try gpa.create(WrappedPointerHolder);
    holder.* = .{ .wrap = wrap };

    const wrapper = qjs.JS_NewObjectClass(env.ctx, @intCast(wrap_class_id));
    if (js.js_is_exception(wrapper)) {
        gpa.destroy(holder);
        gpa.destroy(wrap);
        return error.WrapClassCreateFailed;
    }

    _ = qjs.JS_SetOpaque(wrapper, holder);
    return wrapper;
}

pub fn getWrapData(env: *NapiEnv, obj: qjs.JSValue) ?*WrapData {
    const key = wrapAtom(env);
    defer qjs.JS_FreeAtom(env.ctx, key);

    const val = qjs.JS_GetProperty(env.ctx, obj, key);
    defer qjs.JS_FreeValue(env.ctx, val);

    if (!qjs.JS_IsObject(val)) return null;
    const holder = @as(?*WrappedPointerHolder, @ptrCast(@alignCast(qjs.JS_GetOpaque(val, wrap_class_id))));
    if (holder) |h| return h.wrap;
    return null;
}

pub export fn napi_wrap(env_: napi_env, js_object: napi_value, native_object: ?*anyopaque, finalize_cb: napi_finalize, finalize_hint: ?*anyopaque, result: ?*napi_ref) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = c.toVal(js_object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const key = wrapAtom(env);
    defer qjs.JS_FreeAtom(env.ctx, key);

    const wrapper = createObjectWrapper(env, native_object, finalize_cb, finalize_hint) catch return env.genericFailure();
    if (qjs.JS_DefinePropertyValue(env.ctx, obj, key, wrapper, qjs.JS_PROP_CONFIGURABLE) < 0) {
        qjs.JS_FreeValue(env.ctx, wrapper);
        return env.setLastError(.pending_exception);
    }

    if (result) |r| {
        const ref_obj = gpa.create(NapiReference) catch return env.genericFailure();
        ref_obj.* = .{
            .value = qjs.JS_DupValue(env.ctx, obj),
            .ref_count = 1,
            .ctx = env.ctx,
        };
        env.refs.append(gpa, ref_obj) catch {};
        r.* = ref_obj;
    }
    return env.ok();
}

pub export fn napi_unwrap(env_: napi_env, js_object: napi_value, result: ?*?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const r = result orelse return env.invalidArg();
    const obj = c.toVal(js_object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const wrap = getWrapData(env, obj) orelse return env.invalidArg();
    r.* = wrap.native_object;
    return env.ok();
}

pub export fn napi_remove_wrap(env_: napi_env, js_object: napi_value, result: ?*?*anyopaque) callconv(.c) napi_status {
    const env = env_ orelse return @intFromEnum(Status.invalid_arg);
    const obj = c.toVal(js_object);
    if (!qjs.JS_IsObject(obj)) return env.setLastError(.object_expected);

    const wrap = getWrapData(env, obj);
    if (result) |r| r.* = if (wrap) |w| w.native_object else null;
    if (wrap) |w| w.removed = true;

    const key = wrapAtom(env);
    defer qjs.JS_FreeAtom(env.ctx, key);
    _ = qjs.JS_DeleteProperty(env.ctx, obj, key, 0);
    return env.ok();
}

pub export fn napi_add_finalizer(env_: napi_env, js_object: napi_value, native_object: ?*anyopaque, cb: napi_finalize, hint: ?*anyopaque, result: ?*napi_ref) callconv(.c) napi_status {
    return napi_wrap(env_, js_object, native_object, cb, hint, result);
}
