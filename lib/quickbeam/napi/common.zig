const types = @import("../types.zig");
const js = @import("../js_helpers.zig");
const nt = @import("../napi_types.zig");

pub const std = types.std;
pub const qjs = types.qjs;
pub const gpa = types.gpa;
pub const Status = nt.Status;
pub const napi_status = nt.napi_status;
pub const napi_env = nt.napi_env;
pub const NapiEnv = nt.NapiEnv;
pub const napi_value = nt.napi_value;
pub const napi_ref = nt.napi_ref;
pub const napi_callback = nt.napi_callback;
pub const napi_callback_info = nt.napi_callback_info;
pub const napi_finalize = nt.napi_finalize;
pub const napi_handle_scope = nt.napi_handle_scope;
pub const napi_escapable_handle_scope = nt.napi_escapable_handle_scope;
pub const napi_deferred = nt.napi_deferred;
pub const napi_property_descriptor = nt.napi_property_descriptor;
pub const napi_valuetype = nt.napi_valuetype;
pub const napi_typedarray_type = nt.napi_typedarray_type;
pub const HandleScope = nt.HandleScope;
pub const NapiReference = nt.NapiReference;
pub const Deferred = nt.Deferred;
pub const CallbackInfo = nt.CallbackInfo;
pub const FunctionCallbackData = nt.FunctionCallbackData;
pub const ExternalData = nt.ExternalData;
pub const AsyncWork = nt.AsyncWork;
pub const napi_async_work = nt.napi_async_work;
pub const ThreadSafeFunction = nt.ThreadSafeFunction;
pub const napi_threadsafe_function = nt.napi_threadsafe_function;
pub const NAPI_AUTO_LENGTH = nt.NAPI_AUTO_LENGTH;
pub const js_helpers = js;
pub const napi_types = nt;

pub fn toVal(v: napi_value) qjs.JSValue {
    if (v) |ptr| return ptr.* else return js.js_undefined();
}

pub fn napiSpan(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr) |p| {
        if (len == NAPI_AUTO_LENGTH) {
            const z: [*:0]const u8 = @ptrCast(p);
            return std.mem.span(z);
        }
        return p[0..len];
    }
    return null;
}
