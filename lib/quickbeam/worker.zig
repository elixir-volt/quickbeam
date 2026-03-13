const types = @import("types.zig");
const js = @import("js_helpers.zig");
const globals = @import("globals.zig");
const js_to_beam = @import("js_to_beam.zig");
const beam_to_js = @import("beam_to_js.zig");
const beam_proxy = @import("beam_proxy.zig");
const dom = @import("dom.zig");
pub const atom_cache = @import("atom_cache.zig");
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;

pub const Result = struct {
    ok: bool = false,
    json: []const u8 = "",
    env: ?*e.ErlNifEnv = null,
    term: ?e.ErlNifTerm = null,
};

pub const PendingCall = struct {
    resolve: qjs.JSValue,
    reject: qjs.JSValue,
};

pub const TimerEntry = struct {
    callback: qjs.JSValue,
    deadline: i128,
    interval_ns: ?u64,
};

pub const DrainFn = *const fn (*WorkerState) void;

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
    message_handler: qjs.JSValue = js.JS_UNDEFINED,
    atoms: atom_cache.AtomCache = .{},
    dom_data: ?*dom.DocumentData = null,
    builtin_snapshot: ?std.StringHashMap(void) = null,
    buf: [4096]u8 = @splat(0),
    drain_fn: ?DrainFn = null,

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

        if (!js.is_undefined(self.message_handler)) {
            qjs.JS_FreeValue(self.ctx, self.message_handler);
        }

        if (self.builtin_snapshot) |*snap| {
            var kit = snap.keyIterator();
            while (kit.next()) |k| types.gpa.free(k.*);
            snap.deinit();
        }

        self.atoms.deinit(self.ctx);
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

    pub fn define_global_property(self: *WorkerState, sg: types.SetGlobalPayload) void {
        const env = sg.env orelse return;
        defer beam.free_env(env);
        defer types.gpa.free(sg.name);

        const val = beam_to_js.convert(self.ctx, env, sg.term);

        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);
        _ = qjs.JS_SetPropertyStr(self.ctx, global, sg.name.ptr, val);
    }

    pub fn get_global_property(self: *WorkerState, gg: types.GetGlobalPayload) void {
        defer types.gpa.free(gg.name);

        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);
        const val = qjs.JS_GetPropertyStr(self.ctx, global, gg.name.ptr);
        defer qjs.JS_FreeValue(self.ctx, val);

        const result_env = beam.alloc_env();
        const result_term = js_to_beam.convert(self.ctx, val, result_env);

        types.send_reply(gg.caller_pid, gg.ref_env, gg.ref_term, true, result_env, result_term, "");
    }

    pub fn snapshot_globals(self: *WorkerState) void {
        if (self.builtin_snapshot) |*old| {
            var kit = old.keyIterator();
            while (kit.next()) |k| types.gpa.free(k.*);
            old.deinit();
        }

        var snap = std.StringHashMap(void).init(types.gpa);
        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);

        var ptab: [*c]qjs.JSPropertyEnum = null;
        var plen: u32 = 0;
        if (qjs.JS_GetOwnPropertyNames(self.ctx, &ptab, &plen, global, qjs.JS_GPN_STRING_MASK) < 0) return;
        defer {
            for (0..plen) |i| qjs.JS_FreeAtom(self.ctx, ptab[i].atom);
            qjs.js_free(self.ctx, ptab);
        }

        for (0..plen) |i| {
            const cstr = qjs.JS_AtomToCString(self.ctx, ptab[i].atom);
            if (cstr == null) continue;
            defer qjs.JS_FreeCString(self.ctx, cstr);
            const name = std.mem.span(cstr);
            const duped = types.gpa.dupe(u8, name) catch continue;
            snap.put(duped, {}) catch {
                types.gpa.free(duped);
            };
        }

        self.builtin_snapshot = snap;
    }

    pub fn list_globals(self: *WorkerState, lg: types.ListGlobalsPayload) void {
        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);

        var ptab: [*c]qjs.JSPropertyEnum = null;
        var plen: u32 = 0;
        if (qjs.JS_GetOwnPropertyNames(self.ctx, &ptab, &plen, global, qjs.JS_GPN_STRING_MASK) < 0) {
            const renv = e.enif_alloc_env();
            const empty = e.enif_make_list(renv, 0);
            types.send_reply(lg.caller_pid, lg.ref_env, lg.ref_term, true, renv, empty, "");
            return;
        }

        const result_env = e.enif_alloc_env();
        var list = e.enif_make_list(result_env, 0);

        var i: usize = plen;
        while (i > 0) {
            i -= 1;
            const cstr = qjs.JS_AtomToCString(self.ctx, ptab[i].atom);
            if (cstr == null) continue;
            const name_slice = std.mem.span(cstr);
            const name_len = name_slice.len;

            var skip = false;
            if (lg.user_only) {
                if (name_len >= 5 and std.mem.eql(u8, name_slice[0..5], "__qb_")) skip = true;
                if (!skip) {
                    if (self.builtin_snapshot) |snap| {
                        if (snap.contains(name_slice)) skip = true;
                    }
                }
            }

            if (!skip) {
                var bin: e.ErlNifBinary = undefined;
                if (e.enif_alloc_binary(name_len, &bin) != 0) {
                    @memcpy(bin.data[0..name_len], name_slice[0..name_len]);
                    const name_term = e.enif_make_binary(result_env, &bin);
                    list = e.enif_make_list_cell(result_env, name_term, list);
                }
            }

            qjs.JS_FreeCString(self.ctx, cstr);
        }

        for (0..plen) |j| qjs.JS_FreeAtom(self.ctx, ptab[j].atom);
        qjs.js_free(self.ctx, ptab);

        types.send_reply(lg.caller_pid, lg.ref_env, lg.ref_term, true, result_env, list, "");
    }

    pub fn delete_global_names(self: *WorkerState, dg: types.DeleteGlobalsPayload) void {
        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);

        for (dg.names) |name| {
            const atom = qjs.JS_NewAtomLen(self.ctx, name.ptr, name.len);
            defer qjs.JS_FreeAtom(self.ctx, atom);
            _ = qjs.JS_DeleteProperty(self.ctx, global, atom, 0);
            types.gpa.free(name);
        }
        types.gpa.free(dg.names);
    }

    pub fn deliver_message(self: *WorkerState, sm: types.MessagePayload) void {
        const env = sm.env orelse return;
        defer beam.free_env(env);

        if (js.is_undefined(self.message_handler)) return;

        const val = beam_to_js.convert(self.ctx, env, sm.term);
        defer qjs.JS_FreeValue(self.ctx, val);

        var args = [_]qjs.JSValue{val};
        const ret = qjs.JS_Call(self.ctx, self.message_handler, js.js_undefined(), 1, &args);
        qjs.JS_FreeValue(self.ctx, ret);
        if (js.js_is_exception(ret)) {
            const exc = qjs.JS_GetException(self.ctx);
            qjs.JS_FreeValue(self.ctx, exc);
        }
        self.drain_jobs();
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

    pub fn do_eval(self: *WorkerState, code: []const u8, result: *Result) void {
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

    pub fn do_compile(self: *WorkerState, code: []const u8, result: *Result) void {
        const code_z = gpa.dupeZ(u8, code) catch {
            result.ok = false;
            result.json = "Out of memory";
            return;
        };
        defer gpa.free(code_z);

        const flags: c_int = qjs.JS_EVAL_TYPE_GLOBAL | qjs.JS_EVAL_FLAG_COMPILE_ONLY;
        const func = qjs.JS_Eval(self.ctx, code_z.ptr, code.len, "<compile>", flags);
        defer qjs.JS_FreeValue(self.ctx, func);

        if (js.js_is_exception(func)) {
            self.set_error_term(result);
            return;
        }

        var out_len: usize = 0;
        const buf = qjs.JS_WriteObject(self.ctx, &out_len, func, qjs.JS_WRITE_OBJ_BYTECODE);
        if (buf == null) {
            self.set_error_term(result);
            return;
        }
        defer qjs.js_free(self.ctx, buf);

        const env = beam.alloc_env();
        // SAFETY: out-param written by enif_alloc_binary before use
        var bin: e.ErlNifBinary = undefined;
        _ = e.enif_alloc_binary(out_len, &bin);
        @memcpy(bin.data[0..out_len], buf[0..out_len]);
        result.env = env;
        result.term = e.enif_make_tuple2(env, beam.make_into_atom("bytes", .{ .env = env }).v, e.enif_make_binary(env, &bin));
        result.ok = true;
    }

    pub fn do_load_bytecode(self: *WorkerState, bytecode: []const u8, result: *Result) void {
        const func = qjs.JS_ReadObject(self.ctx, bytecode.ptr, bytecode.len, qjs.JS_READ_OBJ_BYTECODE);
        if (js.js_is_exception(func)) {
            self.set_error_term(result);
            return;
        }

        const val = qjs.JS_EvalFunction(self.ctx, func);
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

    pub fn do_call(self: *WorkerState, name: []const u8, args_env: ?*e.ErlNifEnv, args_term: e.ErlNifTerm, result: *Result) void {
        defer if (args_env) |ae| beam.free_env(ae);

        // Get the function by name
        const name_z = gpa.dupeZ(u8, name) catch {
            result.ok = false;
            result.json = "Out of memory";
            return;
        };
        defer gpa.free(name_z);

        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);
        const func = qjs.JS_GetPropertyStr(self.ctx, global, name_z.ptr);
        defer qjs.JS_FreeValue(self.ctx, func);

        if (!qjs.JS_IsFunction(self.ctx, func)) {
            result.ok = false;
            result.json = "Not a function";
            return;
        }

        // Convert BEAM args list to JS values
        var js_args_buf: [64]qjs.JSValue = undefined;
        var js_argc: usize = 0;

        if (args_env) |ae| {
            var current = args_term;
            while (js_argc < js_args_buf.len) {
                // SAFETY: head_term and tail_term immediately filled by enif_get_list_cell
                var head_term: e.ErlNifTerm = undefined;
                // SAFETY: see above
                var tail_term: e.ErlNifTerm = undefined;
                if (e.enif_get_list_cell(ae, current, &head_term, &tail_term) == 0) break;
                js_args_buf[js_argc] = beam_to_js.convert(self.ctx, ae, head_term);
                js_argc += 1;
                current = tail_term;
            }
        }
        defer for (js_args_buf[0..js_argc]) |v| qjs.JS_FreeValue(self.ctx, v);

        const val = qjs.JS_Call(self.ctx, func, global, @intCast(js_argc), if (js_argc > 0) &js_args_buf else null);
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

    pub fn do_load_module(self: *WorkerState, name: []const u8, code: []const u8, result: *Result) void {
        _ = name;
        const code_z = gpa.dupeZ(u8, code) catch {
            result.ok = false;
            result.json = "Out of memory";
            return;
        };
        defer gpa.free(code_z);

        const val = qjs.JS_Eval(self.ctx, code_z.ptr, code.len, "<module>", qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY);
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

    pub fn do_reset(self: *WorkerState, result: *Result) void {
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

        if (!js.is_undefined(self.message_handler)) {
            qjs.JS_FreeValue(self.ctx, self.message_handler);
            self.message_handler = js.JS_UNDEFINED;
        }

        self.atoms.deinit(self.ctx);
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
        for (0..10000) |_| {
            const state = qjs.JS_PromiseState(self.ctx, promise);

            if (state == qjs.JS_PROMISE_FULFILLED) {
                const v = qjs.JS_PromiseResult(self.ctx, promise);
                defer qjs.JS_FreeValue(self.ctx, v);

                if (unwrap_async and qjs.JS_IsObject(v)) {
                    const inner = qjs.JS_GetPropertyStr(self.ctx, v, "value");
                    defer qjs.JS_FreeValue(self.ctx, inner);
                    self.set_ok_term(inner, result);
                } else {
                    self.set_ok_term(v, result);
                }
                return;
            }

            if (state == qjs.JS_PROMISE_REJECTED) {
                const v = qjs.JS_PromiseResult(self.ctx, promise);
                defer qjs.JS_FreeValue(self.ctx, v);
                const term_env = beam.alloc_env();
                result.ok = false;
                result.term = js_to_beam.convert_error(self.ctx, v, term_env);
                result.env = term_env;
                return;
            }

            // Still pending — process messages that might resolve it
            if (self.drain_fn) |dfn| {
                dfn(self);
            } else if (types.dequeue(self.rd)) |msg| {
                switch (msg) {
                    .resolve_call => |rc| self.resolve_pending(rc.id, rc.json),
                    .reject_call => |rc| self.reject_pending(rc.id, rc.json),
                    .resolve_call_term => |rc| self.resolve_pending_term(rc.env, rc.term, rc.id),
                    .send_message => |sm| self.deliver_message(sm),
                    .define_global => |sg| self.define_global_property(sg),
                    .get_global => |gg| self.get_global_property(gg),
                    .delete_globals => |dg| self.delete_global_names(dg),
                    .snapshot_globals => self.snapshot_globals(),
                    .list_globals => |lg| self.list_globals(lg),
                    .stop => {
                        result.ok = false;
                        result.json = "Runtime stopped";
                        return;
                    },
                    else => {},
                }
            }

            self.fire_expired_timers();
            self.drain_jobs();

            const timer_ns = self.next_timer_timeout_ns();
            const sleep_ns: u64 = if (timer_ns) |t| @min(t, 1_000_000) else 1_000_000;
            std.Thread.sleep(sleep_ns);
        }

        result.ok = false;
        result.json = "Promise resolution timeout";
    }

    fn set_ok_term(self: *WorkerState, val: qjs.JSValue, result: *Result) void {
        const term_env = beam.alloc_env();
        result.ok = true;
        result.term = js_to_beam.convert(self.ctx, val, term_env);
        result.env = term_env;
    }

    fn set_error_term(self: *WorkerState, result: *Result) void {
        const exc = qjs.JS_GetException(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, exc);

        const term_env = beam.alloc_env();
        result.ok = false;
        result.term = js_to_beam.convert_error(self.ctx, exc, term_env);
        result.env = term_env;
    }

    pub fn do_dom_op_result(self: *WorkerState, op: types.DomOp, selector: []const u8, attr_name: []const u8, result: *Result) void {
        const dd = self.dom_data orelse {
            result.ok = false;
            result.json = "No DOM document";
            return;
        };

        const env = beam.alloc_env();
        result.ok = true;
        result.env = env;
        result.term = switch (op) {
            .find => dom.do_dom_query(dd, selector, env),
            .find_all => dom.do_dom_query_all(dd, selector, env),
            .text => dom.do_dom_text(dd, selector, env),
            .attr => dom.do_dom_attr(dd, selector, attr_name, env),
            .html => dom.do_dom_html(dd, env),
        };
    }

    pub fn set_deadline(self: *WorkerState, timeout_ns: u64) void {
        if (timeout_ns > 0) {
            self.rd.deadline = std.time.nanoTimestamp() + @as(i128, timeout_ns);
        }
    }

    pub fn clear_deadline(self: *WorkerState) void {
        self.rd.deadline = null;
    }

    pub fn install_globals(self: *WorkerState) void {
        qjs.JS_SetContextOpaque(self.ctx, @ptrCast(self));
        beam_proxy.initContext(self.ctx);
        self.atoms = atom_cache.AtomCache.init(self.ctx);
        self.dom_data = globals.install_all(self.ctx);
    }
};

fn interrupt_handler(_: ?*qjs.JSRuntime, user_data: ?*anyopaque) callconv(.c) c_int {
    const rd: *types.RuntimeData = @ptrCast(@alignCast(user_data));
    if (rd.deadline) |deadline| {
        if (std.time.nanoTimestamp() > deadline) return 1;
    }
    return 0;
}

pub fn worker_main(rd: *types.RuntimeData, owner_pid: beam.pid) void {
    const rt = qjs.JS_NewRuntime() orelse return;
    defer qjs.JS_FreeRuntime(rt);

    qjs.JS_SetMemoryLimit(rt, rd.memory_limit);
    qjs.JS_SetMaxStackSize(rt, rd.max_stack_size);
    qjs.JS_UpdateStackTop(rt);
    qjs.JS_SetInterruptHandler(rt, &interrupt_handler, @ptrCast(rd));

    types.class_ids_mutex.lock();
    _ = qjs.JS_NewClassID(rt, &beam_proxy.class_id);
    _ = qjs.JS_NewClassID(rt, &dom.document_class_id);
    _ = qjs.JS_NewClassID(rt, &dom.element_class_id);
    types.class_ids_mutex.unlock();

    beam_proxy.initRuntime(rt);

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
                    var result = Result{};
                    state.set_deadline(p.timeout_ns);
                    state.do_eval(p.code, &result);
                    state.clear_deadline();
                    gpa.free(p.code);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
                },
                .compile => |p| {
                    var result = Result{};
                    state.do_compile(p.code, &result);
                    gpa.free(p.code);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
                },
                .call_fn => |p| {
                    var result = Result{};
                    state.set_deadline(p.timeout_ns);
                    state.do_call(p.name, p.args_env, p.args_term, &result);
                    state.clear_deadline();
                    gpa.free(p.name);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
                },
                .load_module => |p| {
                    var result = Result{};
                    state.do_load_module(p.name, p.code, &result);
                    gpa.free(p.name);
                    gpa.free(p.code);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
                },
                .load_bytecode => |p| {
                    var result = Result{};
                    state.do_load_bytecode(p.code, &result);
                    gpa.free(p.code);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
                },
                .reset => |p| {
                    var result = Result{};
                    state.do_reset(&result);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
                },
                .resolve_call => |rc| state.resolve_pending(rc.id, rc.json),
                .reject_call => |rc| state.reject_pending(rc.id, rc.json),
                .resolve_call_term => |rc| state.resolve_pending_term(rc.env, rc.term, rc.id),
                .send_message => |sm| state.deliver_message(sm),
                .define_global => |sg| state.define_global_property(sg),
                .get_global => |gg| state.get_global_property(gg),
                .delete_globals => |dg| state.delete_global_names(dg),
                .snapshot_globals => state.snapshot_globals(),
                .list_globals => |lg| state.list_globals(lg),
                .dom_op => |p| {
                    var result = Result{};
                    state.do_dom_op_result(p.op, p.selector, p.attr_name, &result);
                    gpa.free(p.selector);
                    gpa.free(p.attr_name);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
                },
                .memory_usage => |mu| {
                    var usage: qjs.JSMemoryUsage = undefined;
                    qjs.JS_ComputeMemoryUsage(state.rt, &usage);
                    const renv = beam.alloc_env();
                    const result_term = beam.make(.{
                        .malloc_size = usage.malloc_size,
                        .malloc_count = usage.malloc_count,
                        .memory_used_size = usage.memory_used_size,
                        .atom_count = usage.atom_count,
                        .str_count = usage.str_count,
                        .obj_count = usage.obj_count,
                        .prop_count = usage.prop_count,
                        .shape_count = usage.shape_count,
                        .js_func_count = usage.js_func_count,
                        .c_func_count = usage.c_func_count,
                        .array_count = usage.array_count,
                    }, .{ .env = renv });
                    types.send_reply(mu.caller_pid, mu.ref_env, mu.ref_term, true, renv, result_term.v, "");
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
