const types = @import("types.zig");
const js = @import("js_helpers.zig");
const globals = @import("globals.zig");
const js_to_beam = @import("js_to_beam.zig");
const beam_to_js = @import("beam_to_js.zig");
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;

pub const PendingCall = struct {
    resolve: qjs.JSValue,
    reject: qjs.JSValue,
};

pub const TimerEntry = struct {
    callback: qjs.JSValue,
    deadline: i128,
    interval_ns: ?u64,
};

pub const WorkerState = struct {
    ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    owner_pid: beam.pid,
    rd: *types.RuntimeData,
    pending_calls: std.AutoHashMap(u64, PendingCall),
    timers: std.AutoHashMap(u64, TimerEntry),
    next_call_id: u64 = 1,
    next_timer_id: u64 = 1,
    start_time: i128 = 0,
    buf: [4096]u8 = @splat(0),

    pub fn deinit(self: *WorkerState) void {
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

    pub fn drain_jobs(self: *WorkerState) void {
        var pctx: ?*qjs.JSContext = null;
        while (true) {
            const ret = qjs.JS_ExecutePendingJob(self.rt, &pctx);
            if (ret <= 0) break;
        }
    }

    pub fn next_timer_timeout_ns(self: *WorkerState) ?u64 {
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

    pub fn fire_expired_timers(self: *WorkerState) void {
        const now = std.time.nanoTimestamp();

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
                // Dup callback before calling — the callback may clearInterval(id)
                // which removes the entry and frees the original callback.
                const callback = qjs.JS_DupValue(self.ctx, entry.callback);
                const interval = entry.interval_ns;

                const ret = qjs.JS_Call(self.ctx, callback, js.js_undefined(), 0, null);
                qjs.JS_FreeValue(self.ctx, ret);
                if (js.js_is_exception(ret)) {
                    const exc = qjs.JS_GetException(self.ctx);
                    qjs.JS_FreeValue(self.ctx, exc);
                }
                qjs.JS_FreeValue(self.ctx, callback);

                // Re-check: callback may have removed this timer via clearInterval
                if (self.timers.getPtr(id)) |live_entry| {
                    if (interval) |iv| {
                        live_entry.deadline = std.time.nanoTimestamp() + @as(i128, iv);
                    } else {
                        qjs.JS_FreeValue(self.ctx, live_entry.callback);
                        _ = self.timers.remove(id);
                    }
                }

                self.drain_jobs();
            }
        }
    }

    pub fn resolve_pending(self: *WorkerState, id: u64, value_json: []const u8) void {
        defer gpa.free(value_json);
        const kv = self.pending_calls.fetchRemove(id) orelse return;
        const pc = kv.value;
        defer qjs.JS_FreeValue(self.ctx, pc.resolve);
        defer qjs.JS_FreeValue(self.ctx, pc.reject);

        const val = js.json_parse(self.ctx, value_json);
        defer qjs.JS_FreeValue(self.ctx, val);

        var args = [_]qjs.JSValue{val};
        const ret = qjs.JS_Call(self.ctx, pc.resolve, js.js_undefined(), 1, &args);
        qjs.JS_FreeValue(self.ctx, ret);
        self.drain_jobs();
    }

    pub fn resolve_pending_term(self: *WorkerState, term_env: ?*e.ErlNifEnv, term: e.ErlNifTerm, id: u64) void {
        const env = term_env orelse return;
        const kv = self.pending_calls.fetchRemove(id) orelse {
            beam.free_env(env);
            return;
        };
        const pc = kv.value;
        defer qjs.JS_FreeValue(self.ctx, pc.resolve);
        defer qjs.JS_FreeValue(self.ctx, pc.reject);

        const val = beam_to_js.convert(self.ctx, env, term);
        defer qjs.JS_FreeValue(self.ctx, val);
        beam.free_env(env);

        var args = [_]qjs.JSValue{val};
        const ret = qjs.JS_Call(self.ctx, pc.resolve, js.js_undefined(), 1, &args);
        qjs.JS_FreeValue(self.ctx, ret);
        self.drain_jobs();
    }

    pub fn reject_pending(self: *WorkerState, id: u64, reason: []const u8) void {
        defer gpa.free(reason);
        const kv = self.pending_calls.fetchRemove(id) orelse return;
        const pc = kv.value;
        defer qjs.JS_FreeValue(self.ctx, pc.resolve);
        defer qjs.JS_FreeValue(self.ctx, pc.reject);

        const val = qjs.JS_NewStringLen(self.ctx, reason.ptr, reason.len);
        defer qjs.JS_FreeValue(self.ctx, val);

        var args = [_]qjs.JSValue{val};
        const ret = qjs.JS_Call(self.ctx, pc.reject, js.js_undefined(), 1, &args);
        qjs.JS_FreeValue(self.ctx, ret);
        self.drain_jobs();
    }

    pub fn do_eval(self: *WorkerState, code: []const u8, result: *types.Result) void {
        const code_z = gpa.dupeZ(u8, code) catch {
            result.ok = false;
            result.json = "Out of memory";
            return;
        };
        defer gpa.free(code_z);

        var flags: c_int = qjs.JS_EVAL_TYPE_GLOBAL;
        if (std.mem.indexOf(u8, code, "await") != null) {
            flags |= qjs.JS_EVAL_FLAG_ASYNC;
        }
        const val = qjs.JS_Eval(self.ctx, code_z.ptr, code.len, "<eval>", flags);
        defer qjs.JS_FreeValue(self.ctx, val);
        self.drain_jobs();

        if (js.js_is_exception(val)) {
            self.set_error_term(result);
            return;
        }

        if (js.is_promise(self.ctx, val)) {
            self.await_promise(val, result, flags & qjs.JS_EVAL_FLAG_ASYNC != 0);
            return;
        }

        self.set_ok_term(val, result);
    }

    pub fn do_call(self: *WorkerState, name: []const u8, args_json: []const u8, result: *types.Result) void {
        const call_code = std.fmt.bufPrint(&self.buf, "(function() {{ return {s}.apply(null, {s}); }})()", .{ name, args_json }) catch {
            result.ok = false;
            result.json = "Call expression too long";
            return;
        };

        const val = qjs.JS_Eval(self.ctx, call_code.ptr, call_code.len, "<call>", qjs.JS_EVAL_TYPE_GLOBAL);
        defer qjs.JS_FreeValue(self.ctx, val);
        self.drain_jobs();

        if (js.js_is_exception(val)) {
            self.set_error_term(result);
            return;
        }

        if (js.is_promise(self.ctx, val)) {
            self.await_promise(val, result, false);
            return;
        }

        self.set_ok_term(val, result);
    }

    pub fn do_load_module(self: *WorkerState, name: []const u8, code: []const u8, result: *types.Result) void {
        _ = name;
        const val = qjs.JS_Eval(self.ctx, code.ptr, code.len, "<module>", qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY);
        if (js.js_is_exception(val)) {
            self.set_error_term(result);
            return;
        }

        const eval_result = qjs.JS_EvalFunction(self.ctx, val);
        defer qjs.JS_FreeValue(self.ctx, eval_result);
        self.drain_jobs();

        if (js.js_is_exception(eval_result)) {
            self.set_error_term(result);
            return;
        }

        result.ok = true;
        result.json = "ok";
    }

    pub fn do_reset(self: *WorkerState, result: *types.Result) void {
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

    fn await_promise(self: *WorkerState, promise: qjs.JSValue, result: *types.Result, unwrap_async: bool) void {
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
        const apply_ret = qjs.JS_Call(self.ctx, check_fn, js.js_undefined(), 2, &call_args);
        qjs.JS_FreeValue(self.ctx, apply_ret);
        self.drain_jobs();

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
            const status_str = js.js_to_string(self.ctx, status_val);

            if (std.mem.eql(u8, status_str, "ok")) {
                const v = qjs.JS_GetPropertyStr(self.ctx, global, value_key.ptr);
                defer qjs.JS_FreeValue(self.ctx, v);

                if (unwrap_async and qjs.JS_IsObject(v)) {
                    const inner = qjs.JS_GetPropertyStr(self.ctx, v, "value");
                    defer qjs.JS_FreeValue(self.ctx, inner);
                    self.set_ok_term(inner, result);
                } else {
                    self.set_ok_term(v, result);
                }
                js.cleanup_globals(self.ctx, global, status_key, value_key);
                return;
            } else if (std.mem.eql(u8, status_str, "err")) {
                const v = qjs.JS_GetPropertyStr(self.ctx, global, value_key.ptr);
                defer qjs.JS_FreeValue(self.ctx, v);
                const term_env = beam.alloc_env();
                result.ok = false;
                result.term = js_to_beam.convert_error(self.ctx, v, term_env);
                result.env = term_env;
                js.cleanup_globals(self.ctx, global, status_key, value_key);
                return;
            }

            // Process incoming messages (resolve/reject from beam.call)
            if (types.dequeue(self.rd)) |msg| {
                switch (msg) {
                    .resolve_call => |rc| self.resolve_pending(rc.id, rc.json),
                    .reject_call => |rc| self.reject_pending(rc.id, rc.json),
                    .resolve_call_term => |rc| self.resolve_pending_term(rc.env, rc.term, rc.id),
                    .stop => {
                        result.ok = false;
                        result.json = "Runtime stopped";
                        return;
                    },
                    else => {},
                }
            }

            // Fire expired timers (setTimeout/setInterval callbacks)
            self.fire_expired_timers();
            self.drain_jobs();

            // Sleep until next timer or a short polling interval
            const timer_ns = self.next_timer_timeout_ns();
            const sleep_ns: u64 = if (timer_ns) |t| @min(t, 1_000_000) else 1_000_000;
            std.Thread.sleep(sleep_ns);
        }

        result.ok = false;
        result.json = "Promise resolution timeout";
    }

    fn set_ok_term(self: *WorkerState, val: qjs.JSValue, result: *types.Result) void {
        const term_env = beam.alloc_env();
        result.ok = true;
        result.term = js_to_beam.convert(self.ctx, val, term_env);
        result.env = term_env;
    }

    fn set_error_term(self: *WorkerState, result: *types.Result) void {
        const exc = qjs.JS_GetException(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, exc);

        const term_env = beam.alloc_env();
        result.ok = false;
        result.term = js_to_beam.convert_error(self.ctx, exc, term_env);
        result.env = term_env;
    }

    pub fn install_globals(self: *WorkerState) void {
        qjs.JS_SetContextOpaque(self.ctx, @ptrCast(self));
        globals.install_all(self.ctx);
    }
};

pub fn worker_main(rd: *types.RuntimeData, owner_pid: beam.pid) void {
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
        .start_time = std.time.nanoTimestamp(),
    };
    defer state.deinit();

    state.install_globals();

    while (true) {
        const timeout = state.next_timer_timeout_ns();
        const msg = if (timeout != null and timeout.? == 0)
            types.dequeue(rd)
        else
            types.dequeue_blocking(rd, timeout orelse null);

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
                .resolve_call_term => |rc| state.resolve_pending_term(rc.env, rc.term, rc.id),
                .send_message => |sm| gpa.free(sm.data),
                .memory_usage => |mu| {
                    // SAFETY: immediately filled by JS_ComputeMemoryUsage
                    var usage: qjs.JSMemoryUsage = undefined;
                    qjs.JS_ComputeMemoryUsage(state.rt, &usage);
                    mu.malloc_size = usage.malloc_size;
                    mu.malloc_count = usage.malloc_count;
                    mu.memory_used_size = usage.memory_used_size;
                    mu.atom_count = usage.atom_count;
                    mu.str_count = usage.str_count;
                    mu.obj_count = usage.obj_count;
                    mu.prop_count = usage.prop_count;
                    mu.shape_count = usage.shape_count;
                    mu.js_func_count = usage.js_func_count;
                    mu.c_func_count = usage.c_func_count;
                    mu.array_count = usage.array_count;
                    mu.done.?.set();
                },
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
