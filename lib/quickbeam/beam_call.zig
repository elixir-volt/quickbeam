const types = @import("types.zig");
const worker = @import("worker.zig");
const js = @import("js_helpers.zig");
const beam_to_js = @import("beam_to_js.zig");
const js_to_beam = @import("js_to_beam.zig");
const std = types.std;
const beam = types.beam;
const e = types.e;
const qjs = types.qjs;
const gpa = types.gpa;

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const beam_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, beam_obj, "call", qjs.JS_NewCFunction(ctx, &beam_call_impl, "call", 1));
    _ = qjs.JS_SetPropertyStr(ctx, beam_obj, "callSync", qjs.JS_NewCFunction(ctx, &beam_call_sync_impl, "callSync", 1));
    _ = qjs.JS_SetPropertyStr(ctx, beam_obj, "send", qjs.JS_NewCFunction(ctx, &beam_send_impl, "send", 2));
    _ = qjs.JS_SetPropertyStr(ctx, beam_obj, "self", qjs.JS_NewCFunction(ctx, &beam_self_impl, "self", 0));
    _ = qjs.JS_SetPropertyStr(ctx, global, "beam", beam_obj);

    const process_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, process_obj, "onMessage", qjs.JS_NewCFunction(ctx, &process_on_message_impl, "onMessage", 1));
    _ = qjs.JS_SetPropertyStr(ctx, process_obj, "send", qjs.JS_NewCFunction(ctx, &beam_send_impl, "send", 2));
    _ = qjs.JS_SetPropertyStr(ctx, process_obj, "self", qjs.JS_NewCFunction(ctx, &beam_self_impl, "self", 0));
    _ = qjs.JS_SetPropertyStr(ctx, global, "Process", process_obj);
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

    // SAFETY: resolve_funcs immediately filled by JS_NewPromiseCapability
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

    send_beam_call_term(self, call_id, name, ctx.?, argc, argv);
    qjs.JS_FreeCString(ctx, name_ptr);

    return promise;
}

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

    const call_id = self.next_call_id;
    self.next_call_id += 1;

    var slot = types.SyncCallSlot{};
    self.rd.sync_slots_mutex.lock();
    self.rd.sync_slots.put(gpa, call_id, &slot) catch {
        self.rd.sync_slots_mutex.unlock();
        qjs.JS_FreeCString(ctx, name_ptr);
        return qjs.JS_ThrowOutOfMemory(ctx);
    };
    self.rd.sync_slots_mutex.unlock();

    if (self.rd.shutting_down.load(.acquire)) {
        self.rd.sync_slots_mutex.lock();
        _ = self.rd.sync_slots.remove(call_id);
        self.rd.sync_slots_mutex.unlock();
        qjs.JS_FreeCString(ctx, name_ptr);
        return qjs.JS_ThrowInternalError(ctx, "runtime shutting down");
    }

    send_beam_call_term(self, call_id, name, ctx.?, argc, argv);
    qjs.JS_FreeCString(ctx, name_ptr);

    while (!slot.done.isSet()) {
        if (self.rd.shutting_down.load(.acquire)) {
            self.rd.sync_slots_mutex.lock();
            _ = self.rd.sync_slots.remove(call_id);
            self.rd.sync_slots_mutex.unlock();
            return qjs.JS_ThrowInternalError(ctx, "runtime shutting down");
        }
        slot.done.timedWait(10_000_000) catch {};
    }

    self.rd.sync_slots_mutex.lock();
    _ = self.rd.sync_slots.remove(call_id);
    self.rd.sync_slots_mutex.unlock();

    if (self.rd.shutting_down.load(.acquire)) {
        if (slot.result_env) |env| beam.free_env(env);
        return qjs.JS_ThrowInternalError(ctx, "runtime shutting down");
    }

    if (slot.result_env) |result_env| {
        defer beam.free_env(result_env);
        if (slot.ok) {
            return beam_to_js.convert(ctx.?, result_env, slot.result_term.?);
        } else {
            // Extract error reason string from the term
            // SAFETY: immediately filled by enif_inspect_binary
            var bin: e.ErlNifBinary = undefined;
            if (e.enif_inspect_binary(result_env, slot.result_term.?, &bin) != 0 and bin.size > 0) {
                const msg = gpa.dupeZ(u8, bin.data[0..bin.size]) catch
                    return qjs.JS_ThrowInternalError(ctx, "beam.callSync failed");
                defer gpa.free(msg);
                return qjs.JS_ThrowInternalError(ctx, msg.ptr);
            }
            return qjs.JS_ThrowInternalError(ctx, "beam.callSync failed");
        }
    }

    return qjs.JS_ThrowInternalError(ctx, "beam.callSync: no result received");
}

fn beam_send_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "beam.send requires a pid and a message");

    // First arg must be a PID (passed as an opaque atom/term from beam.self or received via message)
    const send_env = beam.alloc_env();
    const pid_term = js_to_beam.convert(ctx.?, argv[0], send_env);
    const msg_term = js_to_beam.convert(ctx.?, argv[1], send_env);

    // SAFETY: pid immediately filled by enif_get_local_pid
    var pid: beam.pid = undefined;
    if (e.enif_get_local_pid(send_env, pid_term, &pid) == 0) {
        beam.free_env(send_env);
        return qjs.JS_ThrowTypeError(ctx, "beam.send: first argument must be a PID");
    }

    _ = e.enif_send(null, &pid, send_env, msg_term);
    beam.free_env(send_env);
    return js.js_true();
}

fn beam_self_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));
    // Return the owner PID as an opaque JS value via beam_to_js
    const term_env = beam.alloc_env();
    const pid_term = beam.make(self.owner_pid, .{ .env = term_env });
    const js_val = beam_to_js.convert(ctx.?, term_env, pid_term.v);
    beam.free_env(term_env);
    return js_val;
}

fn process_on_message_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const self: *worker.WorkerState = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx)));

    if (argc < 1 or !qjs.JS_IsFunction(ctx, argv[0]))
        return qjs.JS_ThrowTypeError(ctx, "Process.onMessage requires a function argument");

    if (!js.is_undefined(self.message_handler)) {
        qjs.JS_FreeValue(ctx, self.message_handler);
    }

    self.message_handler = qjs.JS_DupValue(ctx, argv[0]);
    return js.js_undefined();
}

fn send_beam_call_term(self: *worker.WorkerState, call_id: u64, name: []const u8, ctx: *qjs.JSContext, argc: c_int, argv: [*c]qjs.JSValue) void {
    const send_env = beam.alloc_env();
    var pid = self.owner_pid;
    const opts = .{ .env = send_env };

    // Convert JS args to a BEAM list
    var args_list = beam.make_empty_list(opts);
    if (argc > 1) {
        var i: c_int = argc - 1;
        while (i >= 1) : (i -= 1) {
            const term = js_to_beam.convert(ctx, argv[@intCast(i)], send_env);
            args_list = beam.make_list_cell(beam.term{ .v = term }, args_list, opts);
        }
    }

    const msg_term = beam.make(.{ .beam_call, call_id, name, args_list }, opts);
    _ = e.enif_send(null, &pid, send_env, msg_term.v);
    beam.free_env(send_env);
}
