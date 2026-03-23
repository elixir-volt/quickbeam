const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;
const gpa = types.gpa;

pub const napi_status = c_uint;

pub const Status = enum(c_uint) {
    ok = 0,
    invalid_arg = 1,
    object_expected = 2,
    string_expected = 3,
    name_expected = 4,
    function_expected = 5,
    number_expected = 6,
    boolean_expected = 7,
    array_expected = 8,
    generic_failure = 9,
    pending_exception = 10,
    cancelled = 11,
    escape_called_twice = 12,
    handle_scope_mismatch = 13,
    callback_scope_mismatch = 14,
    queue_full = 15,
    closing = 16,
    bigint_expected = 17,
    date_expected = 18,
    arraybuffer_expected = 19,
    detachable_arraybuffer_expected = 20,
    would_deadlock = 21,
};

pub const napi_valuetype = enum(c_uint) {
    @"undefined" = 0,
    @"null" = 1,
    boolean = 2,
    number = 3,
    string = 4,
    symbol = 5,
    object = 6,
    function = 7,
    external = 8,
    bigint = 9,
};

pub const napi_typedarray_type = enum(c_uint) {
    int8_array = 0,
    uint8_array = 1,
    uint8_clamped_array = 2,
    int16_array = 3,
    uint16_array = 4,
    int32_array = 5,
    uint32_array = 6,
    float32_array = 7,
    float64_array = 8,
    bigint64_array = 9,
    biguint64_array = 10,
};

pub const napi_threadsafe_function_release_mode = enum(c_uint) {
    release = 0,
    abort = 1,
};

pub const napi_threadsafe_function_call_mode = c_uint;
pub const napi_tsfn_nonblocking: c_uint = 0;
pub const napi_tsfn_blocking: c_uint = 1;

pub const napi_property_attributes = c_uint;
pub const NAPI_DEFAULT: c_uint = 0;
pub const NAPI_WRITABLE: c_uint = 1 << 0;
pub const NAPI_ENUMERABLE: c_uint = 1 << 1;
pub const NAPI_CONFIGURABLE: c_uint = 1 << 2;
pub const NAPI_STATIC: c_uint = 1 << 10;

pub const NAPI_AUTO_LENGTH: usize = std.math.maxInt(usize);
pub const NAPI_VERSION: u32 = 9;

pub const napi_value = ?*qjs.JSValue;
pub const napi_handle_scope = ?*HandleScope;
pub const napi_escapable_handle_scope = ?*HandleScope;
pub const napi_deferred = ?*Deferred;
pub const napi_callback_info = ?*CallbackInfo;
pub const napi_ref = ?*NapiReference;
pub const napi_async_work = ?*AsyncWork;
pub const napi_threadsafe_function = ?*ThreadSafeFunction;

pub const napi_callback = ?*const fn (napi_env, napi_callback_info) callconv(.c) napi_value;
pub const napi_finalize = ?*const fn (napi_env, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const napi_async_execute_callback = *const fn (napi_env, ?*anyopaque) callconv(.c) void;
pub const napi_async_complete_callback = *const fn (napi_env, napi_status, ?*anyopaque) callconv(.c) void;
pub const napi_threadsafe_function_call_js = *const fn (napi_env, napi_value, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const napi_addon_register_func = *const fn (napi_env, napi_value) callconv(.c) napi_value;

pub const napi_property_descriptor = extern struct {
    utf8name: [*c]const u8 = null,
    name: napi_value = null,
    method: napi_callback = null,
    getter: napi_callback = null,
    setter: napi_callback = null,
    value: napi_value = null,
    attributes: napi_property_attributes = NAPI_DEFAULT,
    data: ?*anyopaque = null,
};

pub const napi_extended_error_info = extern struct {
    error_message: [*c]const u8,
    engine_reserved: ?*anyopaque,
    engine_error_code: u32,
    error_code: napi_status,
};

pub const napi_node_version = extern struct {
    major: u32,
    minor: u32,
    patch: u32,
    release: [*:0]const u8,
};

pub const napi_type_tag = extern struct {
    lower: u64,
    upper: u64,
};

pub const napi_module = extern struct {
    nm_version: c_int,
    nm_flags: c_uint,
    nm_filename: [*c]const u8,
    nm_register_func: ?napi_addon_register_func,
    nm_modname: [*c]const u8,
    nm_priv: ?*anyopaque,
    reserved: [4]?*anyopaque,
};

// ──── napi_env ────

pub const napi_env = ?*NapiEnv;

pub const NapiEnv = struct {
    ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    last_error: napi_extended_error_info = .{
        .error_message = null,
        .engine_reserved = null,
        .engine_error_code = 0,
        .error_code = @intFromEnum(Status.ok),
    },
    pending_exception: qjs.JSValue = js.JS_UNDEFINED,
    has_pending_exception: bool = false,
    instance_data: ?*anyopaque = null,
    instance_data_finalize: napi_finalize = null,
    instance_data_hint: ?*anyopaque = null,
    scope_stack: std.ArrayListUnmanaged(*HandleScope) = .{},

    pub fn setLastError(self: *NapiEnv, status: Status) napi_status {
        self.last_error.error_code = @intFromEnum(status);
        return @intFromEnum(status);
    }

    pub fn ok(self: *NapiEnv) napi_status {
        return self.setLastError(.ok);
    }

    pub fn invalidArg(self: *NapiEnv) napi_status {
        return self.setLastError(.invalid_arg);
    }

    pub fn genericFailure(self: *NapiEnv) napi_status {
        return self.setLastError(.generic_failure);
    }

    pub fn setPendingException(self: *NapiEnv, exception: qjs.JSValue) void {
        if (self.has_pending_exception) {
            qjs.JS_FreeValue(self.ctx, self.pending_exception);
        }
        self.pending_exception = qjs.JS_DupValue(self.ctx, exception);
        self.has_pending_exception = true;
    }

    pub fn clearPendingException(self: *NapiEnv) void {
        if (self.has_pending_exception) {
            qjs.JS_FreeValue(self.ctx, self.pending_exception);
            self.pending_exception = js.JS_UNDEFINED;
            self.has_pending_exception = false;
        }
    }

    /// Store a JS value in the current handle scope and return a stable pointer.
    /// The pointer remains valid until the scope is closed.
    pub fn createNapiValue(self: *NapiEnv, val: qjs.JSValue) napi_value {
        if (self.scope_stack.items.len > 0) {
            const scope = self.scope_stack.items[self.scope_stack.items.len - 1];
            return scope.track(self.ctx, val);
        }
        // No scope open — allocate a standalone slot (caller must manage)
        const slot = gpa.create(qjs.JSValue) catch return null;
        slot.* = qjs.JS_DupValue(self.ctx, val);
        return slot;
    }

    pub fn deinit(self: *NapiEnv) void {
        self.clearPendingException();
        for (self.scope_stack.items) |scope| {
            scope.deinit(self.ctx);
            gpa.destroy(scope);
        }
        self.scope_stack.deinit(gpa);
    }
};

// ──── Handle Scope ────

pub const HandleScope = struct {
    values: std.ArrayListUnmanaged(qjs.JSValue) = .{},
    escapable: bool,
    escaped: bool = false,

    pub fn init(escapable: bool) *HandleScope {
        const scope = gpa.create(HandleScope) catch @panic("OOM");
        scope.* = .{
            .escapable = escapable,
        };
        return scope;
    }

    /// Store a JS value in this scope (DupValue to prevent GC), return stable pointer.
    pub fn track(self: *HandleScope, ctx: *qjs.JSContext, val: qjs.JSValue) *qjs.JSValue {
        const duped = qjs.JS_DupValue(ctx, val);
        self.values.append(gpa, duped) catch @panic("OOM");
        return &self.values.items[self.values.items.len - 1];
    }

    pub fn deinit(self: *HandleScope, ctx: *qjs.JSContext) void {
        for (self.values.items) |v| {
            qjs.JS_FreeValue(ctx, v);
        }
        self.values.deinit(gpa);
    }
};

// ──── Reference ────

pub const NapiReference = struct {
    value: qjs.JSValue,
    ref_count: u32,
    ctx: *qjs.JSContext,
    weak: bool = false,
    finalize_cb: napi_finalize = null,
    finalize_data: ?*anyopaque = null,
    finalize_hint: ?*anyopaque = null,

    pub fn ref(self: *NapiReference) void {
        if (self.ref_count == 0 and !self.weak) {
            _ = qjs.JS_DupValue(self.ctx, self.value);
        }
        self.ref_count += 1;
    }

    pub fn unref(self: *NapiReference) void {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
            if (self.ref_count == 0 and !self.weak) {
                qjs.JS_FreeValue(self.ctx, self.value);
            }
        }
    }

    pub fn deinit(self: *NapiReference) void {
        if (self.ref_count > 0) {
            qjs.JS_FreeValue(self.ctx, self.value);
        }
        gpa.destroy(self);
    }
};

// ──── Deferred (for promises) ────

pub const Deferred = struct {
    resolve_func: qjs.JSValue,
    reject_func: qjs.JSValue,
    ctx: *qjs.JSContext,

    pub fn deinit(self: *Deferred) void {
        qjs.JS_FreeValue(self.ctx, self.resolve_func);
        qjs.JS_FreeValue(self.ctx, self.reject_func);
        gpa.destroy(self);
    }
};

// ──── Callback Info ────

pub const CallbackInfo = struct {
    this: qjs.JSValue,
    args: [*c]qjs.JSValue,
    argc: c_int,
    data: ?*anyopaque,
    new_target: qjs.JSValue = js.JS_UNDEFINED,
};

// ──── Async Work ────

pub const AsyncWork = struct {
    env: *NapiEnv,
    execute: napi_async_execute_callback,
    complete: ?napi_async_complete_callback,
    data: ?*anyopaque = null,
    thread: ?std.Thread = null,
    status: std.atomic.Value(AsyncStatus) = std.atomic.Value(AsyncStatus).init(.pending),

    pub const AsyncStatus = enum(u32) {
        pending = 0,
        started = 1,
        completed = 2,
        cancelled = 3,
    };

    pub fn deinit(self: *AsyncWork) void {
        gpa.destroy(self);
    }
};

// ──── Thread-safe Function ────

pub const ThreadSafeFunction = struct {
    env: *NapiEnv,
    callback: ?qjs.JSValue = null,
    call_js_cb: ?napi_threadsafe_function_call_js = null,
    ctx: ?*anyopaque = null,
    finalize_cb: napi_finalize = null,
    finalize_data: ?*anyopaque = null,
    thread_count: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    queue: std.ArrayListUnmanaged(?*anyopaque) = .{},
    max_queue_size: usize = 0,
    lock: std.Thread.Mutex = .{},
    condvar: std.Thread.Condition = .{},
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn deinit(self: *ThreadSafeFunction) void {
        if (self.callback) |cb| {
            qjs.JS_FreeValue(self.env.ctx, cb);
        }
        self.queue.deinit(gpa);
        gpa.destroy(self);
    }
};

// ──── External data class ────

pub var external_class_id: qjs.JSClassID = 0;

pub const ExternalData = struct {
    data: ?*anyopaque,
    finalize_cb: napi_finalize,
    finalize_hint: ?*anyopaque,
    type_tag: ?napi_type_tag = null,
};

// ──── Function callback trampoline data ────

pub const FunctionCallbackData = struct {
    cb: *const fn (napi_env, napi_callback_info) callconv(.c) napi_value,
    data: ?*anyopaque,
    env: *NapiEnv,
};
