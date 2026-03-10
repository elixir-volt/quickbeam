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

    send_beam_call_term(self, call_id, name, ctx.?, argc, argv);
    qjs.JS_FreeCString(ctx, name_ptr);

    slot.done.wait();

    self.rd.sync_slots_mutex.lock();
    _ = self.rd.sync_slots.remove(call_id);
    self.rd.sync_slots_mutex.unlock();

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
