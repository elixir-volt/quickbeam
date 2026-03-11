const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;

pub const AtomCache = struct {
    js_nan: qjs.JSValue = js.JS_UNDEFINED,
    js_infinity: qjs.JSValue = js.JS_UNDEFINED,
    js_neg_infinity: qjs.JSValue = js.JS_UNDEFINED,
    js_ok: qjs.JSValue = js.JS_UNDEFINED,
    js_error: qjs.JSValue = js.JS_UNDEFINED,
    js_bytes: qjs.JSValue = js.JS_UNDEFINED,
    js_symbol: qjs.JSValue = js.JS_UNDEFINED,

    pub fn init(ctx: *qjs.JSContext) AtomCache {
        return .{
            .js_nan = qjs.JS_NewString(ctx, "NaN"),
            .js_infinity = qjs.JS_NewString(ctx, "Infinity"),
            .js_neg_infinity = qjs.JS_NewString(ctx, "-Infinity"),
            .js_ok = qjs.JS_NewString(ctx, "ok"),
            .js_error = qjs.JS_NewString(ctx, "error"),
            .js_bytes = qjs.JS_NewString(ctx, "bytes"),
            .js_symbol = qjs.JS_NewString(ctx, "symbol"),
        };
    }

    pub fn deinit(self: *AtomCache, ctx: *qjs.JSContext) void {
        const fields = [_]*const qjs.JSValue{
            &self.js_nan,
            &self.js_infinity,
            &self.js_neg_infinity,
            &self.js_ok,
            &self.js_error,
            &self.js_bytes,
            &self.js_symbol,
        };
        for (fields) |f| {
            qjs.JS_FreeValue(ctx, f.*);
        }
        self.* = .{};
    }

    /// Returns a JS value for a known BEAM atom name, or null for unknown atoms.
    /// Caller owns the returned value (already duped for refcounted strings).
    pub fn atomToJS(self: *const AtomCache, ctx: *qjs.JSContext, name: []const u8) ?qjs.JSValue {
        if (std.mem.eql(u8, name, "nil") or std.mem.eql(u8, name, "undefined")) return js.js_null();
        if (std.mem.eql(u8, name, "true")) return js.js_true();
        if (std.mem.eql(u8, name, "false")) return js.js_false();
        if (std.mem.eql(u8, name, "NaN")) return qjs.JS_DupValue(ctx, self.js_nan);
        if (std.mem.eql(u8, name, "Infinity")) return qjs.JS_DupValue(ctx, self.js_infinity);
        if (std.mem.eql(u8, name, "-Infinity")) return qjs.JS_DupValue(ctx, self.js_neg_infinity);
        if (std.mem.eql(u8, name, "ok")) return qjs.JS_DupValue(ctx, self.js_ok);
        if (std.mem.eql(u8, name, "error")) return qjs.JS_DupValue(ctx, self.js_error);
        if (std.mem.eql(u8, name, "bytes")) return qjs.JS_DupValue(ctx, self.js_bytes);
        if (std.mem.eql(u8, name, "symbol")) return qjs.JS_DupValue(ctx, self.js_symbol);
        return null;
    }
};
