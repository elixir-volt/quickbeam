# QuickBEAM: Zig NIF Draft

## Why Zig?

The NIF layer sits between two C APIs: QuickJS (`quickjs.h`) and BEAM (`erl_nif.h`).
Zig can `@cImport` both directly — no FFI layers, no bindings crates, no lifetime gymnastics.

What we get:
- **Direct C interop** — call QuickJS and erl_nif functions as if they were native
- **Safer than C** — bounds-checked slices, no implicit casts, comptime, `errdefer`
- **Readable** — simpler than Rust, you can review every line
- **Zigler integration** — `use Zig` in Elixir, automatic type marshalling, resources, threading

## Architecture

Same as the Rust version — Elixir GenServer → mpsc channel → worker thread running QuickJS.
But the boundary code is ~400 lines of Zig instead of ~650 lines of Rust fighting lifetimes.

```
┌─────────────────────┐     messages      ┌──────────────────────┐
│  QuickBEAM.Runtime  │ ──── channel ───▶ │    Worker Thread     │
│  (GenServer/Elixir) │ ◀── send_to_pid ─ │  (Zig + QuickJS C)   │
└─────────────────────┘                   └──────────────────────┘
```

## What the Code Looks Like

### 1. Elixir module with Zigler

```elixir
defmodule QuickBEAM.Native do
  use Zig,
    otp_app: :quickbeam,
    # Compile QuickJS C source directly
    c: [
      include_dirs: "c_src",
      src: ["c_src/quickjs.c", "c_src/quickjs-libc.c"]
    ],
    resources: [:RuntimeResource],
    nifs: [
      # These block on the worker thread response, so dirty_io
      eval: [:dirty_io],
      call_function: [:dirty_io],
      load_module: [:dirty_io],
      reset: [:dirty_io],
      stop: [:dirty_io],
      # These just push onto the channel, instant return
      start: [],
      resolve_call: [],
      reject_call: [],
      send_message: []
    ]

  ~Z"""
  const quickbeam = @import("quickbeam.zig");
  // re-export all pub fns — Zigler picks them up as NIFs
  pub const start = quickbeam.start;
  pub const eval = quickbeam.eval;
  pub const call_function = quickbeam.call_function;
  pub const load_module = quickbeam.load_module;
  pub const reset = quickbeam.reset;
  pub const stop = quickbeam.stop;
  pub const resolve_call = quickbeam.resolve_call;
  pub const reject_call = quickbeam.reject_call;
  pub const send_message = quickbeam.send_message;
  pub const RuntimeResource = quickbeam.RuntimeResource;
  """
end
```

### 2. The Zig NIF layer (`quickbeam.zig`)

```zig
const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const qjs = @cImport(@cInclude("quickjs.h"));

// ─── Resource: wraps a pointer to the channel sender ───

const Channel = std.Thread.Channel(Message);

const RuntimeData = struct {
    channel: *Channel,
    thread: std.Thread,
};

pub const RuntimeResource = beam.Resource(RuntimeData, @import("root"), .{
    .Callbacks = struct {
        pub fn dtor(data: *RuntimeData) void {
            // Send Stop, then join the thread
            data.channel.send(.stop) catch {};
            data.thread.join();
            beam.allocator.destroy(data.channel);
        }
    },
});

// ─── Messages between BEAM and worker thread ───

const ResultPair = struct { ok: bool, json: []const u8 };

const Message = union(enum) {
    eval: struct { code: []const u8, reply: *std.Thread.ResetEvent },
    call_fn: struct { name: []const u8, args_json: []const u8, reply: *std.Thread.ResetEvent },
    load_module: struct { name: []const u8, code: []const u8, reply: *std.Thread.ResetEvent },
    reset: struct { reply: *std.Thread.ResetEvent },
    resolve_call: struct { id: u64, value_json: []const u8 },
    reject_call: struct { id: u64, reason: []const u8 },
    send_message: struct { json: []const u8 },
    stop,
};

// ─── NIF entry points ───

pub fn start(pid: beam.pid) !RuntimeResource {
    const channel = try beam.allocator.create(Channel);
    channel.* = Channel.init(beam.allocator);

    const thread = try std.Thread.spawn(.{}, worker_main, .{ channel, pid });

    return RuntimeResource.create(.{
        .channel = channel,
        .thread = thread,
    }, .{});
}

pub fn eval(resource: RuntimeResource, code: []const u8) !beam.term {
    // This runs on a dirty_io scheduler — blocking is fine
    var event = std.Thread.ResetEvent{};
    const data = resource.unpack();

    data.channel.send(.{ .eval = .{ .code = code, .reply = &event } }) catch
        return beam.make(.{ .error, "dead_runtime" }, .{});

    event.wait();
    // Result is written back via the event's associated data
    // (simplified — real impl uses a shared result slot)
    return beam.make(.{ .ok, "null" }, .{});
}

pub fn resolve_call(resource: RuntimeResource, call_id: u64, value_json: []const u8) !beam.term {
    const data = resource.unpack();
    data.channel.send(.{ .resolve_call = .{ .id = call_id, .value_json = value_json } }) catch {};
    return beam.make(.ok, .{});
}

pub fn reject_call(resource: RuntimeResource, call_id: u64, reason: []const u8) !beam.term {
    const data = resource.unpack();
    data.channel.send(.{ .reject_call = .{ .id = call_id, .reason = reason } }) catch {};
    return beam.make(.ok, .{});
}

// ... (call_function, load_module, reset, stop, send_message follow the same pattern)

// ─── Worker thread — runs QuickJS ───

fn worker_main(channel: *Channel, owner_pid: beam.pid) void {
    const rt = qjs.JS_NewRuntime() orelse return;
    defer qjs.JS_FreeRuntime(rt);

    qjs.JS_SetMemoryLimit(rt, 256 * 1024 * 1024);
    qjs.JS_SetMaxStackSize(rt, 1024 * 1024);

    const ctx = qjs.JS_NewContext(rt) orelse return;
    defer qjs.JS_FreeContext(ctx);

    var state = WorkerState{
        .ctx = ctx,
        .rt = rt,
        .owner_pid = owner_pid,
        .pending_calls = std.AutoHashMap(u64, PendingCall).init(beam.allocator),
        .timers = std.AutoHashMap(u64, TimerEntry).init(beam.allocator),
    };
    defer state.deinit();

    state.install_globals();

    // Event loop
    while (true) {
        const timeout = state.next_timer_timeout();

        // Non-blocking channel receive with timeout
        const msg = channel.tryRecv() orelse {
            if (timeout) |t| {
                std.time.sleep(std.math.min(t, 1_000_000)); // 1ms max sleep
                state.fire_expired_timers();
                state.drain_jobs();
                continue;
            } else {
                // No timers, block until message
                const m = channel.recv() catch break;
                // process m below
                if (!state.handle_message(m)) break;
                state.drain_jobs();
                continue;
            }
        };

        if (!state.handle_message(msg)) break;
        state.fire_expired_timers();
        state.drain_jobs();
    }
}

const WorkerState = struct {
    ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    owner_pid: beam.pid,
    pending_calls: std.AutoHashMap(u64, PendingCall),
    timers: std.AutoHashMap(u64, TimerEntry),
    next_call_id: u64 = 1,
    next_timer_id: u64 = 1,

    fn deinit(self: *WorkerState) void {
        self.pending_calls.deinit();
        self.timers.deinit();
    }

    fn drain_jobs(self: *WorkerState) void {
        while (true) {
            const ret = qjs.JS_ExecutePendingJob(self.rt, null);
            if (ret <= 0) break;
        }
    }

    fn install_globals(self: *WorkerState) void {
        const global = qjs.JS_GetGlobalObject(self.ctx);
        defer qjs.JS_FreeValue(self.ctx, global);

        // beam.call(name, ...args) → Promise
        self.install_beam_call(global);

        // setTimeout, setInterval, clearTimeout
        self.install_timers(global);

        // console.log
        self.install_console(global);
    }

    fn install_beam_call(self: *WorkerState, global: qjs.JSValue) void {
        const beam_obj = qjs.JS_NewObject(self.ctx);

        // The C callback for beam.call — this is where Zig shines.
        // No lifetime issues, no closure boxing, just a C function with opaque pointer.
        const call_fn = qjs.JS_NewCFunction2(
            self.ctx,
            beam_call_impl,    // plain C function
            "call",
            1,                 // min args
            qjs.JS_CFUNC_generic_magic,
            @intCast(@intFromPtr(self)), // opaque "magic" — pointer to WorkerState
        );

        qjs.JS_SetPropertyStr(self.ctx, beam_obj, "call", call_fn);
        qjs.JS_SetPropertyStr(self.ctx, global, "beam", beam_obj);
    }

    // ... timer and console installation follows the same pattern
};

// Plain C-callable function — no lifetime issues!
fn beam_call_impl(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*]qjs.JSValue,
    magic: c_int,
) callconv(.c) qjs.JSValue {
    _ = this;
    const self: *WorkerState = @ptrFromInt(@as(usize, @intCast(magic)));

    if (argc < 1) {
        return qjs.JS_ThrowTypeError(ctx, "beam.call requires at least a handler name");
    }

    // Get the handler name as a string
    const name_ptr = qjs.JS_ToCString(ctx, argv[0]);
    if (name_ptr == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, name_ptr);

    // Create a Promise
    var resolve_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx, &resolve_funcs);
    if (qjs.JS_IsException(promise)) return qjs.JS_EXCEPTION;

    const call_id = self.next_call_id;
    self.next_call_id += 1;

    // Store the resolve/reject functions
    self.pending_calls.put(call_id, .{
        .resolve = resolve_funcs[0],
        .reject = resolve_funcs[1],
    }) catch return qjs.JS_ThrowOutOfMemory(ctx);

    // Serialize args to JSON and send to BEAM owner process
    const args_json = serialize_args(ctx, argc - 1, argv + 1);
    defer beam.allocator.free(args_json);

    // Send {:beam_call, call_id, name, args_json} to the owner pid
    const env = beam.alloc_env();
    beam.send(self.owner_pid, .{
        .beam_call,
        call_id,
        std.mem.span(name_ptr),
        args_json,
    }, .{ .env = env }) catch {};
    beam.free_env(env);

    return promise;
}
```

### 3. Comparison: Rust vs Zig for `beam.call`

**Rust (current — doesn't compile due to lifetime invariance):**
```rust
let call_fn = Function::new(
    ctx.clone(),
    move |ctx: rquickjs::Ctx<'_>, name: String, args: Rest<Value<'_>>| {
        //                   ^^                              ^^ different anonymous lifetimes!
        let worker = unsafe { &mut *worker_ptr };
        let (promise, resolve, reject) = ctx.promise()...;
        worker.pending_calls.insert(call_id, PendingCall {
            resolve: Persistent::save(&ctx, resolve),  // lifetime error
            reject: Persistent::save(&ctx, reject),    // lifetime error
        });
        Ok::<_, rquickjs::Error>(promise.into_value()) // lifetime error
    },
)
```

**Zig (direct QuickJS C API — just works):**
```zig
fn beam_call_impl(ctx: ?*qjs.JSContext, this: qjs.JSValue,
    argc: c_int, argv: [*]qjs.JSValue, magic: c_int,
) callconv(.c) qjs.JSValue {
    const self: *WorkerState = @ptrFromInt(@as(usize, @intCast(magic)));
    var resolve_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx, &resolve_funcs);
    self.pending_calls.put(call_id, .{ .resolve = resolve_funcs[0], .reject = resolve_funcs[1] }) catch ...;
    // Send to BEAM...
    return promise;
}
```

No closures, no lifetimes, no `unsafe`, no `Persistent<T>`.
JSValue is just a `u64` (NaN-boxed) — you store it, pass it, free it. Done.

### 4. What about memory safety?

The safety risk in our NIF:

| Risk | Mitigation |
|------|-----------|
| Use-after-free of JSValue | QuickJS refcounting (`JS_DupValue`/`JS_FreeValue`) — same in C, Rust, or Zig |
| Worker pointer dangling | Worker outlives all closures (thread owns it). Same `unsafe` pattern as Rust version, but explicit in Zig via `@ptrFromInt` |
| Buffer overflows | Zig slices are bounds-checked. `JS_ToCString`/`JS_FreeCString` is the QuickJS API. No manual buffer management in our glue |
| Channel use-after-free | Resource destructor joins the thread before freeing channel |
| Null dereference | Zig has optional types. `qjs.JS_NewContext(rt) orelse return` |

The honest truth: **both Rust and Zig require manual QuickJS refcount discipline** because QuickJS is a C library. Rust's borrow checker can't help with `JS_DupValue`/`JS_FreeValue` — rquickjs wraps it, but we're fighting that wrapper more than it's helping us.

### 5. Build simplicity

**Rust version:**
- Cargo.toml with rustler, rquickjs, rquickjs-sys
- rquickjs needs `bindgen` feature → requires libclang at build time
- Bindgen generates quickjs-sys bindings → another compilation step
- Rustler compiles a proc-macro → slow first build

**Zig version:**
- Copy `quickjs.c` + `quickjs.h` into `c_src/`
- `use Zig, c: [src: "c_src/quickjs.c"]` in Elixir
- Zig compiles QuickJS as part of the NIF build
- One toolchain, one step

## Open Questions

1. **Zigler's `std.Thread.Channel`** — does Zigler's Zig version have this?
   If not, we implement a simple mutex+condition variable channel in ~30 lines of Zig.
   Or use a C `pthread_mutex_t` + `pthread_cond_t` (Zig calls POSIX directly).

2. **`beam.send` from worker thread** — Zigler docs show `beam.send` with `alloc_env`.
   This maps to `enif_alloc_env` + `enif_send`, which is exactly what we need
   for the worker thread to notify the GenServer of `beam.call` requests.

3. **Zigler Zig version** — Zigler 0.15.2 bundles Zig 0.13.x. Need to verify
   QuickJS-NG compiles with it (QuickJS-NG uses C11, Zig's C compiler handles C11).

4. **Resource thread-safety** — The RuntimeResource is accessed from both BEAM schedulers
   (NIF calls) and the worker thread. The channel provides the synchronization.
   Need to verify Zigler's resource model allows this.
