const std = @import("std");

const wamr = @import("wamr.zig").wamr;

extern fn quickbeam_wasm_host_invoke(
    runtime_data: ?*anyopaque,
    callback_name_z: [*:0]const u8,
    signature_z: [*:0]const u8,
    raw_args: [*]u64,
    err_buf: [*]u8,
    err_buf_size: u32,
) bool;

extern fn quickbeam_wasm_host_invoke_js(
    runtime_data: ?*anyopaque,
    callback_name_z: [*:0]const u8,
    signature_z: [*:0]const u8,
    raw_args: [*]u64,
    err_buf: [*]u8,
    err_buf_size: u32,
) bool;

pub const ImportSpec = struct {
    module_name: []const u8,
    symbol: []const u8,
    signature: []const u8,
    callback_name: []const u8,
};

pub const CallbackMode = enum {
    beam,
    js,
};

const Attachment = extern struct {
    runtime_data: ?*anyopaque,
    callback_name: [*:0]const u8,
    signature: [*:0]const u8,
};

pub const PreparedImports = struct {
    registrations: []wamr.WamrNativeModule,
    symbols: []wamr.NativeSymbol,
    attachments: []*Attachment,
    module_names: [][:0]u8,
    symbol_names: [][:0]u8,
    signatures: [][:0]u8,
    callback_names: [][:0]u8,

    pub fn empty() PreparedImports {
        return .{
            .registrations = &.{},
            .symbols = &.{},
            .attachments = &.{},
            .module_names = &.{},
            .symbol_names = &.{},
            .signatures = &.{},
            .callback_names = &.{},
        };
    }

    pub fn deinit(self: *PreparedImports) void {
        for (self.attachments) |attachment| std.heap.c_allocator.destroy(attachment);
        for (self.module_names) |value| std.heap.c_allocator.free(value);
        for (self.symbol_names) |value| std.heap.c_allocator.free(value);
        for (self.signatures) |value| std.heap.c_allocator.free(value);
        for (self.callback_names) |value| std.heap.c_allocator.free(value);

        if (self.registrations.len > 0) std.heap.c_allocator.free(self.registrations);
        if (self.symbols.len > 0) std.heap.c_allocator.free(self.symbols);
        if (self.attachments.len > 0) std.heap.c_allocator.free(self.attachments);
        if (self.module_names.len > 0) std.heap.c_allocator.free(self.module_names);
        if (self.symbol_names.len > 0) std.heap.c_allocator.free(self.symbol_names);
        if (self.signatures.len > 0) std.heap.c_allocator.free(self.signatures);
        if (self.callback_names.len > 0) std.heap.c_allocator.free(self.callback_names);

        self.* = empty();
    }
};

fn host_import_callback(mode: CallbackMode) *const fn (wamr.wasm_exec_env_t, [*]u64) callconv(.c) void {
    return switch (mode) {
        .beam => &quickbeam_wamr_host_import_raw_beam,
        .js => &quickbeam_wamr_host_import_raw_js,
    };
}

fn invoke_host_import(comptime mode: CallbackMode, exec_env: wamr.wasm_exec_env_t, raw_args: [*]u64) void {
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    const attachment_ptr = wamr.wasm_runtime_get_function_attachment(exec_env) orelse {
        wamr.wasm_runtime_set_exception(module_inst, "missing host import attachment");
        return;
    };

    const attachment: *Attachment = @ptrCast(@alignCast(attachment_ptr));
    var err_buf = std.mem.zeroes([256]u8);

    const ok = switch (mode) {
        .beam => quickbeam_wasm_host_invoke(
            attachment.runtime_data,
            attachment.callback_name,
            attachment.signature,
            raw_args,
            &err_buf,
            err_buf.len,
        ),
        .js => quickbeam_wasm_host_invoke_js(
            attachment.runtime_data,
            attachment.callback_name,
            attachment.signature,
            raw_args,
            &err_buf,
            err_buf.len,
        ),
    };

    if (!ok) {
        wamr.wasm_runtime_set_exception(module_inst, &err_buf);
    }
}

pub export fn quickbeam_wamr_host_import_raw_beam(exec_env: wamr.wasm_exec_env_t, raw_args: [*]u64) callconv(.c) void {
    invoke_host_import(.beam, exec_env, raw_args);
}

pub export fn quickbeam_wamr_host_import_raw_js(exec_env: wamr.wasm_exec_env_t, raw_args: [*]u64) callconv(.c) void {
    invoke_host_import(.js, exec_env, raw_args);
}

fn find_module_index(module_names: []const [:0]u8, module_name: []const u8) ?usize {
    for (module_names, 0..) |existing, index| {
        if (std.mem.eql(u8, existing[0..existing.len], module_name)) {
            return index;
        }
    }
    return null;
}

pub fn prepare(imports: []const ImportSpec, runtime_data: ?*anyopaque, mode: CallbackMode) !PreparedImports {
    if (imports.len == 0) return PreparedImports.empty();

    var module_names_list: std.ArrayListUnmanaged([:0]u8) = .{};
    defer module_names_list.deinit(std.heap.c_allocator);

    var module_counts: std.ArrayListUnmanaged(usize) = .{};
    defer module_counts.deinit(std.heap.c_allocator);

    const import_module_indices = try std.heap.c_allocator.alloc(usize, imports.len);
    defer std.heap.c_allocator.free(import_module_indices);

    errdefer {
        for (module_names_list.items) |value| std.heap.c_allocator.free(value);
    }

    for (imports, 0..) |import, index| {
        const module_index = find_module_index(module_names_list.items, import.module_name) orelse blk: {
            const module_name = try std.heap.c_allocator.dupeZ(u8, import.module_name);
            try module_names_list.append(std.heap.c_allocator, module_name);
            try module_counts.append(std.heap.c_allocator, 0);
            break :blk module_names_list.items.len - 1;
        };

        import_module_indices[index] = module_index;
        module_counts.items[module_index] += 1;
    }

    var prepared = PreparedImports{
        .registrations = try std.heap.c_allocator.alloc(wamr.WamrNativeModule, module_names_list.items.len),
        .symbols = try std.heap.c_allocator.alloc(wamr.NativeSymbol, imports.len),
        .attachments = try std.heap.c_allocator.alloc(*Attachment, imports.len),
        .module_names = try module_names_list.toOwnedSlice(std.heap.c_allocator),
        .symbol_names = try std.heap.c_allocator.alloc([:0]u8, imports.len),
        .signatures = try std.heap.c_allocator.alloc([:0]u8, imports.len),
        .callback_names = try std.heap.c_allocator.alloc([:0]u8, imports.len),
    };
    errdefer prepared.deinit();

    const module_starts = try std.heap.c_allocator.alloc(usize, prepared.registrations.len);
    defer std.heap.c_allocator.free(module_starts);
    const module_offsets = try std.heap.c_allocator.alloc(usize, prepared.registrations.len);
    defer std.heap.c_allocator.free(module_offsets);

    var next_symbol_index: usize = 0;
    for (module_counts.items, 0..) |count, index| {
        module_starts[index] = next_symbol_index;
        module_offsets[index] = next_symbol_index;
        next_symbol_index += count;

        prepared.registrations[index] = .{
            .module_name = prepared.module_names[index].ptr,
            .symbols = if (count > 0) &prepared.symbols[module_starts[index]] else null,
            .symbol_count = @intCast(count),
        };
    }

    for (imports, 0..) |import, index| {
        const module_index = import_module_indices[index];
        const symbol_index = module_offsets[module_index];
        module_offsets[module_index] += 1;

        const symbol_name = try std.heap.c_allocator.dupeZ(u8, import.symbol);
        const signature = try std.heap.c_allocator.dupeZ(u8, import.signature);
        const callback_name = try std.heap.c_allocator.dupeZ(u8, import.callback_name);
        const attachment = try std.heap.c_allocator.create(Attachment);

        attachment.* = .{
            .runtime_data = runtime_data,
            .callback_name = callback_name.ptr,
            .signature = signature.ptr,
        };

        prepared.symbol_names[symbol_index] = symbol_name;
        prepared.signatures[symbol_index] = signature;
        prepared.callback_names[symbol_index] = callback_name;
        prepared.attachments[symbol_index] = attachment;

        prepared.symbols[symbol_index] = std.mem.zeroes(wamr.NativeSymbol);
        prepared.symbols[symbol_index].symbol = symbol_name.ptr;
        prepared.symbols[symbol_index].func_ptr = @ptrCast(@constCast(host_import_callback(mode)));
        prepared.symbols[symbol_index].signature = signature.ptr;
        prepared.symbols[symbol_index].attachment = attachment;
    }

    return prepared;
}
