const types = @import("types.zig");
const worker = @import("worker.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const set_timeout = qjs.JS_NewCFunction(ctx, &set_timeout_impl, "setTimeout", 2);
    _ = qjs.JS_SetPropertyStr(ctx, global, "setTimeout", set_timeout);

    const set_interval = qjs.JS_NewCFunction(ctx, &set_interval_impl, "setInterval", 2);
    _ = qjs.JS_SetPropertyStr(ctx, global, "setInterval", set_interval);

    const clear_fn = qjs.JS_NewCFunction(ctx, &clear_timer_impl, "clearTimeout", 1);
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearTimeout", qjs.JS_DupValue(ctx, clear_fn));
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearInterval", clear_fn);
}

fn set_timeout_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return set_timer_common(ctx, argc, argv, false);
}

fn set_interval_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return set_timer_common(ctx, argc, argv, true);
}

fn set_timer_common(ctx: ?*qjs.JSContext, argc: c_int, argv: [*c]qjs.JSValue, is_interval: bool) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "setTimeout/setInterval requires a callback");

    const callback = qjs.JS_DupValue(ctx, argv[0]);

    var delay_ms: f64 = 0;
    if (argc >= 2) {
        _ = qjs.JS_ToFloat64(ctx, &delay_ms, argv[1]);
    }
    if (delay_ms < 0) delay_ms = 0;
    if (is_interval and delay_ms < 1) delay_ms = 1;

    const delay_ns: u64 = @intFromFloat(delay_ms * 1_000_000);

    const id = self.next_timer_id;
    self.next_timer_id += 1;

    self.timers.put(id, .{
        .callback = callback,
        .deadline = std.time.nanoTimestamp() + @as(i128, delay_ns),
        .interval_ns = if (is_interval) delay_ns else null,
    }) catch {
        qjs.JS_FreeValue(ctx, callback);
        return qjs.JS_ThrowOutOfMemory(ctx);
    };

    self.rd.cond.signal();

    return qjs.JS_NewFloat64(ctx, @floatFromInt(id));
}

fn clear_timer_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1) return js.js_undefined();

    var id_f: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx, &id_f, argv[0]);
    const id: u64 = @intFromFloat(id_f);

    if (self.timers.fetchRemove(id)) |kv| {
        qjs.JS_FreeValue(ctx, kv.value.callback);
    }

    return js.js_undefined();
}
