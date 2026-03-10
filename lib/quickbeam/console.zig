const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const console = qjs.JS_NewObject(ctx);
    const log_fn = qjs.JS_NewCFunction(ctx, &console_log_impl, "log", 0);
    _ = qjs.JS_SetPropertyStr(ctx, console, "log", qjs.JS_DupValue(ctx, log_fn));
    _ = qjs.JS_SetPropertyStr(ctx, console, "warn", qjs.JS_DupValue(ctx, log_fn));
    _ = qjs.JS_SetPropertyStr(ctx, console, "error", log_fn);
    _ = qjs.JS_SetPropertyStr(ctx, global, "console", console);
}

fn console_log_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) std.debug.print(" ", .{});
        const ptr = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (ptr != null) {
            std.debug.print("{s}", .{std.mem.span(ptr)});
            qjs.JS_FreeCString(ctx, ptr);
        }
    }
    std.debug.print("\n", .{});
    return js.js_undefined();
}
