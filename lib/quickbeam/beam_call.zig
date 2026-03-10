const types = @import("types.zig");
const worker = @import("worker.zig");
const js = @import("js_helpers.zig");
const beam_to_js = @import("beam_to_js.zig");
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

    send_beam_call(self, call_id, name, args_json);
    qjs.JS_FreeCString(ctx, name_ptr);
    if (args_alloc) gpa.free(args_json);

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

    var slot = types.SyncCallSlot{};
    self.rd.sync_slots_mutex.lock();
    self.rd.sync_slots.put(gpa, call_id, &slot) catch {
        self.rd.sync_slots_mutex.unlock();
        qjs.JS_FreeCString(ctx, name_ptr);
        if (args_alloc) gpa.free(args_json);
        return qjs.JS_ThrowOutOfMemory(ctx);
    };
    self.rd.sync_slots_mutex.unlock();

    send_beam_call(self, call_id, name, args_json);
    qjs.JS_FreeCString(ctx, name_ptr);
    if (args_alloc) gpa.free(args_json);

    slot.done.wait();

    self.rd.sync_slots_mutex.lock();
    _ = self.rd.sync_slots.remove(call_id);
    self.rd.sync_slots_mutex.unlock();

    // Prefer native term result over JSON
    if (slot.result_env) |result_env| {
        defer beam.free_env(result_env);
        if (slot.ok) {
            return beam_to_js.convert(ctx.?, result_env, slot.result_term.?);
        } else {
            return qjs.JS_ThrowInternalError(ctx, "beam.callSync failed");
        }
    }

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

fn send_beam_call(self: *worker.WorkerState, call_id: u64, name: []const u8, args_json: []const u8) void {
    const send_env = beam.alloc_env();
    var pid = self.owner_pid;
    const opts = .{ .env = send_env };
    const msg_term = beam.make(.{ .beam_call, call_id, name, args_json }, opts);
    _ = e.enif_send(null, &pid, send_env, msg_term.v);
    beam.free_env(send_env);
}
