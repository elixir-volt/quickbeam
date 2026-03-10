const types = @import("types.zig");
const qjs = types.qjs;

const beam_call = @import("beam_call.zig");
const timers = @import("timers.zig");
const console = @import("console.zig");
const text_encoding = @import("text_encoding.zig");
const web_apis = @import("web_apis.zig");
const dom = @import("dom.zig");

pub fn install_all(ctx: *qjs.JSContext) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    beam_call.install(ctx, global);
    timers.install(ctx, global);
    console.install(ctx, global);
    text_encoding.install(ctx, global);
    web_apis.install(ctx, global);
    dom.install(ctx, global);
}
