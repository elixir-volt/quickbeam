const types = @import("types.zig");
const js = @import("js_helpers.zig");
const globals = @import("globals.zig");
const js_to_beam = @import("js_to_beam.zig");
const beam_to_js = @import("beam_to_js.zig");
const beam_proxy = @import("beam_proxy.zig");
const dom = @import("dom.zig");
const wasm_js = @import("wasm_js.zig");
const napi_mod = @import("napi.zig");
const nt = @import("napi_types.zig");
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
    napi_env: ?*napi_mod.NapiEnv = null,
    max_reductions: i64 = 0,

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

        // Release napi JS refs, then free context, then free napi Zig memory
        if (self.napi_env) |nenv| nenv.releaseValues();
        self.atoms.deinit(self.ctx);

        wasm_js.destroy_context(self.ctx);

        // Run GC before freeing context to collect cycles
        qjs.JS_RunGC(self.rt);
        qjs.JS_FreeContext(self.ctx);

        if (self.napi_env) |nenv| {
            nenv.deinit();
            gpa.destroy(nenv);
            self.napi_env = null;
        }
    }

    pub fn drain_jobs(self: *WorkerState) void {
        var pctx: ?*qjs.JSContext = null;
        while (true) {
            const ret = qjs.JS_ExecutePendingJob(self.rt, &pctx);
            if (ret <= 0) break;
        }
    }

    fn drain_jobs_or_set_error(self: *WorkerState, result: *Result) bool {
        var pctx: ?*qjs.JSContext = null;
        var had_error = false;
        while (true) {
            const ret = qjs.JS_ExecutePendingJob(self.rt, &pctx);
            if (ret > 0) continue;
            if (ret < 0) {
                if (!had_error) {
                    self.set_error_term_from_ctx(pctx orelse self.ctx, result);
                    had_error = true;
                } else {
                    const exc = qjs.JS_GetException(pctx orelse self.ctx);
                    qjs.JS_FreeValue(pctx orelse self.ctx, exc);
                }
                continue;
            }
            break;
        }
        return !had_error;
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
        const result_term = js_to_beam.convert_with_limits(self.ctx, val, result_env, self.convert_limits());

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
            const empty = beam.make_empty_list(.{ .env = renv }).v;
            types.send_reply(lg.caller_pid, lg.ref_env, lg.ref_term, true, renv, empty, "");
            return;
        }

        const result_env = e.enif_alloc_env();
        var list = beam.make_empty_list(.{ .env = result_env }).v;

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
                // SAFETY: enif_alloc_binary initializes bin on success before it is read.
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

        if (!self.drain_jobs_or_set_error(result)) {
            return;
        }

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

        if (!self.drain_jobs_or_set_error(result)) {
            return;
        }

        if (js.js_is_exception(eval_result)) {
            self.set_error_term(result);
            return;
        }

        if (js.is_promise(self.ctx, eval_result)) {
            self.await_promise(eval_result, result, false);
            if (!result.ok) return;
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

        if (self.napi_env) |nenv| {
            nenv.releaseValues();
            nenv.deinit();
            gpa.destroy(nenv);
            self.napi_env = null;
        }
        self.atoms.deinit(self.ctx);
        wasm_js.destroy_context(self.ctx);
        qjs.JS_RunGC(self.rt);
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
                result.term = js_to_beam.convert_error_with_limits(self.ctx, v, term_env, self.convert_limits());
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
                    .call_fn_sync => |p| {
                        var nested_result: Result = .{};
                        self.set_deadline(p.timeout_ns);
                        self.do_call(p.name, p.args_env, p.args_term, &nested_result);
                        self.clear_deadline();
                        self.complete_sync_call(p.id, &nested_result);
                        gpa.free(p.name);
                    },
                    .send_message => |sm| self.deliver_message(sm),
                    .define_global => |sg| self.define_global_property(sg),
                    .get_global => |gg| self.get_global_property(gg),
                    .delete_globals => |dg| self.delete_global_names(dg),
                    .snapshot_globals => self.snapshot_globals(),
                    .list_globals => |lg| self.list_globals(lg),
                    .napi_async_complete => |p| {
                        if (p.work.complete) |complete| {
                            const ns: nt.napi_status = if (p.work.status.load(.seq_cst) == .cancelled)
                                @intFromEnum(nt.Status.cancelled)
                            else
                                @intFromEnum(nt.Status.ok);
                            complete(p.work.env, ns, p.work.data);
                        }
                    },
                    .napi_tsfn_call => |p| {
                        const tsfn = p.tsfn;
                        if (tsfn.call_js_cb) |cb| {
                            const napi_val: napi_mod.napi_value = if (tsfn.callback) |c| blk: {
                                const slot = gpa.create(qjs.JSValue) catch break :blk null;
                                slot.* = c;
                                break :blk slot;
                            } else null;
                            cb(tsfn.env, napi_val, tsfn.ctx, p.data);
                        } else if (tsfn.callback) |cb| {
                            const ret = qjs.JS_Call(self.ctx, cb, js.js_undefined(), 0, null);
                            qjs.JS_FreeValue(self.ctx, ret);
                        }
                    },
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
        result.term = js_to_beam.convert_with_limits(self.ctx, val, term_env, self.convert_limits());
        result.env = term_env;
    }

    fn set_error_term(self: *WorkerState, result: *Result) void {
        self.set_error_term_from_ctx(self.ctx, result);
    }

    fn complete_sync_call(self: *WorkerState, id: u64, result: *Result) void {
        self.rd.sync_slots_mutex.lock();
        const slot = self.rd.sync_slots.get(id);
        self.rd.sync_slots_mutex.unlock();

        if (slot) |sync_slot| {
            sync_slot.ok = result.ok;
            sync_slot.result_json = result.json;
            sync_slot.result_env = result.env;
            sync_slot.result_term = if (result.env != null) result.term else null;
            sync_slot.done.set();
        } else if (result.env) |term_env| {
            beam.free_env(term_env);
        }
    }

    fn set_error_term_from_ctx(self: *WorkerState, ctx: *qjs.JSContext, result: *Result) void {
        const exc = qjs.JS_GetException(ctx);
        defer qjs.JS_FreeValue(ctx, exc);

        const term_env = beam.alloc_env();
        result.ok = false;
        result.term = js_to_beam.convert_error_with_limits(ctx, exc, term_env, self.convert_limits());
        result.env = term_env;
    }

    fn convert_limits(self: *WorkerState) js_to_beam.ConvertLimits {
        return .{
            .max_depth = self.rd.max_convert_depth,
            .max_nodes = self.rd.max_convert_nodes,
        };
    }

    fn ensureNapiSymbolsGlobal() void {
        const promoted = struct {
            var done: bool = false;
        };
        if (promoted.done) return;
        promoted.done = true;

        // On Linux, addons loaded via dlopen need N-API symbols from the NIF
        // to be globally visible. Re-open our own .so with RTLD_GLOBAL to
        // promote the exported napi_* symbols into the global symbol table.
        if (comptime @import("builtin").os.tag == .linux) {
            const DlInfo = extern struct {
                dli_fname: [*c]const u8,
                dli_fbase: ?*anyopaque,
                dli_sname: [*c]const u8,
                dli_saddr: ?*anyopaque,
            };
            const RTLD_LAZY = 0x00001;
            const RTLD_GLOBAL = 0x00100;
            const RTLD_NOLOAD = 0x00004;
            const dladdr = @extern(*const fn (?*const anyopaque, *DlInfo) callconv(.c) c_int, .{ .name = "dladdr" });
            const dlopen_fn = @extern(*const fn (?[*:0]const u8, c_int) callconv(.c) ?*anyopaque, .{ .name = "dlopen" });
            // SAFETY: dladdr initializes info on success before it is read.
            var info: DlInfo = undefined;
            if (dladdr(@ptrCast(&napi_mod.napi_module_register), &info) != 0) {
                _ = dlopen_fn(info.dli_fname, RTLD_LAZY | RTLD_GLOBAL | RTLD_NOLOAD);
            }
        }
    }

    pub fn do_load_addon(self: *WorkerState, path: [:0]const u8, global_name: ?[:0]const u8, result: *Result) void {
        ensureNapiSymbolsGlobal();

        if (self.napi_env == null) {
            self.napi_env = napi_mod.createEnvWithRd(self.ctx, self.rt, self.rd);
        }
        const env = self.napi_env.?;

        napi_mod.clearPendingModule();

        const lib = gpa.create(std.DynLib) catch {
            result.ok = false;
            result.json = "OOM";
            return;
        };
        lib.* = std.DynLib.openZ(path) catch {
            gpa.destroy(lib);
            result.ok = false;
            result.json = "Failed to dlopen addon";
            return;
        };

        const exports = qjs.JS_NewObject(self.ctx);
        const exports_slot = gpa.create(qjs.JSValue) catch {
            qjs.JS_FreeValue(self.ctx, exports);
            result.ok = false;
            result.json = "OOM";
            return;
        };
        exports_slot.* = exports;
        defer gpa.destroy(exports_slot);

        var final_exports: qjs.JSValue = exports;

        // Check if napi_module_register was called during dlopen (static constructor)
        if (napi_mod.getPendingModule()) |mod| {
            napi_mod.clearPendingModule();
            if (mod.nm_register_func) |register| {
                const ret_val = register(env, exports_slot);
                self.drain_jobs();
                if (ret_val) |rv| final_exports = rv.*;
            }
        } else {
            // Try looking up napi_register_module_v1
            if (lib.lookup(*const fn (napi_mod.napi_env, napi_mod.napi_value) callconv(.c) napi_mod.napi_value, "napi_register_module_v1")) |init_fn| {
                const ret_val = init_fn(env, exports_slot);
                self.drain_jobs();
                if (ret_val) |rv| final_exports = rv.*;
            } else {
                qjs.JS_FreeValue(self.ctx, exports);
                result.ok = false;
                result.json = "Addon has no napi_module_register or napi_register_module_v1";
                return;
            }
        }

        // Set exports as a global JS variable if a name was provided
        if (global_name) |gn| {
            const g = qjs.JS_GetGlobalObject(self.ctx);
            defer qjs.JS_FreeValue(self.ctx, g);
            _ = qjs.JS_SetPropertyStr(self.ctx, g, gn.ptr, qjs.JS_DupValue(self.ctx, final_exports));
            // Track the atom so we can delete it during cleanup
            const atom = qjs.JS_NewAtom(self.ctx, gn.ptr);
            env.addon_globals.append(gpa, atom) catch {
                qjs.JS_FreeAtom(self.ctx, atom);
            };
        }

        const result_env = beam.alloc_env();
        result.ok = true;
        result.term = js_to_beam.convert_with_limits(self.ctx, final_exports, result_env, self.convert_limits());
        result.env = result_env;

        // Free our reference to exports
        qjs.JS_FreeValue(self.ctx, exports);
        if (final_exports.tag != exports.tag or qjs.JS_VALUE_GET_PTR(final_exports) != qjs.JS_VALUE_GET_PTR(exports)) {
            qjs.JS_FreeValue(self.ctx, final_exports);
        }
        // These are standalone DupValue'd slots that need cleanup
        env.clearPendingException();
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

        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);
        wasm_js.install(self.ctx, global, self.max_reductions);
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
    napi_mod.initRuntime(rt);

    const ctx = qjs.JS_NewContext(rt) orelse return;

    var state = WorkerState{
        .ctx = ctx,
        .rt = rt,
        .owner_pid = owner_pid,
        .rd = rd,
        .pending_calls = std.AutoHashMap(u64, PendingCall).init(gpa),
        .timers = std.AutoHashMap(u64, TimerEntry).init(gpa),
        .start_time = std.time.nanoTimestamp(),
        .max_reductions = 0,
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
                .call_fn_sync => |p| {
                    var result = Result{};
                    state.set_deadline(p.timeout_ns);
                    state.do_call(p.name, p.args_env, p.args_term, &result);
                    state.clear_deadline();
                    state.complete_sync_call(p.id, &result);
                    gpa.free(p.name);
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
                    // SAFETY: JS_ComputeMemoryUsage fully initializes usage before it is read.
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
                .napi_async_complete => |p| {
                    const work = p.work;
                    if (work.complete) |complete| {
                        const napi_status: nt.napi_status = if (work.status.load(.seq_cst) == .cancelled)
                            @intFromEnum(nt.Status.cancelled)
                        else
                            @intFromEnum(nt.Status.ok);
                        complete(work.env, napi_status, work.data);
                    }
                    work.deinit();
                },
                .napi_tsfn_call => |p| {
                    const tsfn = p.tsfn;

                    tsfn.lock.lock();
                    if (tsfn.queue.items.len == 0) {
                        const should_finalize = tsfn.closing.load(.seq_cst) and !tsfn.finalized.load(.seq_cst);
                        tsfn.lock.unlock();
                        if (should_finalize and tsfn.finalized.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
                            if (tsfn.finalize_cb) |cb| cb(tsfn.env, tsfn.ctx, null);
                            tsfn.deinit();
                        }
                        break;
                    }

                    const data = tsfn.queue.orderedRemove(0);
                    tsfn.condvar.signal();
                    const should_finalize_after = tsfn.closing.load(.seq_cst) and tsfn.queue.items.len == 0 and !tsfn.finalized.load(.seq_cst);
                    tsfn.lock.unlock();

                    if (tsfn.call_js_cb) |cb| {
                        const napi_val: napi_mod.napi_value = if (tsfn.callback) |c| blk: {
                            const slot = gpa.create(qjs.JSValue) catch break :blk null;
                            slot.* = c;
                            break :blk slot;
                        } else null;
                        cb(tsfn.env, napi_val, tsfn.ctx, data);
                        if (napi_val) |slot| gpa.destroy(slot);
                    } else if (tsfn.callback) |cb| {
                        const ret = qjs.JS_Call(state.ctx, cb, js.js_undefined(), 0, null);
                        qjs.JS_FreeValue(state.ctx, ret);
                    }

                    if (should_finalize_after and tsfn.finalized.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
                        if (tsfn.finalize_cb) |cb| cb(tsfn.env, tsfn.ctx, null);
                        tsfn.deinit();
                    }
                },
                .load_addon => |p| {
                    var result = Result{};
                    state.do_load_addon(p.path, p.global_name, &result);
                    gpa.free(p.path);
                    if (p.global_name) |gn| gpa.free(gn);
                    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
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

fn parse_i64_term(env: *e.ErlNifEnv, term: beam.term) !i64 {
    var value: i64 = 0;
    if (e.enif_get_int64(env, term.v, &value) != 0) {
        return value;
    }

    const value_str = beam.get([]const u8, term, .{}) catch return error.BadArg;
    return std.fmt.parseInt(i64, value_str, 10) catch error.BadArg;
}

fn parse_f64_term(env: *e.ErlNifEnv, term: beam.term) !f64 {
    var value: f64 = 0;
    if (e.enif_get_double(env, term.v, &value) != 0) {
        return value;
    }

    const int_value = try parse_i64_term(env, term);
    return @floatFromInt(int_value);
}

fn build_host_args_term(env: *e.ErlNifEnv, signature: []const u8, raw_args: [*]u64) !e.ErlNifTerm {
    const close_idx = std.mem.indexOfScalar(u8, signature, ')') orelse return error.BadArg;

    var list = beam.make_empty_list(.{ .env = env }).v;
    var i = close_idx;
    while (i > 1) {
        i -= 1;
        const sig = signature[i];
        const raw = raw_args[i - 1];
        const term = switch (sig) {
            'i' => beam.make(@as(i32, @bitCast(@as(u32, @truncate(raw)))), .{ .env = env }).v,
            'I' => blk: {
                var buf: [32]u8 = undefined;
                const rendered = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @bitCast(raw))}) catch return error.BadArg;
                break :blk beam.make(rendered, .{ .env = env }).v;
            },
            'f' => beam.make(@as(f64, @floatCast(@as(f32, @bitCast(@as(u32, @truncate(raw)))))), .{ .env = env }).v,
            'F' => beam.make(@as(f64, @bitCast(raw)), .{ .env = env }).v,
            else => return error.UnsupportedType,
        };
        list = beam.make_list_cell(beam.term{ .v = term }, beam.term{ .v = list }, .{ .env = env }).v;
    }

    return list;
}

fn write_host_result(env: *e.ErlNifEnv, term: e.ErlNifTerm, signature: []const u8, raw_args: [*]u64) !void {
    const close_idx = std.mem.indexOfScalar(u8, signature, ')') orelse return error.BadArg;
    if (close_idx + 1 >= signature.len) return;

    switch (signature[close_idx + 1]) {
        'i' => {
            const value = try parse_i64_term(env, .{ .v = term });
            raw_args[0] = @as(u64, @as(u32, @bitCast(@as(i32, @intCast(value)))));
        },
        'I' => {
            const value = try parse_i64_term(env, .{ .v = term });
            raw_args[0] = @bitCast(value);
        },
        'f' => {
            const value = try parse_f64_term(env, .{ .v = term });
            raw_args[0] = @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(value)))));
        },
        'F' => {
            const value = try parse_f64_term(env, .{ .v = term });
            raw_args[0] = @bitCast(value);
        },
        else => return error.UnsupportedType,
    }
}

fn copy_error_buf(err_buf: [*]u8, err_buf_size: u32, msg: []const u8) void {
    if (err_buf_size == 0) return;
    const copy_len = @min(msg.len, err_buf_size - 1);
    std.mem.copyForwards(u8, err_buf[0..copy_len], msg[0..copy_len]);
    err_buf[copy_len] = 0;
}

pub fn quickbeam_wasm_host_invoke_js_impl(runtime_data: ?*anyopaque, callback_name_z: [*:0]const u8, signature_z: [*:0]const u8, raw_args: [*]u64, err_buf: [*]u8, err_buf_size: u32) bool {
    const ctx_ptr = runtime_data orelse {
        copy_error_buf(err_buf, err_buf_size, "context not available");
        return false;
    };

    const ctx: *qjs.JSContext = @ptrCast(@alignCast(ctx_ptr));
    const self: *WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));
    const callback_name = std.mem.span(callback_name_z);
    const signature = std.mem.span(signature_z);

    const args_env = beam.alloc_env() orelse {
        copy_error_buf(err_buf, err_buf_size, "out of memory");
        return false;
    };
    const args_term = build_host_args_term(args_env, signature, raw_args) catch {
        beam.free_env(args_env);
        copy_error_buf(err_buf, err_buf_size, "invalid host import args");
        return false;
    };

    var result: Result = .{};
    self.do_call(callback_name, args_env, args_term, &result);

    if (!result.ok) {
        if (result.env) |result_env| {
            defer beam.free_env(result_env);
            if (result.term) |term| {
                // SAFETY: `enif_inspect_binary` initializes `bin` on success before it is read.
                var bin: e.ErlNifBinary = undefined;
                if (e.enif_inspect_binary(result_env, term, &bin) != 0 and bin.size > 0) {
                    copy_error_buf(err_buf, err_buf_size, bin.data[0..bin.size]);
                    return false;
                }
            }
        }

        if (result.json.len > 0) {
            copy_error_buf(err_buf, err_buf_size, result.json);
        } else {
            copy_error_buf(err_buf, err_buf_size, "host import callback failed");
        }
        return false;
    }

    if (result.env) |result_env| {
        defer beam.free_env(result_env);
        if (result.term) |term| {
            write_host_result(result_env, term, signature, raw_args) catch {
                copy_error_buf(err_buf, err_buf_size, "invalid host import return value");
                return false;
            };
            return true;
        }
    }

    copy_error_buf(err_buf, err_buf_size, "host import callback returned no result");
    return false;
}
