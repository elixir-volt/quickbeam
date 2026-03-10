const types = @import("types.zig");
const worker = @import("worker.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const console_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "log", qjs.JS_NewCFunction(ctx, &console_log, "log", 0));
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "info", qjs.JS_NewCFunction(ctx, &console_log, "info", 0));
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "warn", qjs.JS_NewCFunction(ctx, &console_warn, "warn", 0));
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "error", qjs.JS_NewCFunction(ctx, &console_error, "error", 0));
    _ = qjs.JS_SetPropertyStr(ctx, global, "console", console_obj);
}

fn console_log(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return send_console_message(ctx, "log", argc, argv);
}

fn console_warn(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return send_console_message(ctx, "warning", argc, argv);
}

fn console_error(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return send_console_message(ctx, "error", argc, argv);
}

fn send_console_message(ctx: ?*qjs.JSContext, level: []const u8, argc: c_int, argv: [*c]qjs.JSValue) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    var list = std.ArrayList(u8){};
    defer list.deinit(types.gpa);

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) list.append(types.gpa, ' ') catch break;
        const ptr = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (ptr != null) {
            list.appendSlice(types.gpa, std.mem.span(ptr)) catch break;
            qjs.JS_FreeCString(ctx, ptr);
        }
    }

    const send_env = beam.alloc_env();
    const opts = .{ .env = send_env };
    const msg = beam.make(.{ .console, level, list.items }, opts);
    var pid = self.owner_pid;
    _ = e.enif_send(null, &pid, send_env, msg.v);
    beam.free_env(send_env);

    return js.js_undefined();
}
