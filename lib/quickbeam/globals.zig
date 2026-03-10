const types = @import("types.zig");
const worker = @import("worker.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;

// ──────────────────── beam.call ────────────────────

pub fn install_beam_object(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const beam_obj = qjs.JS_NewObject(ctx);
    const call_fn = qjs.JS_NewCFunction(ctx, &beam_call_impl, "call", 1);
    const call_sync_fn = qjs.JS_NewCFunction(ctx, &beam_call_sync_impl, "callSync", 1);
    _ = qjs.JS_SetPropertyStr(ctx, beam_obj, "call", call_fn);
    _ = qjs.JS_SetPropertyStr(ctx, beam_obj, "callSync", call_sync_fn);
    _ = qjs.JS_SetPropertyStr(ctx, global, "beam", beam_obj);
}

fn beam_call_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "beam.call requires a handler name");

    const name_ptr = qjs.JS_ToCString(ctx, argv[0]) orelse
        return qjs.JS_ThrowTypeError(ctx, "beam.call: first argument must be a string");
    const name = std.mem.span(name_ptr);

    var args_json: []const u8 = "[]";
    var args_alloc = false;
    if (argc > 1) {
        const arr = qjs.JS_NewArray(ctx);
        var i: c_int = 1;
        while (i < argc) : (i += 1) {
            _ = qjs.JS_SetPropertyUint32(ctx, arr, @intCast(i - 1), qjs.JS_DupValue(ctx, argv[@intCast(i)]));
        }
        args_json = js.js_to_json(ctx.?, arr);
        args_alloc = true;
        qjs.JS_FreeValue(ctx, arr);
    }

    var resolve_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx, &resolve_funcs);
    if (js.js_is_exception(promise)) {
        qjs.JS_FreeCString(ctx, name_ptr);
        return js.js_exception();
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

// ──────────────────── beam.callSync ────────────────────

fn beam_call_sync_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "beam.callSync requires a handler name");

    const name_ptr = qjs.JS_ToCString(ctx, argv[0]) orelse
        return qjs.JS_ThrowTypeError(ctx, "beam.callSync: first argument must be a string");
    const name = std.mem.span(name_ptr);

    var args_json: []const u8 = "[]";
    var args_alloc = false;
    if (argc > 1) {
        const arr = qjs.JS_NewArray(ctx);
        var i: c_int = 1;
        while (i < argc) : (i += 1) {
            _ = qjs.JS_SetPropertyUint32(ctx, arr, @intCast(i - 1), qjs.JS_DupValue(ctx, argv[@intCast(i)]));
        }
        args_json = js.js_to_json(ctx.?, arr);
        args_alloc = true;
        qjs.JS_FreeValue(ctx, arr);
    }

    const call_id = self.next_call_id;
    self.next_call_id += 1;

    // Register sync slot so resolve_call NIF writes directly to it
    var slot = types.SyncCallSlot{};
    self.rd.sync_slots_mutex.lock();
    self.rd.sync_slots.put(gpa, call_id, &slot) catch {
        self.rd.sync_slots_mutex.unlock();
        qjs.JS_FreeCString(ctx, name_ptr);
        if (args_alloc) gpa.free(args_json);
        return qjs.JS_ThrowOutOfMemory(ctx);
    };
    self.rd.sync_slots_mutex.unlock();

    // Send the call to the GenServer (same message format as async)
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

    // Block until response arrives
    slot.done.wait();

    // Clean up slot
    self.rd.sync_slots_mutex.lock();
    _ = self.rd.sync_slots.remove(call_id);
    self.rd.sync_slots_mutex.unlock();

    defer if (slot.result_json.len > 0) gpa.free(slot.result_json);

    if (slot.ok) {
        if (slot.result_json.len == 0) return js.js_null();
        const code_z = gpa.dupeZ(u8, slot.result_json) catch return js.js_null();
        defer gpa.free(code_z);
        const parsed = qjs.JS_ParseJSON(ctx, code_z.ptr, slot.result_json.len, "<sync>");
        if (js.js_is_exception(parsed)) {
            const exc = qjs.JS_GetException(ctx);
            qjs.JS_FreeValue(ctx, exc);
            return js.js_null();
        }
        return parsed;
    } else {
        const err_msg = gpa.dupeZ(u8, slot.result_json) catch return qjs.JS_ThrowInternalError(ctx, "beam.callSync failed");
        defer gpa.free(err_msg);
        return qjs.JS_ThrowInternalError(ctx, err_msg.ptr);
    }
}

// ──────────────────── Timers ────────────────────

pub fn install_timers(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const set_timeout = qjs.JS_NewCFunction(ctx, &set_timeout_impl, "setTimeout", 2);
    _ = qjs.JS_SetPropertyStr(ctx, global, "setTimeout", set_timeout);

    const set_interval = qjs.JS_NewCFunction(ctx, &set_interval_impl, "setInterval", 2);
    _ = qjs.JS_SetPropertyStr(ctx, global, "setInterval", set_interval);

    const clear_fn = qjs.JS_NewCFunction(ctx, &clear_timer_impl, "clearTimeout", 1);
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearTimeout", qjs.JS_DupValue(ctx, clear_fn));
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearInterval", clear_fn);
}

fn set_timeout_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return set_timer_common(ctx, argc, argv, false);
}

fn set_interval_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return set_timer_common(ctx, argc, argv, true);
}

fn set_timer_common(ctx: ?*qjs.JSContext, argc: c_int, argv: [*c]qjs.JSValue, is_interval: bool) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

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

    self.rd.cond.signal();

    return qjs.JS_NewFloat64(ctx, @floatFromInt(id));
}

fn clear_timer_impl(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1) return js.js_undefined();

    var id_f: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx, &id_f, argv[0]);
    const id: u64 = @intFromFloat(id_f);

    if (self.timers.fetchRemove(id)) |kv| {
        qjs.JS_FreeValue(ctx, kv.value.callback);
    }

    return js.js_undefined();
}

// ──────────────────── Console ────────────────────

pub fn install_console(ctx: *qjs.JSContext, global: qjs.JSValue) void {
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

// ──────────────────── BEAM term helpers ────────────────────

fn make_atom(env: ?*e.ErlNifEnv, name: []const u8) e.ErlNifTerm {
    return e.enif_make_atom_len(env, name.ptr, name.len);
}

fn make_binary_term(env: ?*e.ErlNifEnv, data: []const u8) e.ErlNifTerm {
    // SAFETY: immediately initialized by enif_alloc_binary below
    var bin: e.ErlNifBinary = undefined;
    _ = e.enif_alloc_binary(data.len, &bin);
    @memcpy(bin.data[0..data.len], data);
    return e.enif_make_binary(env, &bin);
}
