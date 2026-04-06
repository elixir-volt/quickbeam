const std = @import("std");
const wamr = @import("wamr.zig").wamr;
const wasm_host_imports = @import("wasm_host_imports.zig");

var wamr_initialized = false;

fn copy_error_buf(err_buf: []u8, msg: []const u8) void {
    if (err_buf.len == 0) return;
    const copy_len = @min(msg.len, err_buf.len - 1);
    std.mem.copyForwards(u8, err_buf[0..copy_len], msg[0..copy_len]);
    err_buf[copy_len] = 0;
}

pub fn ensure_init() bool {
    if (wamr_initialized) return true;
    if (wamr.wamr_bridge_init()) {
        wamr_initialized = true;
        return true;
    }
    return false;
}

pub const ManagedInstance = struct {
    inst: *wamr.WamrInstance,
    imports: ?wasm_host_imports.PreparedImports = null,

    pub fn destroy(self: *ManagedInstance) void {
        wamr.wamr_bridge_stop(self.inst);
        if (self.imports) |*imports| {
            wamr.wamr_bridge_unregister_native_modules(@ptrCast(imports.registrations.ptr), @intCast(imports.registrations.len));
            imports.deinit();
        }
        std.heap.c_allocator.destroy(self);
    }
};

pub fn start_managed_instance(
    mod: *wamr.WamrModule,
    stack_size: u32,
    heap_size: u32,
    prepared_imports: ?*wasm_host_imports.PreparedImports,
    err_buf: []u8,
) ?*ManagedInstance {
    const imports = if (prepared_imports) |value|
        if (value.registrations.len > 0) value else null
    else
        null;

    const inst = if (imports) |value|
        wamr.wamr_bridge_start_with_native_modules(mod, stack_size, heap_size, @ptrCast(value.registrations.ptr), @intCast(value.registrations.len), err_buf.ptr, @intCast(err_buf.len))
    else
        wamr.wamr_bridge_start(mod, stack_size, heap_size, err_buf.ptr, @intCast(err_buf.len));
    if (inst == null) return null;

    const inst_nn = inst orelse return null;
    const managed = std.heap.c_allocator.create(ManagedInstance) catch {
        wamr.wamr_bridge_stop(inst_nn);
        if (imports) |value| {
            wamr.wamr_bridge_unregister_native_modules(@ptrCast(value.registrations.ptr), @intCast(value.registrations.len));
            value.deinit();
            value.* = wasm_host_imports.PreparedImports.empty();
        }
        copy_error_buf(err_buf, "resource alloc failed");
        return null;
    };

    managed.* = .{
        .inst = inst_nn,
        .imports = if (imports) |value| value.* else null,
    };

    if (imports) |value| {
        value.* = wasm_host_imports.PreparedImports.empty();
    }

    return managed;
}
