const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const qjs = @cImport(@cInclude("quickjs.h"));

// ──────────────────── JSValue helpers ────────────────────
// QuickJS macros that don't translate through @cImport

fn js_undefined() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_UNDEFINED, .u = .{ .int32 = 0 } };
}

fn js_null() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_NULL, .u = .{ .int32 = 0 } };
}

fn js_exception() qjs.JSValue {
    return qjs.JSValue{ .tag = qjs.JS_TAG_EXCEPTION, .u = .{ .int32 = 0 } };
}

fn js_is_exception(v: qjs.JSValue) bool {
    return v.tag == qjs.JS_TAG_EXCEPTION;
}

// ──────────────────── Resource ────────────────────

const RuntimeData = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    queue_head: ?*MessageNode,
    queue_tail: ?*MessageNode,
    stopped: bool,
    thread: ?std.Thread,
};

pub const RuntimeResource = beam.Resource(*RuntimeData, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(ptr: **RuntimeData) void {
            const data = ptr.*;
            enqueue(data, .{ .stop = {} });
            if (data.thread) |t| t.join();
            gpa.destroy(data);
        }
    },
});

// ──────────────────── Message queue ────────────────────
// Simple intrusive linked list protected by the RuntimeData mutex.

const Message = union(enum) {
    eval: RequestPayload,
    call_fn: CallPayload,
    load_module: ModulePayload,
    reset: RequestPayload,
    resolve_call: CallResponse,
    reject_call: CallResponse,
    send_message: StringPayload,
    stop,
};

const RequestPayload = struct {
    code: []const u8,
    result: *Result,
    done: *std.Thread.ResetEvent,
};

const CallPayload = struct {
    name: []const u8,
    args_json: []const u8,
    result: *Result,
    done: *std.Thread.ResetEvent,
};

const ModulePayload = struct {
    name: []const u8,
    code: []const u8,
    result: *Result,
    done: *std.Thread.ResetEvent,
};

const CallResponse = struct {
    id: u64,
    json: []const u8,
};

const StringPayload = struct {
    data: []const u8,
};

const Result = struct {
    ok: bool = false,
    json: []const u8 = "",
};

const MessageNode = struct {
    msg: Message,
    next: ?*MessageNode,
};

const gpa = std.heap.c_allocator;

fn enqueue(rd: *RuntimeData, msg: Message) void {
    const node = gpa.create(MessageNode) catch return;
    node.* = .{ .msg = msg, .next = null };

    rd.mutex.lock();
    defer rd.mutex.unlock();

    if (rd.queue_tail) |tail| {
        tail.next = node;
    } else {
        rd.queue_head = node;
    }
    rd.queue_tail = node;
    rd.cond.signal();
}

fn dequeue(rd: *RuntimeData) ?Message {
    rd.mutex.lock();
    defer rd.mutex.unlock();

    const node = rd.queue_head orelse return null;
    rd.queue_head = node.next;
    if (rd.queue_head == null) rd.queue_tail = null;
    const msg = node.msg;
    gpa.destroy(node);
    return msg;
}

fn dequeue_blocking(rd: *RuntimeData, timeout_ns: ?u64) ?Message {
    rd.mutex.lock();

    while (rd.queue_head == null and !rd.stopped) {
        if (timeout_ns) |t| {
            rd.cond.timedWait(&rd.mutex, t) catch break;
        } else {
            rd.cond.wait(&rd.mutex);
        }
    }

    const node = rd.queue_head;
    if (node) |n| {
        rd.queue_head = n.next;
        if (rd.queue_head == null) rd.queue_tail = null;
        rd.mutex.unlock();
        const msg = n.msg;
        gpa.destroy(n);
        return msg;
    }

    rd.mutex.unlock();
    return null;
}

// ──────────────────── NIF entry points ────────────────────

pub fn start_runtime(owner_pid: beam.pid) !RuntimeResource {
    const data = try gpa.create(RuntimeData);
    data.* = .{
        .mutex = .{},
        .cond = .{},
        .queue_head = null,
        .queue_tail = null,
        .stopped = false,
        .thread = null,
    };

    const res = try RuntimeResource.create(data, .{});

    data.thread = std.Thread.spawn(.{}, worker_main, .{ data, owner_pid }) catch {
        gpa.destroy(data);
        return error.ThreadSpawn;
    };

    return res;
}

pub fn eval(resource: RuntimeResource, code: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .eval = .{
        .code = code,
        .result = &result,
        .done = &done,
    } });

    done.wait();

    if (result.ok) {
        return beam.make(.{ .ok, result.json }, .{});
    } else {
        return beam.make(.{ .@"error", result.json }, .{});
    }
}

pub fn call_function(resource: RuntimeResource, name: []const u8, args_json: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .call_fn = .{
        .name = name,
        .args_json = args_json,
        .result = &result,
        .done = &done,
    } });

    done.wait();

    if (result.ok) {
        return beam.make(.{ .ok, result.json }, .{});
    } else {
        return beam.make(.{ .@"error", result.json }, .{});
    }
}

pub fn load_module(resource: RuntimeResource, name: []const u8, code: []const u8) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .load_module = .{
        .name = name,
        .code = code,
        .result = &result,
        .done = &done,
    } });

    done.wait();

    if (result.ok) {
        return beam.make(.{ .ok, result.json }, .{});
    } else {
        return beam.make(.{ .@"error", result.json }, .{});
    }
}

pub fn reset_runtime(resource: RuntimeResource) beam.term {
    var result = Result{};
    var done = std.Thread.ResetEvent{};
    const data = resource.unpack();

    enqueue(data, .{ .reset = .{
        .code = "",
        .result = &result,
        .done = &done,
    } });

    done.wait();

    if (result.ok) {
        return beam.make(.{ .ok, result.json }, .{});
    } else {
        return beam.make(.{ .@"error", result.json }, .{});
    }
}

pub fn stop_runtime(resource: RuntimeResource) beam.term {
    const data = resource.unpack();
    enqueue(data, .{ .stop = {} });
    if (data.thread) |t| {
        t.join();
        data.thread = null;
    }
    return beam.make(.ok, .{});
}

pub fn resolve_call(resource: RuntimeResource, call_id: u64, value_json: []const u8) beam.term {
    const json_copy = gpa.dupe(u8, value_json) catch return beam.make(.ok, .{});
    enqueue(resource.unpack(), .{ .resolve_call = .{ .id = call_id, .json = json_copy } });
    return beam.make(.ok, .{});
}

pub fn reject_call(resource: RuntimeResource, call_id: u64, reason: []const u8) beam.term {
    const reason_copy = gpa.dupe(u8, reason) catch return beam.make(.ok, .{});
    enqueue(resource.unpack(), .{ .reject_call = .{ .id = call_id, .json = reason_copy } });
    return beam.make(.ok, .{});
}

pub fn send_message(resource: RuntimeResource, json: []const u8) beam.term {
    const json_copy = gpa.dupe(u8, json) catch return beam.make(.ok, .{});
    enqueue(resource.unpack(), .{ .send_message = .{ .data = json_copy } });
    return beam.make(.ok, .{});
}

// ──────────────────── Worker thread ────────────────────

const PendingCall = struct {
    resolve: qjs.JSValue,
    reject: qjs.JSValue,
};

const TimerEntry = struct {
    callback: qjs.JSValue,
    deadline: i128,
    interval_ns: ?u64,
};

const WorkerState = struct {
    ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    owner_pid: beam.pid,
    rd: *RuntimeData,
    pending_calls: std.AutoHashMap(u64, PendingCall),
    timers: std.AutoHashMap(u64, TimerEntry),
    next_call_id: u64 = 1,
    next_timer_id: u64 = 1,
    buf: [4096]u8 = undefined,

    fn deinit(self: *WorkerState) void {
        var call_it = self.pending_calls.valueIterator();
        while (call_it.next()) |pc| {
            qjs.JS_FreeValue(self.ctx, pc.resolve);
            qjs.JS_FreeValue(self.ctx, pc.reject);
        }
        self.pending_calls.deinit();

        var timer_it = self.timers.valueIterator();
        while (timer_it.next()) |t| {
            qjs.JS_FreeValue(self.ctx, t.callback);
        }
        self.timers.deinit();

        qjs.JS_FreeContext(self.ctx);
    }

    fn drain_jobs(self: *WorkerState) void {
        var pctx: ?*qjs.JSContext = null;
        while (true) {
            const ret = qjs.JS_ExecutePendingJob(self.rt, &pctx);
            if (ret <= 0) break;
        }
    }

    fn next_timer_timeout_ns(self: *WorkerState) ?u64 {
        var min_deadline: ?i128 = null;
        var it = self.timers.valueIterator();
        while (it.next()) |t| {
            if (min_deadline == null or t.deadline < min_deadline.?) {
                min_deadline = t.deadline;
            }
        }
        if (min_deadline) |d| {
            const now = std.time.nanoTimestamp();
            if (d <= now) return 0;
            return @intCast(d - now);
        }
        return null;
    }

    fn fire_expired_timers(self: *WorkerState) void {
        const now = std.time.nanoTimestamp();

        // Collect expired timer ids
        var expired_buf: [64]u64 = undefined;
        var expired_count: usize = 0;
        var it = self.timers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deadline <= now and expired_count < expired_buf.len) {
                expired_buf[expired_count] = entry.key_ptr.*;
                expired_count += 1;
            }
        }

        for (expired_buf[0..expired_count]) |id| {
            if (self.timers.getPtr(id)) |entry| {
                const callback = entry.callback;
                const interval = entry.interval_ns;

                const ret = qjs.JS_Call(self.ctx, callback, js_undefined(), 0, null);
                defer qjs.JS_FreeValue(self.ctx, ret);
                if (js_is_exception(ret)) {
                    const exc = qjs.JS_GetException(self.ctx);
                    qjs.JS_FreeValue(self.ctx, exc);
                }

                if (interval) |iv| {
                    // Reschedule interval
                    entry.deadline = std.time.nanoTimestamp() + @as(i128, iv);
                } else {
                    // One-shot: remove and free callback
                    qjs.JS_FreeValue(self.ctx, callback);
                    _ = self.timers.remove(id);
                }

                self.drain_jobs();
            }
        }
    }

    fn resolve_pending(self: *WorkerState, id: u64, value_json: []const u8) void {
        defer gpa.free(value_json);
        const kv = self.pending_calls.fetchRemove(id) orelse return;
        const pc = kv.value;
        defer qjs.JS_FreeValue(self.ctx, pc.resolve);
        defer qjs.JS_FreeValue(self.ctx, pc.reject);

        const val = json_parse(self.ctx, value_json);
        defer qjs.JS_FreeValue(self.ctx, val);

        var args = [_]qjs.JSValue{val};
        const ret = qjs.JS_Call(self.ctx, pc.resolve, js_undefined(), 1, &args);
        qjs.JS_FreeValue(self.ctx, ret);
        self.drain_jobs();
    }

    fn reject_pending(self: *WorkerState, id: u64, reason: []const u8) void {
        defer gpa.free(reason);
        const kv = self.pending_calls.fetchRemove(id) orelse return;
        const pc = kv.value;
        defer qjs.JS_FreeValue(self.ctx, pc.resolve);
        defer qjs.JS_FreeValue(self.ctx, pc.reject);

        const val = qjs.JS_NewStringLen(self.ctx, reason.ptr, reason.len);
        defer qjs.JS_FreeValue(self.ctx, val);

        var args = [_]qjs.JSValue{val};
        const ret = qjs.JS_Call(self.ctx, pc.reject, js_undefined(), 1, &args);
        qjs.JS_FreeValue(self.ctx, ret);
        self.drain_jobs();
    }

    fn do_eval(self: *WorkerState, code: []const u8, result: *Result) void {
        const code_z = gpa.dupeZ(u8, code) catch {
            result.ok = false;
            result.json = "Out of memory";
            return;
        };
        defer gpa.free(code_z);

        // Enable top-level await if code contains 'await'
        var flags: c_int = qjs.JS_EVAL_TYPE_GLOBAL;
        if (std.mem.indexOf(u8, code, "await") != null) {
            flags |= qjs.JS_EVAL_FLAG_ASYNC;
        }
        const val = qjs.JS_Eval(self.ctx, code_z.ptr, code.len, "<eval>", flags);
        defer qjs.JS_FreeValue(self.ctx, val);
        self.drain_jobs();

        if (js_is_exception(val)) {
            result.ok = false;
            result.json = self.get_exception_message();
            return;
        }

        if (is_promise(self.ctx, val)) {
            self.await_promise(val, result, flags & qjs.JS_EVAL_FLAG_ASYNC != 0);
            return;
        }

        result.ok = true;
        result.json = js_to_json(self.ctx, val);
    }

    fn do_call(self: *WorkerState, name: []const u8, args_json: []const u8, result: *Result) void {
        const call_code = std.fmt.bufPrint(&self.buf, "(function() {{ return {s}.apply(null, {s}); }})()", .{ name, args_json }) catch {
            result.ok = false;
            result.json = "Call expression too long";
            return;
        };

        const val = qjs.JS_Eval(self.ctx, call_code.ptr, call_code.len, "<call>", qjs.JS_EVAL_TYPE_GLOBAL);
        defer qjs.JS_FreeValue(self.ctx, val);
        self.drain_jobs();

        if (js_is_exception(val)) {
            result.ok = false;
            result.json = self.get_exception_message();
            return;
        }

        if (is_promise(self.ctx, val)) {
            self.await_promise(val, result, false);
            return;
        }

        result.ok = true;
        result.json = js_to_json(self.ctx, val);
    }

    fn do_load_module(self: *WorkerState, name: []const u8, code: []const u8, result: *Result) void {
        _ = name;
        // Use eval with MODULE flag
        const val = qjs.JS_Eval(self.ctx, code.ptr, code.len, "<module>", qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY);
        if (js_is_exception(val)) {
            result.ok = false;
            result.json = self.get_exception_message();
            return;
        }

        const eval_result = qjs.JS_EvalFunction(self.ctx, val);
        defer qjs.JS_FreeValue(self.ctx, eval_result);
        self.drain_jobs();

        if (js_is_exception(eval_result)) {
            result.ok = false;
            result.json = self.get_exception_message();
            return;
        }

        result.ok = true;
        result.json = "ok";
    }

    fn do_reset(self: *WorkerState, result: *Result) void {
        // Free pending calls and timers
        var call_it = self.pending_calls.valueIterator();
        while (call_it.next()) |pc| {
            qjs.JS_FreeValue(self.ctx, pc.resolve);
            qjs.JS_FreeValue(self.ctx, pc.reject);
        }
        self.pending_calls.clearRetainingCapacity();

        var timer_it = self.timers.valueIterator();
        while (timer_it.next()) |t| {
            qjs.JS_FreeValue(self.ctx, t.callback);
        }
        self.timers.clearRetainingCapacity();

        // Run GC before freeing context to clean up any lingering refs
        qjs.JS_FreeContext(self.ctx);
        self.ctx = qjs.JS_NewContext(self.rt) orelse {
            result.ok = false;
            result.json = "Failed to create new context";
            return;
        };
        self.install_globals();
        result.ok = true;
        result.json = "ok";
    }

    fn await_promise(self: *WorkerState, promise: qjs.JSValue, result: *Result, unwrap_async: bool) void {
        // Install .then/.catch handlers that write to globals
        const then_code =
            \\(function(p, id) {
            \\  globalThis['__qb_' + id + '_s'] = 'pending';
            \\  p.then(
            \\    function(v) { globalThis['__qb_' + id + '_s'] = 'ok'; globalThis['__qb_' + id + '_v'] = v; },
            \\    function(e) { globalThis['__qb_' + id + '_s'] = 'err'; globalThis['__qb_' + id + '_v'] = e; }
            \\  );
            \\})
        ;
        const check_fn = qjs.JS_Eval(self.ctx, then_code, then_code.len, "<await>", qjs.JS_EVAL_TYPE_GLOBAL);
        defer qjs.JS_FreeValue(self.ctx, check_fn);

        const check_id = self.next_call_id;
        self.next_call_id += 1;
        const id_val = qjs.JS_NewInt64(self.ctx, @intCast(check_id));
        defer qjs.JS_FreeValue(self.ctx, id_val);

        var call_args = [_]qjs.JSValue{ promise, id_val };
        const apply_ret = qjs.JS_Call(self.ctx, check_fn, js_undefined(), 2, &call_args);
        qjs.JS_FreeValue(self.ctx, apply_ret);
        self.drain_jobs();

        // Poll for completion
        const id_str = std.fmt.bufPrint(&self.buf, "{d}", .{check_id}) catch "0";
        var status_key_buf: [64]u8 = undefined;
        var value_key_buf: [64]u8 = undefined;
        const status_key = std.fmt.bufPrintZ(&status_key_buf, "__qb_{s}_s", .{id_str}) catch return;
        const value_key = std.fmt.bufPrintZ(&value_key_buf, "__qb_{s}_v", .{id_str}) catch return;

        for (0..10000) |_| {
            const global = qjs.JS_GetGlobalObject(self.ctx);
            defer qjs.JS_FreeValue(self.ctx, global);

            const status_val = qjs.JS_GetPropertyStr(self.ctx, global, status_key.ptr);
            defer qjs.JS_FreeValue(self.ctx, status_val);
            const status_str = js_to_string(self.ctx, status_val);

            if (std.mem.eql(u8, status_str, "ok")) {
                const v = qjs.JS_GetPropertyStr(self.ctx, global, value_key.ptr);
                defer qjs.JS_FreeValue(self.ctx, v);

                // JS_EVAL_FLAG_ASYNC wraps result in {value: <result>}
                if (unwrap_async and qjs.JS_IsObject(v)) {
                    const inner = qjs.JS_GetPropertyStr(self.ctx, v, "value");
                    defer qjs.JS_FreeValue(self.ctx, inner);
                    result.ok = true;
                    result.json = js_to_json(self.ctx, inner);
                } else {
                    result.ok = true;
                    result.json = js_to_json(self.ctx, v);
                }
                cleanup_globals(self.ctx, global, status_key, value_key);
                return;
            } else if (std.mem.eql(u8, status_str, "err")) {
                const v = qjs.JS_GetPropertyStr(self.ctx, global, value_key.ptr);
                defer qjs.JS_FreeValue(self.ctx, v);
                result.ok = false;
                result.json = get_error_message(self.ctx, v);
                cleanup_globals(self.ctx, global, status_key, value_key);
                return;
            }

            if (dequeue(self.rd)) |msg| {
                switch (msg) {
                    .resolve_call => |rc| self.resolve_pending(rc.id, rc.json),
                    .reject_call => |rc| self.reject_pending(rc.id, rc.json),
                    else => {},
                }
            } else {
                std.Thread.yield() catch {};
            }

            self.drain_jobs();
        }

        result.ok = false;
        result.json = "Promise resolution timeout";
    }

    fn get_exception_message(self: *WorkerState) []const u8 {
        const exc = qjs.JS_GetException(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, exc);
        return get_error_message(self.ctx, exc);
    }

    fn install_globals(self: *WorkerState) void {
        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);

        // Store WorkerState pointer as opaque on the context
        qjs.JS_SetContextOpaque(self.ctx, @ptrCast(self));

        install_beam_object(self.ctx, global);
        install_timers(self.ctx, global);
        install_console(self.ctx, global);
    }
};

fn worker_main(rd: *RuntimeData, owner_pid: beam.pid) void {
    const rt = qjs.JS_NewRuntime() orelse return;
    defer qjs.JS_FreeRuntime(rt);

    qjs.JS_SetMemoryLimit(rt, 256 * 1024 * 1024);
    qjs.JS_SetMaxStackSize(rt, 1024 * 1024);

    const ctx = qjs.JS_NewContext(rt) orelse return;

    var state = WorkerState{
        .ctx = ctx,
        .rt = rt,
        .owner_pid = owner_pid,
        .rd = rd,
        .pending_calls = std.AutoHashMap(u64, PendingCall).init(gpa),
        .timers = std.AutoHashMap(u64, TimerEntry).init(gpa),
    };
    defer state.deinit();

    state.install_globals();

    while (true) {
        const timeout = state.next_timer_timeout_ns();
        const msg = if (timeout != null and timeout.? == 0)
            dequeue(rd)
        else
            dequeue_blocking(rd, timeout orelse null);

        if (msg) |m| {
            switch (m) {
                .eval => |p| {
                    state.do_eval(p.code, p.result);
                    p.done.set();
                },
                .call_fn => |p| {
                    state.do_call(p.name, p.args_json, p.result);
                    p.done.set();
                },
                .load_module => |p| {
                    state.do_load_module(p.name, p.code, p.result);
                    p.done.set();
                },
                .reset => |p| {
                    state.do_reset(p.result);
                    p.done.set();
                },
                .resolve_call => |rc| state.resolve_pending(rc.id, rc.json),
                .reject_call => |rc| state.reject_pending(rc.id, rc.json),
                .send_message => |sm| gpa.free(sm.data),
                .stop => break,
            }
        }

        state.fire_expired_timers();
        state.drain_jobs();
    }

    rd.mutex.lock();
    rd.stopped = true;
    rd.mutex.unlock();
}

// ──────────────────── beam.call ────────────────────

fn install_beam_object(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const beam_obj = qjs.JS_NewObject(ctx);
    const call_fn = qjs.JS_NewCFunction(ctx, &beam_call_impl, "call", 1);
    _ = qjs.JS_SetPropertyStr(ctx, beam_obj, "call", call_fn);
    _ = qjs.JS_SetPropertyStr(ctx, global, "beam", beam_obj);
}

fn beam_call_impl(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this_val;
    const self: *WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "beam.call requires a handler name");

    const name_ptr = qjs.JS_ToCString(ctx, argv[0]) orelse
        return qjs.JS_ThrowTypeError(ctx, "beam.call: first argument must be a string");
    const name = std.mem.span(name_ptr);

    // Serialize remaining args as JSON array
    var args_json: []const u8 = "[]";
    var args_alloc = false;
    if (argc > 1) {
        const arr = qjs.JS_NewArray(ctx);
        var i: c_int = 1;
        while (i < argc) : (i += 1) {
            _ = qjs.JS_SetPropertyUint32(ctx, arr, @intCast(i - 1), qjs.JS_DupValue(ctx, argv[@intCast(i)]));
        }
        args_json = js_to_json(ctx.?, arr);
        args_alloc = true;
        qjs.JS_FreeValue(ctx, arr);
    }

    // Create promise
    var resolve_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx, &resolve_funcs);
    if (js_is_exception(promise)) {
        qjs.JS_FreeCString(ctx, name_ptr);
        return js_exception();
    }

    const call_id = self.next_call_id;
    self.next_call_id += 1;

    self.pending_calls.put(call_id, .{
        .resolve = resolve_funcs[0],
        .reject = resolve_funcs[1],
    }) catch {
        qjs.JS_FreeValue(ctx, resolve_funcs[0]);
        qjs.JS_FreeValue(ctx, resolve_funcs[1]);
        qjs.JS_FreeValue(ctx, promise);
        qjs.JS_FreeCString(ctx, name_ptr);
        return qjs.JS_ThrowOutOfMemory(ctx);
    };

    // Send {:beam_call, call_id, name, args_json} to owner
    const send_env = beam.alloc_env();
    var pid = self.owner_pid;
    var tuple_elems = [_]e.ErlNifTerm{
        make_atom(send_env, "beam_call"),
        e.enif_make_uint64(send_env, call_id),
        make_binary_term(send_env, name),
        make_binary_term(send_env, args_json),
    };
    const msg_term = e.enif_make_tuple_from_array(send_env, &tuple_elems, 4);
    _ = e.enif_send(null, &pid, send_env, msg_term);
    beam.free_env(send_env);

    qjs.JS_FreeCString(ctx, name_ptr);
    if (args_alloc) gpa.free(args_json);

    return promise;
}

// ──────────────────── Timers ────────────────────

fn install_timers(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const set_timeout = qjs.JS_NewCFunction(ctx, &set_timeout_impl, "setTimeout", 2);
    _ = qjs.JS_SetPropertyStr(ctx, global, "setTimeout", set_timeout);

    const set_interval = qjs.JS_NewCFunction(ctx, &set_interval_impl, "setInterval", 2);
    _ = qjs.JS_SetPropertyStr(ctx, global, "setInterval", set_interval);

    const clear_fn = qjs.JS_NewCFunction(ctx, &clear_timer_impl, "clearTimeout", 1);
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearTimeout", qjs.JS_DupValue(ctx, clear_fn));
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearInterval", clear_fn);
}

fn set_timeout_impl(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return set_timer_common(ctx, this_val, argc, argv, false);
}

fn set_interval_impl(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return set_timer_common(ctx, this_val, argc, argv, true);
}

fn set_timer_common(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue, is_interval: bool) qjs.JSValue {
    const self: *WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

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

    // Wake the event loop
    self.rd.cond.signal();

    return qjs.JS_NewFloat64(ctx, @floatFromInt(id));
}

fn clear_timer_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const self: *WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1) return js_undefined();

    var id_f: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx, &id_f, argv[0]);
    const id: u64 = @intFromFloat(id_f);

    if (self.timers.fetchRemove(id)) |kv| {
        qjs.JS_FreeValue(ctx, kv.value.callback);
    }

    return js_undefined();
}

// ──────────────────── Console ────────────────────

fn install_console(ctx: *qjs.JSContext, global: qjs.JSValue) void {
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
    return js_undefined();
}

// ──────────────────── JS ↔ string helpers ────────────────────

fn json_parse(ctx: *qjs.JSContext, json: []const u8) qjs.JSValue {
    const json_str = qjs.JS_NewStringLen(ctx, json.ptr, json.len);
    defer qjs.JS_FreeValue(ctx, json_str);

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const json_obj = qjs.JS_GetPropertyStr(ctx, global, "JSON");
    defer qjs.JS_FreeValue(ctx, json_obj);

    const parse_fn = qjs.JS_GetPropertyStr(ctx, json_obj, "parse");
    defer qjs.JS_FreeValue(ctx, parse_fn);

    var args = [_]qjs.JSValue{json_str};
    const result = qjs.JS_Call(ctx, parse_fn, json_obj, 1, &args);

    if (js_is_exception(result)) {
        const exc = qjs.JS_GetException(ctx);
        qjs.JS_FreeValue(ctx, exc);
        return qjs.JS_NewStringLen(ctx, json.ptr, json.len);
    }

    return result;
}

fn js_to_json(ctx: anytype, val: qjs.JSValue) []const u8 {
    const c: *qjs.JSContext = switch (@typeInfo(@TypeOf(ctx))) {
        .optional => ctx orelse return "null",
        .pointer => ctx,
        else => @compileError("expected *JSContext or ?*JSContext"),
    };

    if (qjs.JS_IsUndefined(val) or qjs.JS_IsNull(val)) return "null";

    // For bools and numbers, use JS_ToCString which gives "true"/"false"/"42"/etc.
    if (qjs.JS_IsBool(val) or qjs.JS_IsNumber(val)) {
        const ptr = qjs.JS_ToCString(c, val);
        if (ptr == null) return "null";
        defer qjs.JS_FreeCString(c, ptr);
        return gpa.dupe(u8, std.mem.span(ptr)) catch "null";
    }

    // For strings, return directly (unquoted — Elixir side treats as raw string)
    if (qjs.JS_IsString(val)) {
        const ptr = qjs.JS_ToCString(c, val);
        if (ptr == null) return "null";
        const s = std.mem.span(ptr);
        const copy = gpa.dupe(u8, s) catch "null";
        qjs.JS_FreeCString(c, ptr);
        return copy;
    }

    // JSON.stringify for everything else
    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);

    const json_obj = qjs.JS_GetPropertyStr(c, global, "JSON");
    defer qjs.JS_FreeValue(c, json_obj);

    const stringify_fn = qjs.JS_GetPropertyStr(c, json_obj, "stringify");
    defer qjs.JS_FreeValue(c, stringify_fn);

    var args = [_]qjs.JSValue{val};
    const json_val = qjs.JS_Call(c, stringify_fn, json_obj, 1, &args);
    defer qjs.JS_FreeValue(c, json_val);

    if (js_is_exception(json_val) or qjs.JS_IsUndefined(json_val)) return "null";

    const ptr = qjs.JS_ToCString(c, json_val);
    if (ptr == null) return "null";
    const s = std.mem.span(ptr);
    const copy = gpa.dupe(u8, s) catch "null";
    qjs.JS_FreeCString(c, ptr);
    return copy;
}

fn js_to_string(ctx: *qjs.JSContext, val: qjs.JSValue) []const u8 {
    if (qjs.JS_IsUndefined(val) or qjs.JS_IsNull(val)) return "";
    const ptr = qjs.JS_ToCString(ctx, val);
    if (ptr == null) return "";
    const s = std.mem.span(ptr);
    const copy = gpa.dupe(u8, s) catch "";
    qjs.JS_FreeCString(ctx, ptr);
    return copy;
}

fn get_error_message(ctx: *qjs.JSContext, val: qjs.JSValue) []const u8 {
    if (qjs.JS_IsString(val)) return js_to_string(ctx, val);

    const msg_prop = qjs.JS_GetPropertyStr(ctx, val, "message");
    defer qjs.JS_FreeValue(ctx, msg_prop);

    if (qjs.JS_IsString(msg_prop)) return js_to_string(ctx, msg_prop);

    return js_to_string(ctx, val);
}

fn is_promise(ctx: *qjs.JSContext, val: qjs.JSValue) bool {
    if (!qjs.JS_IsObject(val)) return false;
    const then_prop = qjs.JS_GetPropertyStr(ctx, val, "then");
    const result = qjs.JS_IsFunction(ctx, then_prop);
    qjs.JS_FreeValue(ctx, then_prop);
    return result;
}

fn cleanup_globals(ctx: *qjs.JSContext, global: qjs.JSValue, status_key: []const u8, value_key: []const u8) void {
    const undef = js_undefined();
    const s_atom = qjs.JS_NewAtomLen(ctx, status_key.ptr, status_key.len);
    _ = qjs.JS_SetProperty(ctx, global, s_atom, undef);
    qjs.JS_FreeAtom(ctx, s_atom);

    const v_atom = qjs.JS_NewAtomLen(ctx, value_key.ptr, value_key.len);
    _ = qjs.JS_SetProperty(ctx, global, v_atom, undef);
    qjs.JS_FreeAtom(ctx, v_atom);
}

// ──────────────────── BEAM term helpers ────────────────────

fn make_atom(env: ?*e.ErlNifEnv, name: []const u8) e.ErlNifTerm {
    return e.enif_make_atom_len(env, name.ptr, name.len);
}

fn make_binary_term(env: ?*e.ErlNifEnv, data: []const u8) e.ErlNifTerm {
    var bin: e.ErlNifBinary = undefined;
    _ = e.enif_alloc_binary(data.len, &bin);
    @memcpy(bin.data[0..data.len], data);
    return e.enif_make_binary(env, &bin);
}
