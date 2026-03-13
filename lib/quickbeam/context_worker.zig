const ct = @import("context_types.zig");
const types = @import("types.zig");
const worker = @import("worker.zig");
const beam_proxy = @import("beam_proxy.zig");
const dom = @import("dom.zig");

const std = ct.std;
const beam = ct.beam;
const e = ct.e;
const qjs = ct.qjs;
const gpa = ct.gpa;

fn interrupt_handler(_: ?*qjs.JSRuntime, user_data: ?*anyopaque) callconv(.c) c_int {
    const pd: *ct.PoolData = @ptrCast(@alignCast(user_data));
    if (pd.deadline) |deadline| {
        if (std.time.nanoTimestamp() > deadline) return 1;
    }
    return 0;
}

// Thread-local state for the drain callback.
// Set before calling do_eval/do_call, cleared after.
threadlocal var tl_pool_data: ?*ct.PoolData = null;
threadlocal var tl_contexts: ?*std.AutoHashMap(ct.ContextId, *ct.ContextEntry) = null;
threadlocal var tl_context_id: ct.ContextId = 0;

fn install_pump(
    pd: *ct.PoolData,
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    context_id: ct.ContextId,
    entry: *ct.ContextEntry,
) void {
    tl_pool_data = pd;
    tl_contexts = contexts;
    tl_context_id = context_id;
    entry.state.drain_fn = &pool_drain_callback;
}

fn uninstall_pump(entry: *ct.ContextEntry) void {
    entry.state.drain_fn = null;
    tl_pool_data = null;
    tl_contexts = null;
}

fn pool_drain_callback(state: *worker.WorkerState) void {
    const pd = tl_pool_data orelse return;
    const contexts = tl_contexts orelse return;
    const active_id = tl_context_id;

    const msg = ct.pool_dequeue(pd) orelse return;

    switch (msg) {
        .ctx_resolve_call => |p| {
            if (p.context_id == active_id) {
                state.resolve_pending(p.id, p.json);
            } else {
                handle_ctx_resolve_call(contexts, p);
            }
        },
        .ctx_reject_call => |p| {
            if (p.context_id == active_id) {
                state.reject_pending(p.id, p.json);
            } else {
                handle_ctx_reject_call(contexts, p);
            }
        },
        .ctx_resolve_call_term => |p| {
            if (p.context_id == active_id) {
                state.resolve_pending_term(p.env, p.term, p.id);
            } else {
                handle_ctx_resolve_call_term(contexts, p);
            }
        },
        .ctx_send_message => |p| {
            if (p.context_id == active_id) {
                state.deliver_message(.{ .env = p.env, .term = p.term });
            } else {
                handle_ctx_message(contexts, p);
            }
        },
        .ctx_define_global => |p| {
            if (p.context_id == active_id) {
                state.define_global_property(.{ .name = p.name, .env = p.env, .term = p.term });
            } else {
                handle_ctx_define_global(contexts, p);
            }
        },
        .ctx_get_global => |p| {
            if (p.context_id == active_id) {
                state.get_global_property(.{ .name = p.name, .caller_pid = p.caller_pid, .ref_env = p.ref_env, .ref_term = p.ref_term });
            } else {
                handle_ctx_get_global(contexts, p);
            }
        },
        // Re-enqueue messages that can't be processed during a promise wait
        .ctx_eval, .ctx_load_bytecode, .ctx_call_fn, .ctx_reset, .ctx_memory_usage, .ctx_dom_op => {
            ct.pool_enqueue(pd, msg);
        },
        .create_context, .destroy_context, .stop => {
            ct.pool_enqueue(pd, msg);
        },
    }
}

pub fn pool_worker_main(pd: *ct.PoolData) void {
    const rt = qjs.JS_NewRuntime() orelse return;
    defer qjs.JS_FreeRuntime(rt);

    qjs.JS_SetMemoryLimit(rt, pd.memory_limit);
    qjs.JS_SetMaxStackSize(rt, pd.max_stack_size);
    qjs.JS_UpdateStackTop(rt);
    qjs.JS_SetInterruptHandler(rt, &interrupt_handler, @ptrCast(pd));

    types.class_ids_mutex.lock();
    _ = qjs.JS_NewClassID(rt, &beam_proxy.class_id);
    _ = qjs.JS_NewClassID(rt, &dom.document_class_id);
    _ = qjs.JS_NewClassID(rt, &dom.element_class_id);
    types.class_ids_mutex.unlock();

    beam_proxy.initRuntime(rt);

    var contexts = std.AutoHashMap(ct.ContextId, *ct.ContextEntry).init(gpa);
    defer {
        var it = contexts.valueIterator();
        while (it.next()) |entry| {
            entry.*.state.deinit();
            gpa.destroy(entry.*);
        }
        contexts.deinit();
    }

    while (true) {
        const min_timer_ns = find_min_timer(&contexts);
        const msg = if (min_timer_ns != null and min_timer_ns.? == 0)
            ct.pool_dequeue(pd)
        else
            ct.pool_dequeue_blocking(pd, min_timer_ns orelse null);

        if (msg) |m| {
            switch (m) {
                .create_context => |p| handle_create_context(rt, &contexts, pd, p),
                .destroy_context => |p| handle_destroy_context(&contexts, pd, p),
                .ctx_eval => |p| handle_ctx_eval(&contexts, pd, p),
                .ctx_load_bytecode => |p| handle_ctx_load_bytecode(&contexts, pd, p),
                .ctx_call_fn => |p| handle_ctx_call(&contexts, pd, p),
                .ctx_reset => |p| handle_ctx_reset(&contexts, p),
                .ctx_send_message => |p| handle_ctx_message(&contexts, p),
                .ctx_define_global => |p| handle_ctx_define_global(&contexts, p),
                .ctx_get_global => |p| handle_ctx_get_global(&contexts, p),
                .ctx_memory_usage => |p| handle_ctx_memory_usage(&contexts, p),
                .ctx_dom_op => |p| handle_ctx_dom_op(&contexts, p),
                .ctx_resolve_call => |p| handle_ctx_resolve_call(&contexts, p),
                .ctx_reject_call => |p| handle_ctx_reject_call(&contexts, p),
                .ctx_resolve_call_term => |p| handle_ctx_resolve_call_term(&contexts, p),
                .stop => break,
            }
        }

        fire_all_timers(&contexts);
    }

    pd.mutex.lock();
    pd.stopped = true;
    pd.mutex.unlock();
}

fn find_min_timer(contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry)) ?u64 {
    var min: ?u64 = null;
    var it = contexts.valueIterator();
    while (it.next()) |entry| {
        if (entry.*.state.next_timer_timeout_ns()) |ns| {
            if (min == null or ns < min.?) min = ns;
        }
    }
    return min;
}

fn fire_all_timers(contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry)) void {
    var it = contexts.valueIterator();
    while (it.next()) |entry| {
        entry.*.state.fire_expired_timers();
        entry.*.state.drain_jobs();
    }
}

fn handle_create_context(
    rt: *qjs.JSRuntime,
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    pd: *ct.PoolData,
    p: ct.CreateContextPayload,
) void {
    const ctx = qjs.JS_NewContext(rt) orelse {
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Failed to create JS context");
        return;
    };

    const entry = gpa.create(ct.ContextEntry) catch {
        qjs.JS_FreeContext(ctx);
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Out of memory");
        return;
    };

    entry.* = .{
        .rd = .{
            .mutex = .{},
            .cond = .{},
            .queue_head = null,
            .queue_tail = null,
            .stopped = false,
            .thread = null,
        },
        .state = undefined,
        .owner_pid = p.owner_pid,
        .id = p.context_id,
    };

    entry.state = .{
        .ctx = ctx,
        .rt = rt,
        .owner_pid = p.owner_pid,
        .rd = &entry.rd,
        .pending_calls = std.AutoHashMap(u64, worker.PendingCall).init(gpa),
        .timers = std.AutoHashMap(u64, worker.TimerEntry).init(gpa),
        .start_time = std.time.nanoTimestamp(),
    };

    entry.state.install_globals();

    if (p.memory_limit > 0) {
        qjs.JS_SetContextMemoryLimit(ctx, p.memory_limit);
    }
    if (p.max_reductions > 0) {
        qjs.JS_SetContextReductionLimit(ctx, p.max_reductions);
    }

    // Register rd pointer so NIFs can find it for sync call resolution
    pd.rd_map_mutex.lock();
    pd.rd_map.put(gpa, p.context_id, &entry.rd) catch {};
    pd.rd_map_mutex.unlock();

    contexts.put(p.context_id, entry) catch {
        entry.state.deinit();
        gpa.destroy(entry);
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Out of memory");
        return;
    };

    const renv = beam.alloc_env();
    const term = beam.make(p.context_id, .{ .env = renv });
    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, true, renv, term.v, "");
}

fn handle_destroy_context(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    pd: *ct.PoolData,
    p: ct.DestroyContextPayload,
) void {
    pd.rd_map_mutex.lock();
    _ = pd.rd_map.remove(p.context_id);
    pd.rd_map_mutex.unlock();

    if (contexts.fetchRemove(p.context_id)) |kv| {
        var entry = kv.value;
        entry.state.deinit();
        gpa.destroy(entry);
    }
}

fn handle_ctx_eval(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    pd: *ct.PoolData,
    p: ct.CtxEvalPayload,
) void {
    defer gpa.free(p.code);

    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Context not found");
        return;
    };
    const entry = entry_ptr.*;

    if (p.timeout_ns > 0) {
        pd.deadline = std.time.nanoTimestamp() + @as(i128, p.timeout_ns);
    }

    // Pump resolve/reject messages from the pool queue into the context's rd queue
    // so that await_promise (which drains rd) can pick them up.
    install_pump(pd, contexts, p.context_id, entry);
    qjs.JS_ResetContextReductionCount(entry.state.ctx);
    var result = worker.Result{};
    entry.state.do_eval(p.code, &result);
    uninstall_pump(entry);

    pd.deadline = null;
    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
}

fn handle_ctx_load_bytecode(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    pd: *ct.PoolData,
    p: ct.CtxEvalPayload,
) void {
    defer gpa.free(p.code);

    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Context not found");
        return;
    };
    const entry = entry_ptr.*;

    install_pump(pd, contexts, p.context_id, entry);
    var result = worker.Result{};
    entry.state.do_load_bytecode(p.code, &result);
    uninstall_pump(entry);

    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
}

fn handle_ctx_call(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    pd: *ct.PoolData,
    p: ct.CtxCallPayload,
) void {
    defer gpa.free(p.name);

    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        if (p.args_env) |ae| beam.free_env(ae);
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Context not found");
        return;
    };
    const entry = entry_ptr.*;

    if (p.timeout_ns > 0) {
        pd.deadline = std.time.nanoTimestamp() + @as(i128, p.timeout_ns);
    }

    install_pump(pd, contexts, p.context_id, entry);
    qjs.JS_ResetContextReductionCount(entry.state.ctx);
    var result = worker.Result{};
    entry.state.do_call(p.name, p.args_env, p.args_term, &result);
    uninstall_pump(entry);

    pd.deadline = null;
    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
}

fn handle_ctx_reset(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxResetPayload,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Context not found");
        return;
    };
    const entry = entry_ptr.*;

    var result = worker.Result{};
    entry.state.do_reset(&result);

    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
}

fn handle_ctx_message(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxMessagePayload,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        if (p.env) |env| beam.free_env(env);
        return;
    };
    const entry = entry_ptr.*;
    entry.state.deliver_message(.{ .env = p.env, .term = p.term });
}

fn handle_ctx_define_global(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxDefineGlobalPayload,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        if (p.env) |env| beam.free_env(env);
        gpa.free(p.name);
        return;
    };
    const entry = entry_ptr.*;
    entry.state.define_global_property(.{ .name = p.name, .env = p.env, .term = p.term });
}

fn handle_ctx_get_global(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxGetGlobalPayload,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        gpa.free(p.name);
        if (p.ref_env) |env| beam.free_env(env);
        return;
    };
    const entry = entry_ptr.*;
    entry.state.get_global_property(.{ .name = p.name, .caller_pid = p.caller_pid, .ref_env = p.ref_env, .ref_term = p.ref_term });
}

fn handle_ctx_memory_usage(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxMemoryPayload,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Context not found");
        return;
    };
    const entry = entry_ptr.*;

    var usage: qjs.JSMemoryUsage = undefined;
    qjs.JS_ComputeMemoryUsage(entry.state.rt, &usage);
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
        .context_malloc_size = qjs.JS_GetContextMallocSize(entry.state.ctx),
    }, .{ .env = renv });
    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, true, renv, result_term.v, "");
}

fn handle_ctx_dom_op(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxDomPayload,
) void {
    defer gpa.free(p.selector);
    defer gpa.free(p.attr_name);

    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        types.send_reply(p.caller_pid, p.ref_env, p.ref_term, false, null, null, "Context not found");
        return;
    };
    const entry = entry_ptr.*;

    var result = worker.Result{};
    entry.state.do_dom_op_result(p.op, p.selector, p.attr_name, &result);
    types.send_reply(p.caller_pid, p.ref_env, p.ref_term, result.ok, result.env, result.term, result.json);
}

fn handle_ctx_resolve_call(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxCallResponse,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        gpa.free(p.json);
        return;
    };
    const entry = entry_ptr.*;
    entry.state.resolve_pending(p.id, p.json);
}

fn handle_ctx_reject_call(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxCallResponse,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        gpa.free(p.json);
        return;
    };
    const entry = entry_ptr.*;
    entry.state.reject_pending(p.id, p.json);
}

fn handle_ctx_resolve_call_term(
    contexts: *std.AutoHashMap(ct.ContextId, *ct.ContextEntry),
    p: ct.CtxCallResponseTerm,
) void {
    const entry_ptr = contexts.getPtr(p.context_id) orelse {
        if (p.env) |env| beam.free_env(env);
        return;
    };
    const entry = entry_ptr.*;
    entry.state.resolve_pending_term(p.env, p.term, p.id);
}
