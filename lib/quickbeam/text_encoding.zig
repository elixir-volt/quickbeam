const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;
const gpa = types.gpa;

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    install_text_encoder(ctx, global);
    install_text_decoder(ctx, global);
    install_atob_btoa(ctx, global);
}

// ──────────────────── TextEncoder ────────────────────

fn install_text_encoder(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const ctor = qjs.JS_NewCFunction2(ctx, &text_encoder_ctor, "TextEncoder", 0, qjs.JS_CFUNC_constructor, 0);

    const proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, proto, "encoding", qjs.JS_NewString(ctx, "utf-8"));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "encode", qjs.JS_NewCFunction(ctx, &text_encoder_encode, "encode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "encodeInto", qjs.JS_NewCFunction(ctx, &text_encoder_encode_into, "encodeInto", 2));

    _ = qjs.JS_SetPropertyStr(ctx, ctor, "prototype", qjs.JS_DupValue(ctx, proto));
    _ = qjs.JS_SetConstructor(ctx, ctor, proto);
    qjs.JS_FreeValue(ctx, proto);

    _ = qjs.JS_SetPropertyStr(ctx, global, "TextEncoder", ctor);
}

fn text_encoder_ctor(
    ctx: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const proto = qjs.JS_GetPropertyStr(ctx, new_target, "prototype");
    defer qjs.JS_FreeValue(ctx, proto);

    const obj = qjs.JS_NewObjectProtoClass(ctx, proto, 0);
    _ = qjs.JS_SetPropertyStr(ctx, obj, "encoding", qjs.JS_NewString(ctx, "utf-8"));
    return obj;
}

fn text_encoder_encode(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this;
    var input: [*c]const u8 = "";
    var len: usize = 0;

    if (argc >= 1 and !qjs.JS_IsUndefined(argv[0])) {
        input = qjs.JS_ToCStringLen(ctx, &len, argv[0]) orelse
            return qjs.JS_ThrowTypeError(ctx, "Failed to convert argument to string");
    }

    const buf = @as([*]const u8, @ptrCast(input))[0..len];
    const ab = qjs.JS_NewArrayBufferCopy(ctx, buf.ptr, buf.len);
    if (js.js_is_exception(ab)) return js.js_exception();

    const u8arr_ctor = blk: {
        const g = qjs.JS_GetGlobalObject(ctx);
        defer qjs.JS_FreeValue(ctx, g);
        break :blk qjs.JS_GetPropertyStr(ctx, g, "Uint8Array");
    };
    defer qjs.JS_FreeValue(ctx, u8arr_ctor);

    var ab_arg = [_]qjs.JSValue{ab};
    const result = qjs.JS_CallConstructor(ctx, u8arr_ctor, 1, &ab_arg);
    qjs.JS_FreeValue(ctx, ab);

    if (argc >= 1 and !qjs.JS_IsUndefined(argv[0])) {
        qjs.JS_FreeCString(ctx, input);
    }

    return result;
}

fn text_encoder_encode_into(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "encodeInto requires 2 arguments");

    var src_len: usize = 0;
    const src_ptr = qjs.JS_ToCStringLen(ctx, &src_len, argv[0]) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to convert source to string");
    defer qjs.JS_FreeCString(ctx, src_ptr);

    const src = @as([*]const u8, @ptrCast(src_ptr))[0..src_len];

    var dst_size: usize = 0;
    var dst_offset: usize = 0;
    const dst_buf = get_typed_array_buffer(ctx, argv[1], &dst_offset, &dst_size) orelse
        return qjs.JS_ThrowTypeError(ctx, "Second argument must be a Uint8Array");

    var read: usize = 0;
    var written: usize = 0;
    var src_idx: usize = 0;

    while (src_idx < src.len and written < dst_size) {
        const byte = src[src_idx];
        const seq_len = utf8_seq_len(byte);
        if (seq_len == 0) {
            src_idx += 1;
            continue;
        }
        if (src_idx + seq_len > src.len) break;
        if (written + seq_len > dst_size) break;

        @memcpy(dst_buf[dst_offset + written .. dst_offset + written + seq_len], src[src_idx .. src_idx + seq_len]);
        written += seq_len;
        src_idx += seq_len;

        // Count JS string characters read (surrogate pairs = 2 JS chars for 4-byte UTF-8)
        if (seq_len == 4) {
            read += 2;
        } else {
            read += 1;
        }
    }

    const result = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, result, "read", qjs.JS_NewInt64(ctx, @intCast(read)));
    _ = qjs.JS_SetPropertyStr(ctx, result, "written", qjs.JS_NewInt64(ctx, @intCast(written)));
    return result;
}

fn utf8_seq_len(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 0; // continuation byte or invalid
}

fn get_typed_array_buffer(
    ctx: ?*qjs.JSContext,
    val: qjs.JSValue,
    offset: *usize,
    size: *usize,
) ?[*]u8 {
    var byte_offset: usize = 0;
    var byte_len: usize = 0;
    var total_size: usize = 0;
    const ab = qjs.JS_GetTypedArrayBuffer(ctx, val, &byte_offset, &byte_len, &total_size);
    if (js.js_is_exception(ab)) return null;
    defer qjs.JS_FreeValue(ctx, ab);

    var buf_size: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(ctx, &buf_size, ab);
    if (ptr == null) return null;

    offset.* = byte_offset;
    size.* = byte_len;
    return ptr;
}

// ──────────────────── TextDecoder ────────────────────

fn install_text_decoder(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    const ctor = qjs.JS_NewCFunction2(ctx, &text_decoder_ctor, "TextDecoder", 0, qjs.JS_CFUNC_constructor, 0);

    const proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, proto, "encoding", qjs.JS_NewString(ctx, "utf-8"));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "decode", qjs.JS_NewCFunction(ctx, &text_decoder_decode, "decode", 1));

    _ = qjs.JS_SetPropertyStr(ctx, ctor, "prototype", qjs.JS_DupValue(ctx, proto));
    _ = qjs.JS_SetConstructor(ctx, ctor, proto);
    qjs.JS_FreeValue(ctx, proto);

    _ = qjs.JS_SetPropertyStr(ctx, global, "TextDecoder", ctor);
}

fn text_decoder_ctor(
    ctx: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc >= 1 and !qjs.JS_IsUndefined(argv[0])) {
        const ptr = qjs.JS_ToCString(ctx, argv[0]) orelse
            return qjs.JS_ThrowTypeError(ctx, "Invalid encoding label");
        const encoding = std.mem.span(ptr);

        const supported = is_supported_encoding(encoding);
        qjs.JS_FreeCString(ctx, ptr);
        if (!supported) {
            return qjs.JS_ThrowRangeError(ctx, "The encoding label provided is not supported");
        }
    }

    var fatal = false;
    if (argc >= 2 and qjs.JS_IsObject(argv[1])) {
        const fatal_val = qjs.JS_GetPropertyStr(ctx, argv[1], "fatal");
        defer qjs.JS_FreeValue(ctx, fatal_val);
        fatal = qjs.JS_ToBool(ctx, fatal_val) != 0;
    }

    const proto = qjs.JS_GetPropertyStr(ctx, new_target, "prototype");
    defer qjs.JS_FreeValue(ctx, proto);

    const obj = qjs.JS_NewObjectProtoClass(ctx, proto, 0);
    _ = qjs.JS_SetPropertyStr(ctx, obj, "encoding", qjs.JS_NewString(ctx, "utf-8"));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "fatal", if (fatal) js.js_true() else js.js_false());
    return obj;
}

fn is_supported_encoding(label: []const u8) bool {
    const lower = to_ascii_lower(label) orelse return false;
    defer gpa.free(lower);

    const supported = [_][]const u8{
        "utf-8", "utf8", "unicode-1-1-utf-8",
    };
    for (supported) |s| {
        if (std.mem.eql(u8, lower, s)) return true;
    }
    return false;
}

fn to_ascii_lower(s: []const u8) ?[]u8 {
    const out = gpa.alloc(u8, s.len) catch return null;
    for (s, 0..) |c, i| {
        out[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return out;
}

fn text_decoder_decode(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1 or qjs.JS_IsUndefined(argv[0])) {
        return qjs.JS_NewString(ctx, "");
    }

    const fatal_val = qjs.JS_GetPropertyStr(ctx, this, "fatal");
    defer qjs.JS_FreeValue(ctx, fatal_val);
    const fatal = qjs.JS_ToBool(ctx, fatal_val) != 0;

    const input = argv[0];
    var data: []const u8 = &.{};

    if (qjs.JS_IsArrayBuffer(input)) {
        var len: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(ctx, &len, input) orelse
            return qjs.JS_NewString(ctx, "");
        data = @as([*]const u8, @ptrCast(ptr))[0..len];
    } else {
        var byte_offset: usize = 0;
        var byte_len: usize = 0;
        var total_size: usize = 0;
        const ab = qjs.JS_GetTypedArrayBuffer(ctx, input, &byte_offset, &byte_len, &total_size);
        if (js.js_is_exception(ab)) {
            return qjs.JS_ThrowTypeError(ctx, "argument must be a BufferSource");
        }
        defer qjs.JS_FreeValue(ctx, ab);

        var ab_size: usize = 0;
        const buf_ptr = qjs.JS_GetArrayBuffer(ctx, &ab_size, ab) orelse
            return qjs.JS_NewString(ctx, "");
        data = @as([*]const u8, @ptrCast(buf_ptr + byte_offset))[0..byte_len];
    }

    // Strip UTF-8 BOM (EF BB BF)
    if (data.len >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
        data = data[3..];
    }

    if (fatal) {
        if (!validate_utf8(data)) {
            return qjs.JS_ThrowTypeError(ctx, "The encoded data was not valid UTF-8");
        }
    } else {
        if (replace_invalid_utf8(data)) |r| {
            defer gpa.free(r);
            return qjs.JS_NewStringLen(ctx, r.ptr, r.len);
        }
    }

    return qjs.JS_NewStringLen(ctx, data.ptr, data.len);
}

fn validate_utf8(data: []const u8) bool {
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }

        const seq_len: usize = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else return false;

        if (i + seq_len > data.len) return false;

        // Validate continuation bytes
        for (1..seq_len) |j| {
            if (data[i + j] & 0xC0 != 0x80) return false;
        }

        // Decode and check for overlong / surrogate / out-of-range
        const cp: u32 = switch (seq_len) {
            2 => (@as(u32, b & 0x1F) << 6) | @as(u32, data[i + 1] & 0x3F),
            3 => (@as(u32, b & 0x0F) << 12) | (@as(u32, data[i + 1] & 0x3F) << 6) | @as(u32, data[i + 2] & 0x3F),
            4 => (@as(u32, b & 0x07) << 18) | (@as(u32, data[i + 1] & 0x3F) << 12) | (@as(u32, data[i + 2] & 0x3F) << 6) | @as(u32, data[i + 3] & 0x3F),
            else => return false,
        };

        // Overlong check
        if (seq_len == 2 and cp < 0x80) return false;
        if (seq_len == 3 and cp < 0x800) return false;
        if (seq_len == 4 and cp < 0x10000) return false;

        // Surrogate range
        if (cp >= 0xD800 and cp <= 0xDFFF) return false;

        // Out of Unicode range
        if (cp > 0x10FFFF) return false;

        i += seq_len;
    }
    return true;
}

fn replace_invalid_utf8(data: []const u8) ?[]u8 {
    // First pass: check if any replacements needed
    var needs_replace = false;
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        const sl: usize = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else {
            needs_replace = true;
            i += 1;
            continue;
        };
        if (i + sl > data.len or !validate_continuation(data[i + 1 .. @min(i + sl, data.len)])) {
            needs_replace = true;
            i += 1;
            continue;
        }
        const cp = decode_codepoint(data[i..], sl);
        if (is_overlong(cp, sl) or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF) {
            needs_replace = true;
        }
        i += sl;
    }

    if (!needs_replace) return null;

    // Worst case: every byte becomes U+FFFD (3 bytes)
    const buf = gpa.alloc(u8, @max(data.len * 3, 1)) catch return null;
    const replacement = [_]u8{ 0xEF, 0xBF, 0xBD }; // U+FFFD in UTF-8
    var oi: usize = 0;

    i = 0;
    while (i < data.len) {
        const b = data[i];
        if (b < 0x80) {
            buf[oi] = b;
            oi += 1;
            i += 1;
            continue;
        }
        const sl: usize = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else {
            @memcpy(buf[oi .. oi + 3], &replacement);
            oi += 3;
            i += 1;
            continue;
        };
        if (i + sl > data.len or !validate_continuation(data[i + 1 .. @min(i + sl, data.len)])) {
            @memcpy(buf[oi .. oi + 3], &replacement);
            oi += 3;
            i += 1;
            continue;
        }
        const cp = decode_codepoint(data[i..], sl);
        if (is_overlong(cp, sl) or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF) {
            @memcpy(buf[oi .. oi + 3], &replacement);
            oi += 3;
            i += sl;
            continue;
        }
        @memcpy(buf[oi .. oi + sl], data[i .. i + sl]);
        oi += sl;
        i += sl;
    }

    if (oi < buf.len) {
        const result = gpa.realloc(buf, oi) catch {
            gpa.free(buf);
            return null;
        };
        return result;
    }
    return buf;
}

fn validate_continuation(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b & 0xC0 != 0x80) return false;
    }
    return true;
}

fn decode_codepoint(data: []const u8, sl: usize) u32 {
    return switch (sl) {
        2 => (@as(u32, data[0] & 0x1F) << 6) | @as(u32, data[1] & 0x3F),
        3 => (@as(u32, data[0] & 0x0F) << 12) | (@as(u32, data[1] & 0x3F) << 6) | @as(u32, data[2] & 0x3F),
        4 => (@as(u32, data[0] & 0x07) << 18) | (@as(u32, data[1] & 0x3F) << 12) | (@as(u32, data[2] & 0x3F) << 6) | @as(u32, data[3] & 0x3F),
        else => 0xFFFD,
    };
}

fn is_overlong(cp: u32, sl: usize) bool {
    return (sl == 2 and cp < 0x80) or (sl == 3 and cp < 0x800) or (sl == 4 and cp < 0x10000);
}

// ──────────────────── atob / btoa ────────────────────

fn install_atob_btoa(ctx: *qjs.JSContext, global: qjs.JSValue) void {
    _ = qjs.JS_SetPropertyStr(ctx, global, "btoa", qjs.JS_NewCFunction(ctx, &btoa_impl, "btoa", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "atob", qjs.JS_NewCFunction(ctx, &atob_impl, "atob", 1));
}

const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn btoa_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "btoa requires 1 argument");

    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen(ctx, &len, argv[0]) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to convert argument to string");
    defer qjs.JS_FreeCString(ctx, ptr);

    const src = @as([*]const u8, @ptrCast(ptr))[0..len];

    // btoa must throw if any code point > 0xFF — but QuickJS gives us UTF-8.
    // We need to check: any multi-byte UTF-8 sequence with codepoint > 255 is invalid.
    // Walk the UTF-8 and reject codepoints > 0xFF.
    var i: usize = 0;
    var latin1_len: usize = 0;
    while (i < src.len) {
        const sl = utf8_seq_len(src[i]);
        if (sl == 0) {
            i += 1;
            continue;
        }
        if (sl > 2 or (sl == 2 and src[i] >= 0xC4)) {
            return throw_invalid_char_error(ctx);
        }
        latin1_len += 1;
        i += sl;
    }

    // Convert UTF-8 to Latin-1 bytes for base64 encoding
    const latin1 = gpa.alloc(u8, latin1_len) catch
        return qjs.JS_ThrowOutOfMemory(ctx);
    defer gpa.free(latin1);

    i = 0;
    var li: usize = 0;
    while (i < src.len) {
        const sl = utf8_seq_len(src[i]);
        if (sl == 1) {
            latin1[li] = src[i];
        } else if (sl == 2) {
            latin1[li] = (@as(u8, src[i] & 0x1F) << 6) | (src[i + 1] & 0x3F);
        } else {
            i += if (sl == 0) 1 else sl;
            continue;
        }
        li += 1;
        i += sl;
    }

    const out_len = ((latin1_len + 2) / 3) * 4;
    const out = gpa.alloc(u8, out_len) catch
        return qjs.JS_ThrowOutOfMemory(ctx);
    defer gpa.free(out);

    var oi: usize = 0;
    var si: usize = 0;
    while (si < latin1_len) {
        const a: u32 = latin1[si];
        si += 1;
        const b: u32 = if (si < latin1_len) latin1[si] else 0;
        const has_b = si < latin1_len;
        if (has_b) si += 1;
        const c: u32 = if (si < latin1_len) latin1[si] else 0;
        const has_c = si < latin1_len;
        if (has_c) si += 1;

        const triple = (a << 16) | (b << 8) | c;
        out[oi] = b64_alphabet[@intCast((triple >> 18) & 0x3F)];
        out[oi + 1] = b64_alphabet[@intCast((triple >> 12) & 0x3F)];
        out[oi + 2] = if (has_b) b64_alphabet[@intCast((triple >> 6) & 0x3F)] else '=';
        out[oi + 3] = if (has_c) b64_alphabet[@intCast(triple & 0x3F)] else '=';
        oi += 4;
    }

    return qjs.JS_NewStringLen(ctx, out.ptr, out_len);
}

fn throw_invalid_char_error(ctx: ?*qjs.JSContext) qjs.JSValue {
    // Throw DOMException with name "InvalidCharacterError"
    // For now, throw a simple error — DOMException support can come later
    const err = qjs.JS_NewError(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, err, "message", qjs.JS_NewString(ctx, "The string to be encoded contains characters outside of the Latin1 range."));
    _ = qjs.JS_SetPropertyStr(ctx, err, "name", qjs.JS_NewString(ctx, "InvalidCharacterError"));
    return qjs.JS_Throw(ctx, err);
}

const b64_decode_table = blk: {
    var table: [256]u8 = [_]u8{0xFF} ** 256;
    for (b64_alphabet, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};

fn atob_impl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "atob requires 1 argument");

    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen(ctx, &len, argv[0]) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to convert argument to string");
    defer qjs.JS_FreeCString(ctx, ptr);

    const src = @as([*]const u8, @ptrCast(ptr))[0..len];

    // Strip ASCII whitespace per spec
    var clean = gpa.alloc(u8, len) catch return qjs.JS_ThrowOutOfMemory(ctx);
    defer gpa.free(clean);
    var clean_len: usize = 0;
    for (src) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C) continue;
        clean[clean_len] = c;
        clean_len += 1;
    }

    // Per spec: after removing whitespace, length % 4 == 1 is always invalid
    if (clean_len % 4 == 1) return throw_invalid_char_error(ctx);

    // Add padding if missing (length % 4 == 2 or 3 are valid without padding)
    const padded_len = ((clean_len + 3) / 4) * 4;
    if (padded_len > clean.len) {
        gpa.free(clean);
        clean = gpa.alloc(u8, padded_len) catch return qjs.JS_ThrowOutOfMemory(ctx);
        clean_len = 0;
        for (src) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C) continue;
            clean[clean_len] = c;
            clean_len += 1;
        }
    }
    while (clean_len < padded_len) {
        clean[clean_len] = '=';
        clean_len += 1;
    }

    const out_max = (clean_len / 4) * 3;
    const out = gpa.alloc(u8, out_max) catch return qjs.JS_ThrowOutOfMemory(ctx);
    defer gpa.free(out);

    var oi: usize = 0;
    var si: usize = 0;
    while (si < clean_len) {
        var vals: [4]u8 = undefined;
        var pad_count: u8 = 0;
        for (0..4) |j| {
            const c = clean[si + j];
            if (c == '=') {
                vals[j] = 0;
                pad_count += 1;
            } else {
                vals[j] = b64_decode_table[c];
                if (vals[j] == 0xFF) return throw_invalid_char_error(ctx);
                if (pad_count > 0) return throw_invalid_char_error(ctx);
            }
        }
        si += 4;

        const triple = (@as(u32, vals[0]) << 18) | (@as(u32, vals[1]) << 12) | (@as(u32, vals[2]) << 6) | @as(u32, vals[3]);

        out[oi] = @intCast((triple >> 16) & 0xFF);
        oi += 1;
        if (pad_count < 2) {
            out[oi] = @intCast((triple >> 8) & 0xFF);
            oi += 1;
        }
        if (pad_count < 1) {
            out[oi] = @intCast(triple & 0xFF);
            oi += 1;
        }
    }

    // Result is a "binary string" — each byte as a code point
    const result = gpa.alloc(u8, oi * 2) catch return qjs.JS_ThrowOutOfMemory(ctx);
    defer gpa.free(result);

    // Convert bytes to Latin-1 string via UTF-8 encoding
    var ri: usize = 0;
    for (out[0..oi]) |byte| {
        if (byte < 0x80) {
            result[ri] = byte;
            ri += 1;
        } else {
            result[ri] = 0xC0 | (byte >> 6);
            result[ri + 1] = 0x80 | (byte & 0x3F);
            ri += 2;
        }
    }

    return qjs.JS_NewStringLen(ctx, result.ptr, ri);
}
