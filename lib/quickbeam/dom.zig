const types = @import("types.zig");
const js = @import("js_helpers.zig");
const std = types.std;
const qjs = types.qjs;
const beam = types.beam;
const e = types.e;

const lxb = @cImport(@cInclude("lexbor_bridge.h"));

// ──────────────────── JS class IDs ────────────────────

pub var document_class_id: qjs.JSClassID = 0;
pub var element_class_id: qjs.JSClassID = 0;

// ──────────────────── Opaque data attached to JS objects ────────────────────

pub const DocumentData = struct {
    doc: *lxb.lxb_html_document_t,
    css_parser: *lxb.lxb_css_parser_t,
    selectors: *lxb.lxb_selectors_t,
};

// ──────────────────── Helpers ────────────────────

fn get_document_data(ctx: *qjs.JSContext) ?*DocumentData {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const doc_val = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_val);
    if (!qjs.JS_IsObject(doc_val)) return null;
    const ptr = qjs.JS_GetOpaque(doc_val, document_class_id);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

fn node_to_js(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    const obj = qjs.JS_NewObjectClass(ctx, @intCast(element_class_id));
    if (js.js_is_exception(obj)) return obj;
    _ = qjs.JS_SetOpaque(obj, @ptrCast(node));
    install_element_proto(ctx, obj);
    return obj;
}

fn js_to_node(val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    const ptr = qjs.JS_GetOpaque(val, element_class_id);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

fn to_lxb(s: []const u8) [*c]const lxb.lxb_char_t {
    return @ptrCast(s.ptr);
}

fn str_arg(ctx: ?*qjs.JSContext, argv: [*c]qjs.JSValue, idx: usize) ?[]const u8 {
    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen(ctx, &len, argv[idx]);
    if (ptr == null) return null;
    return ptr[0..len];
}

fn free_str(ctx: ?*qjs.JSContext, ptr: [*c]const u8) void {
    qjs.JS_FreeCString(ctx, ptr);
}

// ──────────────────── Serialization callback ────────────────────

fn serialize_callback(data: [*c]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
    list.appendSlice(types.gpa, data[0..len]) catch return 1;
    return 0;
}

// ──────────────────── document methods ────────────────────

fn doc_create_element(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "createElement requires a tag name");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const tag = str_arg(ctx, argv, 0) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid tag name");
    defer free_str(ctx, tag.ptr);

    const dom_doc = lxb.qb_dom_document(dd.doc);
    const elem = lxb.qb_create_element(dom_doc, to_lxb(tag), tag.len) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to create element");

    return node_to_js(ctx.?, lxb.qb_element_as_node(elem).?);
}

fn doc_create_text_node(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "createTextNode requires text");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const text = str_arg(ctx, argv, 0) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid text");
    defer free_str(ctx, text.ptr);

    const dom_doc = lxb.qb_dom_document(dd.doc);
    const text_node = lxb.qb_create_text_node(dom_doc, to_lxb(text), text.len) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to create text node");

    return node_to_js(ctx.?, lxb.qb_text_as_node(text_node).?);
}

fn doc_create_element_ns(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "createElementNS requires a namespace and a qualified name");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const dom_doc = lxb.qb_dom_document(dd.doc);

    // First arg: namespace URI (may be null)
    var ns: ?[]const u8 = null;
    if (!qjs.JS_IsNull(argv[0])) {
        ns = str_arg(ctx, argv, 0);
    }
    defer if (ns) |s| free_str(ctx, s.ptr);

    // Second arg: qualified name (e.g. "svg" or "xlink:href")
    const qname = str_arg(ctx, argv, 1) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid qualified name");
    defer free_str(ctx, qname.ptr);

    // Split qualified name into prefix:localName
    var prefix: ?[]const u8 = null;
    var local_name = qname;
    if (std.mem.indexOfScalar(u8, qname, ':')) |colon| {
        prefix = qname[0..colon];
        local_name = qname[colon + 1 ..];
    }

    const ns_ptr = if (ns) |s| to_lxb(s) else null;
    const ns_len = if (ns) |s| s.len else 0;
    const prefix_ptr = if (prefix) |p| to_lxb(p) else null;
    const prefix_len = if (prefix) |p| p.len else 0;

    const elem = lxb.qb_create_element_ns(
        dom_doc,
        to_lxb(local_name),
        local_name.len,
        ns_ptr,
        ns_len,
        prefix_ptr,
        prefix_len,
    ) orelse return qjs.JS_ThrowTypeError(ctx, "Failed to create element");

    return node_to_js(ctx.?, lxb.qb_element_as_node(elem).?);
}

fn doc_create_document_fragment(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const dom_doc = lxb.qb_dom_document(dd.doc);
    const frag = lxb.qb_create_document_fragment(dom_doc) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to create document fragment");
    return node_to_js(ctx.?, frag);
}

fn doc_create_comment(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const dom_doc = lxb.qb_dom_document(dd.doc);

    if (argc >= 1) {
        const data = str_arg(ctx, argv, 0) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid comment data");
        defer free_str(ctx, data.ptr);
        const comment = lxb.qb_create_comment(dom_doc, to_lxb(data), data.len) orelse
            return qjs.JS_ThrowTypeError(ctx, "Failed to create comment");
        return node_to_js(ctx.?, comment);
    } else {
        const comment = lxb.qb_create_comment(dom_doc, to_lxb(""), 0) orelse
            return qjs.JS_ThrowTypeError(ctx, "Failed to create comment");
        return node_to_js(ctx.?, comment);
    }
}

fn doc_get_element_by_id(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "getElementById requires an id");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const id = str_arg(ctx, argv, 0) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid id");
    defer free_str(ctx, id.ptr);

    const body_node = lxb.qb_body(dd.doc) orelse return js.js_null();
    const body_elem = lxb.qb_node_as_element(body_node) orelse return js.js_null();
    const dom_doc = lxb.qb_dom_document(dd.doc);
    const collection = lxb.qb_collection_make(dom_doc, 1) orelse return js.js_null();
    defer lxb.qb_collection_destroy(collection);

    const status = lxb.qb_elements_by_attr(body_elem, collection, to_lxb("id"), 2, to_lxb(id), id.len);
    if (status != 0 or lxb.qb_collection_length(collection) == 0)
        return js.js_null();

    const elem = lxb.qb_collection_element(collection, 0);
    return node_to_js(ctx.?, lxb.qb_element_as_node(elem.?).?);
}

fn doc_get_elements_by_class_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "getElementsByClassName requires a class name");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_NewArray(ctx);
    const name = str_arg(ctx, argv, 0) orelse return qjs.JS_NewArray(ctx);
    defer free_str(ctx, name.ptr);

    const root_elem = lxb.qb_node_as_element(lxb.qb_body(dd.doc) orelse return qjs.JS_NewArray(ctx)) orelse return qjs.JS_NewArray(ctx);
    return elements_by_class_name(ctx, dd, root_elem, name);
}

fn el_get_elements_by_class_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "getElementsByClassName requires a class name");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_NewArray(ctx);
    const node = js_to_node(this) orelse return qjs.JS_NewArray(ctx);
    const root_elem = lxb.qb_node_as_element(node) orelse return qjs.JS_NewArray(ctx);
    const name = str_arg(ctx, argv, 0) orelse return qjs.JS_NewArray(ctx);
    defer free_str(ctx, name.ptr);
    return elements_by_class_name(ctx, dd, root_elem, name);
}

fn elements_by_class_name(ctx: ?*qjs.JSContext, dd: *DocumentData, root_elem: *lxb.lxb_dom_element_t, name: []const u8) qjs.JSValue {
    const dom_doc = lxb.qb_dom_document(dd.doc);
    const collection = lxb.qb_collection_make(dom_doc, 16) orelse return qjs.JS_NewArray(ctx);
    defer lxb.qb_collection_destroy(collection);
    _ = lxb.qb_elements_by_class_name(root_elem, collection, to_lxb(name), name.len);
    return collection_to_js_array(ctx, collection);
}

fn doc_get_elements_by_tag_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "getElementsByTagName requires a tag name");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_NewArray(ctx);
    const name = str_arg(ctx, argv, 0) orelse return qjs.JS_NewArray(ctx);
    defer free_str(ctx, name.ptr);

    const root_elem = lxb.qb_node_as_element(lxb.qb_body(dd.doc) orelse return qjs.JS_NewArray(ctx)) orelse return qjs.JS_NewArray(ctx);
    return elements_by_tag_name(ctx, dd, root_elem, name);
}

fn el_get_elements_by_tag_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "getElementsByTagName requires a tag name");
    const dd = get_document_data(ctx.?) orelse return qjs.JS_NewArray(ctx);
    const node = js_to_node(this) orelse return qjs.JS_NewArray(ctx);
    const root_elem = lxb.qb_node_as_element(node) orelse return qjs.JS_NewArray(ctx);
    const name = str_arg(ctx, argv, 0) orelse return qjs.JS_NewArray(ctx);
    defer free_str(ctx, name.ptr);
    return elements_by_tag_name(ctx, dd, root_elem, name);
}

fn elements_by_tag_name(ctx: ?*qjs.JSContext, dd: *DocumentData, root_elem: *lxb.lxb_dom_element_t, name: []const u8) qjs.JSValue {
    const dom_doc = lxb.qb_dom_document(dd.doc);
    const collection = lxb.qb_collection_make(dom_doc, 16) orelse return qjs.JS_NewArray(ctx);
    defer lxb.qb_collection_destroy(collection);
    _ = lxb.qb_elements_by_tag_name(root_elem, collection, to_lxb(name), name.len);
    return collection_to_js_array(ctx, collection);
}

fn collection_to_js_array(ctx: ?*qjs.JSContext, collection: *lxb.lxb_dom_collection_t) qjs.JSValue {
    const arr = qjs.JS_NewArray(ctx);
    const len = lxb.qb_collection_length(collection);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = lxb.qb_collection_element(collection, i) orelse continue;
        const node = lxb.qb_element_as_node(elem) orelse continue;
        _ = qjs.JS_SetPropertyUint32(ctx, arr, @intCast(i), node_to_js(ctx.?, node));
    }
    return arr;
}

// ──────────────────── querySelector / querySelectorAll ────────────────────

const SelectorCtx = struct {
    results: *std.ArrayList(*lxb.lxb_dom_node_t),
    find_one: bool,
};

fn selector_callback(node_ptr: ?*anyopaque, _: c_uint, ctx_ptr: ?*anyopaque) callconv(.c) lxb.lxb_status_t {
    const sctx: *SelectorCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(node_ptr.?));
    sctx.results.append(types.gpa, node) catch return 1;
    if (sctx.find_one) return 1;
    return 0;
}

fn do_query_selector(ctx: ?*qjs.JSContext, root: *lxb.lxb_dom_node_t, dd: *DocumentData, selector: []const u8, find_one: bool) qjs.JSValue {
    const list = lxb.qb_css_selectors_parse(dd.css_parser, to_lxb(selector), selector.len);
    if (lxb.qb_css_parser_status(dd.css_parser) != 0 or list == null)
        return if (find_one) js.js_null() else qjs.JS_NewArray(ctx);

    defer lxb.qb_css_selector_list_destroy(dd.css_parser, list);

    var results = std.ArrayList(*lxb.lxb_dom_node_t){};

    var sctx = SelectorCtx{ .results = &results, .find_one = find_one };
    _ = lxb.qb_selectors_find(dd.selectors, root, list, selector_callback, @ptrCast(&sctx));

    if (find_one) {
        defer results.deinit(types.gpa);
        if (results.items.len == 0) return js.js_null();
        return node_to_js(ctx.?, results.items[0]);
    }

    return make_owned_node_list(ctx.?, results);
}

fn make_owned_node_list(ctx: *qjs.JSContext, nodes: std.ArrayList(*lxb.lxb_dom_node_t)) qjs.JSValue {
    const arr = qjs.JS_NewArray(ctx);
    if (js.js_is_exception(arr)) {
        var mut_nodes = nodes;
        mut_nodes.deinit(types.gpa);
        return arr;
    }
    for (nodes.items, 0..) |node, i| {
        const elem_js = node_to_js(ctx, node);
        _ = qjs.JS_SetPropertyUint32(ctx, arr, @intCast(i), elem_js);
    }
    var mut_nodes = nodes;
    mut_nodes.deinit(types.gpa);
    return arr;
}

fn query_selector(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "querySelector requires a selector");

    const selector = str_arg(ctx, argv, 0) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid selector");
    defer free_str(ctx, selector.ptr);

    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const root = js_to_node(this) orelse (lxb.qb_doc_as_node(dd.doc) orelse return js.js_null());
    return do_query_selector(ctx, root, dd, selector, true);
}

fn query_selector_all(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "querySelectorAll requires a selector");

    const selector = str_arg(ctx, argv, 0) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid selector");
    defer free_str(ctx, selector.ptr);

    const dd = get_document_data(ctx.?) orelse return qjs.JS_ThrowTypeError(ctx, "No document");
    const root = js_to_node(this) orelse (lxb.qb_doc_as_node(dd.doc) orelse return qjs.JS_NewArray(ctx));
    return do_query_selector(ctx, root, dd, selector, false);
}

// ──────────────────── Element property accessors ────────────────────

fn el_get_tag_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    if (lxb.qb_node_type(node) != lxb.QB_NODE_TYPE_ELEMENT) return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    var len: usize = 0;
    const name = lxb.qb_element_qualified_name(elem, &len);
    if (name == null) return js.js_undefined();
    return qjs.JS_NewStringLen(ctx, @ptrCast(name), len);
}

fn el_get_id(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    var len: usize = 0;
    const val = lxb.qb_element_get_attribute(elem, to_lxb("id"), 2, &len);
    if (val == null) return qjs.JS_NewStringLen(ctx, "", 0);
    return qjs.JS_NewStringLen(ctx, @ptrCast(val), len);
}

fn el_set_id(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    const val = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, val.ptr);
    _ = lxb.qb_element_set_attribute(elem, to_lxb("id"), 2, to_lxb(val), val.len);
    return js.js_undefined();
}

fn el_get_class_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    var len: usize = 0;
    const val = lxb.qb_element_get_attribute(elem, to_lxb("class"), 5, &len);
    if (val == null) return qjs.JS_NewStringLen(ctx, "", 0);
    return qjs.JS_NewStringLen(ctx, @ptrCast(val), len);
}

fn el_get_attribute(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "getAttribute requires a name");
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    const name = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, name.ptr);

    var len: usize = 0;
    const val = lxb.qb_element_get_attribute(elem, to_lxb(name), name.len, &len);
    if (val == null) return js.js_null();
    return qjs.JS_NewStringLen(ctx, @ptrCast(val), len);
}

fn el_set_attribute(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "setAttribute requires name and value");
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    const name = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, name.ptr);
    const val = str_arg(ctx, argv, 1) orelse return js.js_undefined();
    defer free_str(ctx, val.ptr);
    _ = lxb.qb_element_set_attribute(elem, to_lxb(name), name.len, to_lxb(val), val.len);
    return js.js_undefined();
}

fn el_remove_attribute(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "removeAttribute requires a name");
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    const name = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, name.ptr);
    _ = lxb.qb_element_remove_attribute(elem, to_lxb(name), name.len);
    return js.js_undefined();
}

fn el_has_attribute(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "hasAttribute requires a name");
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    const name = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, name.ptr);
    var len: usize = 0;
    const val = lxb.qb_element_get_attribute(elem, to_lxb(name), name.len, &len);
    return if (val != null) js.js_true() else js.js_false();
}

// ──────────────────── Tree manipulation ────────────────────

fn el_append_child(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "appendChild requires a node");
    const parent = js_to_node(this) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid parent");
    const child = js_to_node(argv[0]) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid child");

    if (lxb.qb_node_type(child) == lxb.QB_NODE_TYPE_DOCUMENT_FRAGMENT) {
        var c: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(child);
        while (c) |node| {
            const next = lxb.qb_node_next(node);
            lxb.qb_node_insert_child(parent, node);
            c = next;
        }
    } else {
        if (lxb.qb_node_parent(child) != null) lxb.qb_node_remove(child);
        lxb.qb_node_insert_child(parent, child);
    }
    return qjs.JS_DupValue(ctx, argv[0]);
}

fn el_remove_child(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "removeChild requires a node");
    const child = js_to_node(argv[0]) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid child");
    lxb.qb_node_remove(child);
    return qjs.JS_DupValue(ctx, argv[0]);
}

fn el_insert_before(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "insertBefore requires 2 arguments");
    const parent = js_to_node(this) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid parent");
    const new_node = js_to_node(argv[0]) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid new node");

    if (lxb.qb_node_type(new_node) == lxb.QB_NODE_TYPE_DOCUMENT_FRAGMENT) {
        var c: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(new_node);
        if (qjs.JS_IsNull(argv[1])) {
            while (c) |node| {
                const next = lxb.qb_node_next(node);
                lxb.qb_node_insert_child(parent, node);
                c = next;
            }
        } else {
            const ref_node = js_to_node(argv[1]) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid reference node");
            while (c) |node| {
                const next = lxb.qb_node_next(node);
                lxb.qb_node_insert_before(ref_node, node);
                c = next;
            }
        }
    } else {
        if (qjs.JS_IsNull(argv[1])) {
            if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
            lxb.qb_node_insert_child(parent, new_node);
        } else {
            const ref_node = js_to_node(argv[1]) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid reference node");
            if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
            lxb.qb_node_insert_before(ref_node, new_node);
        }
    }
    return qjs.JS_DupValue(ctx, argv[0]);
}

fn el_replace_child(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "replaceChild requires 2 arguments");
    _ = this;
    const new_node = js_to_node(argv[0]) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid new node");
    const old_node = js_to_node(argv[1]) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid old node");
    if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
    lxb.qb_node_insert_before(old_node, new_node);
    lxb.qb_node_remove(old_node);
    return qjs.JS_DupValue(ctx, argv[1]);
}

fn el_clone_node(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return qjs.JS_ThrowTypeError(ctx, "Invalid node");
    var deep: c_int = 0;
    if (argc >= 1) {
        deep = if (qjs.JS_ToBool(ctx, argv[0]) != 0) 1 else 0;
    }
    const cloned = lxb.qb_node_clone(node, deep) orelse
        return qjs.JS_ThrowTypeError(ctx, "Failed to clone node");
    return node_to_js(ctx.?, cloned);
}

fn el_contains(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1 or qjs.JS_IsNull(argv[0])) return js.js_false();
    const node = js_to_node(this) orelse return js.js_false();
    const other = js_to_node(argv[0]) orelse return js.js_false();
    _ = ctx;

    if (node == other) return js.js_true();

    var current: ?*lxb.lxb_dom_node_t = lxb.qb_node_parent(other);
    while (current) |c| {
        if (c == node) return js.js_true();
        current = lxb.qb_node_parent(c);
    }
    return js.js_false();
}

fn el_remove(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = ctx;
    const node = js_to_node(this) orelse return js.js_undefined();
    lxb.qb_node_remove(node);
    return js.js_undefined();
}

fn el_before(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const new_node = js_to_node(argv[i]) orelse {
            const text = str_arg(ctx, argv, i) orelse continue;
            defer free_str(ctx, text.ptr);
            const dd = get_document_data(ctx.?) orelse continue;
            const text_node = lxb.qb_create_text_node(lxb.qb_dom_document(dd.doc), to_lxb(text), text.len) orelse continue;
            lxb.qb_node_insert_before(node, lxb.qb_text_as_node(text_node).?);
            continue;
        };
        if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
        lxb.qb_node_insert_before(node, new_node);
    }
    return js.js_undefined();
}

fn el_after(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    var ref = node;
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const new_node = js_to_node(argv[i]) orelse {
            const text = str_arg(ctx, argv, i) orelse continue;
            defer free_str(ctx, text.ptr);
            const dd = get_document_data(ctx.?) orelse continue;
            const text_node = lxb.qb_create_text_node(lxb.qb_dom_document(dd.doc), to_lxb(text), text.len) orelse continue;
            const tn = lxb.qb_text_as_node(text_node).?;
            lxb.qb_node_insert_after(ref, tn);
            ref = tn;
            continue;
        };
        if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
        lxb.qb_node_insert_after(ref, new_node);
        ref = new_node;
    }
    return js.js_undefined();
}

fn el_prepend(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const parent = js_to_node(this) orelse return js.js_undefined();
    const first = lxb.qb_node_first_child(parent);

    var i: usize = @as(usize, @intCast(argc));
    while (i > 0) {
        i -= 1;
        const new_node = js_to_node(argv[i]) orelse {
            const text = str_arg(ctx, argv, i) orelse continue;
            defer free_str(ctx, text.ptr);
            const dd = get_document_data(ctx.?) orelse continue;
            const text_node = lxb.qb_create_text_node(lxb.qb_dom_document(dd.doc), to_lxb(text), text.len) orelse continue;
            const tn = lxb.qb_text_as_node(text_node).?;
            if (first) |f| {
                lxb.qb_node_insert_before(f, tn);
            } else {
                lxb.qb_node_insert_child(parent, tn);
            }
            continue;
        };
        if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
        if (first) |f| {
            lxb.qb_node_insert_before(f, new_node);
        } else {
            lxb.qb_node_insert_child(parent, new_node);
        }
    }
    return js.js_undefined();
}

fn el_append(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const parent = js_to_node(this) orelse return js.js_undefined();
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const new_node = js_to_node(argv[i]) orelse {
            const text = str_arg(ctx, argv, i) orelse continue;
            defer free_str(ctx, text.ptr);
            const dd = get_document_data(ctx.?) orelse continue;
            const text_node = lxb.qb_create_text_node(lxb.qb_dom_document(dd.doc), to_lxb(text), text.len) orelse continue;
            lxb.qb_node_insert_child(parent, lxb.qb_text_as_node(text_node).?);
            continue;
        };
        if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
        lxb.qb_node_insert_child(parent, new_node);
    }
    return js.js_undefined();
}

fn el_replace_with(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const new_node = js_to_node(argv[i]) orelse {
            const text = str_arg(ctx, argv, i) orelse continue;
            defer free_str(ctx, text.ptr);
            const dd = get_document_data(ctx.?) orelse continue;
            const text_node = lxb.qb_create_text_node(lxb.qb_dom_document(dd.doc), to_lxb(text), text.len) orelse continue;
            lxb.qb_node_insert_before(node, lxb.qb_text_as_node(text_node).?);
            continue;
        };
        if (lxb.qb_node_parent(new_node) != null) lxb.qb_node_remove(new_node);
        lxb.qb_node_insert_before(node, new_node);
    }
    lxb.qb_node_remove(node);
    return js.js_undefined();
}

fn el_matches(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "matches requires a selector");
    const node = js_to_node(this) orelse return js.js_false();
    const dd = get_document_data(ctx.?) orelse return js.js_false();
    const selector = str_arg(ctx, argv, 0) orelse return js.js_false();
    defer free_str(ctx, selector.ptr);

    const list = lxb.qb_css_selectors_parse(dd.css_parser, to_lxb(selector), selector.len);
    if (lxb.qb_css_parser_status(dd.css_parser) != 0 or list == null)
        return js.js_false();
    defer lxb.qb_css_selector_list_destroy(dd.css_parser, list);

    var results = std.ArrayList(*lxb.lxb_dom_node_t){};
    defer results.deinit(types.gpa);

    const parent = lxb.qb_node_parent(node) orelse return js.js_false();
    var sctx = SelectorCtx{ .results = &results, .find_one = false };
    _ = lxb.qb_selectors_find(dd.selectors, parent, list, selector_callback, @ptrCast(&sctx));

    for (results.items) |r| {
        if (r == node) return js.js_true();
    }
    return js.js_false();
}

fn el_closest(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_ThrowTypeError(ctx, "closest requires a selector");
    const dd = get_document_data(ctx.?) orelse return js.js_null();
    const selector = str_arg(ctx, argv, 0) orelse return js.js_null();
    defer free_str(ctx, selector.ptr);

    const list = lxb.qb_css_selectors_parse(dd.css_parser, to_lxb(selector), selector.len);
    if (lxb.qb_css_parser_status(dd.css_parser) != 0 or list == null)
        return js.js_null();
    defer lxb.qb_css_selector_list_destroy(dd.css_parser, list);

    const root = lxb.qb_doc_as_node(dd.doc) orelse return js.js_null();

    var current: ?*lxb.lxb_dom_node_t = js_to_node(this);
    while (current) |c| {
        if (lxb.qb_node_type(c) == lxb.QB_NODE_TYPE_ELEMENT) {
            var results = std.ArrayList(*lxb.lxb_dom_node_t){};
            defer results.deinit(types.gpa);
            var sctx = SelectorCtx{ .results = &results, .find_one = false };
            _ = lxb.qb_selectors_find(dd.selectors, root, list, selector_callback, @ptrCast(&sctx));

            for (results.items) |r| {
                if (r == c) return node_to_js(ctx.?, c);
            }
        }
        current = lxb.qb_node_parent(c);
    }
    return js.js_null();
}

fn el_get_inner_html(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    var buf = std.ArrayList(u8){};
    defer buf.deinit(types.gpa);

    var child: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(node);
    while (child) |c| {
        _ = lxb.qb_serialize_tree(c, serialize_callback, @ptrCast(&buf));
        child = lxb.qb_node_next(c);
    }

    return qjs.JS_NewStringLen(ctx, @ptrCast(buf.items.ptr), buf.items.len);
}

fn el_set_inner_html(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    const dd = get_document_data(ctx.?) orelse return js.js_undefined();
    const html_str = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, html_str.ptr);

    // Remove existing children
    while (lxb.qb_node_first_child(node) != null) {
        lxb.qb_node_remove(lxb.qb_node_first_child(node).?);
    }

    // Parse fragment
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    const frag_node = lxb.qb_parse_fragment(dd.doc, elem, to_lxb(html_str), html_str.len) orelse return js.js_undefined();

    // Move children from fragment to node
    var child: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(frag_node);
    while (child) |c| {
        const next = lxb.qb_node_next(c);
        lxb.qb_node_insert_child(node, c);
        child = next;
    }

    return js.js_undefined();
}

fn el_get_outer_html(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    var buf = std.ArrayList(u8){};
    defer buf.deinit(types.gpa);
    _ = lxb.qb_serialize_tree(node, serialize_callback, @ptrCast(&buf));
    return qjs.JS_NewStringLen(ctx, @ptrCast(buf.items.ptr), buf.items.len);
}

fn el_get_text_content(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    var len: usize = 0;
    const text = lxb.qb_node_text_content(node, &len);
    if (text == null) return qjs.JS_NewStringLen(ctx, "", 0);
    defer lxb.qb_dom_document_destroy_text(lxb.qb_node_owner_document(node), @constCast(text));
    return qjs.JS_NewStringLen(ctx, @ptrCast(text), len);
}

fn el_set_text_content(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    const text = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, text.ptr);
    _ = lxb.qb_node_text_content_set(node, to_lxb(text), text.len);
    return js.js_undefined();
}

// ──────────────────── Tree navigation ────────────────────

fn el_get_parent_node(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_null();
    const parent = lxb.qb_node_parent(node) orelse return js.js_null();
    return node_to_js(ctx.?, parent);
}

fn el_get_children(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return qjs.JS_NewArray(ctx);
    const arr = qjs.JS_NewArray(ctx);
    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(node);
    while (child) |c| {
        if (lxb.qb_node_type(c) == lxb.QB_NODE_TYPE_ELEMENT) {
            _ = qjs.JS_SetPropertyUint32(ctx, arr, idx, node_to_js(ctx.?, c));
            idx += 1;
        }
        child = lxb.qb_node_next(c);
    }
    return arr;
}

fn el_get_child_nodes(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return qjs.JS_NewArray(ctx);
    const arr = qjs.JS_NewArray(ctx);
    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(node);
    while (child) |c| {
        _ = qjs.JS_SetPropertyUint32(ctx, arr, idx, node_to_js(ctx.?, c));
        idx += 1;
        child = lxb.qb_node_next(c);
    }
    return arr;
}

fn el_get_first_child(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_null();
    const first = lxb.qb_node_first_child(node) orelse return js.js_null();
    return node_to_js(ctx.?, first);
}

fn el_get_next_sibling(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_null();
    const next = lxb.qb_node_next(node) orelse return js.js_null();
    return node_to_js(ctx.?, next);
}

fn el_get_last_child(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_null();
    const last = lxb.qb_node_last_child(node) orelse return js.js_null();
    return node_to_js(ctx.?, last);
}

fn el_get_previous_sibling(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_null();
    const prev = lxb.qb_node_prev(node) orelse return js.js_null();
    return node_to_js(ctx.?, prev);
}

fn el_get_node_type(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    return qjs.JS_NewInt32(ctx, @intCast(lxb.qb_node_type(node)));
}

fn el_get_node_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    const nt = lxb.qb_node_type(node);
    if (nt == lxb.QB_NODE_TYPE_ELEMENT) {
        const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
        var len: usize = 0;
        const name = lxb.qb_element_qualified_name(elem, &len);
        if (name == null) return js.js_undefined();
        return qjs.JS_NewStringLen(ctx, @ptrCast(name), len);
    } else if (nt == lxb.QB_NODE_TYPE_TEXT) {
        return qjs.JS_NewString(ctx, "#text");
    } else if (nt == lxb.QB_NODE_TYPE_COMMENT) {
        return qjs.JS_NewString(ctx, "#comment");
    } else if (nt == lxb.QB_NODE_TYPE_DOCUMENT) {
        return qjs.JS_NewString(ctx, "#document");
    } else if (nt == lxb.QB_NODE_TYPE_DOCUMENT_FRAGMENT) {
        return qjs.JS_NewString(ctx, "#document-fragment");
    }
    return js.js_undefined();
}

fn el_get_parent_element(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_null();
    const parent = lxb.qb_node_parent(node) orelse return js.js_null();
    if (lxb.qb_node_type(parent) != lxb.QB_NODE_TYPE_ELEMENT) return js.js_null();
    return node_to_js(ctx.?, parent);
}

fn el_set_class_name(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_undefined();
    const elem = lxb.qb_node_as_element(node) orelse return js.js_undefined();
    const val = str_arg(ctx, argv, 0) orelse return js.js_undefined();
    defer free_str(ctx, val.ptr);
    _ = lxb.qb_element_set_attribute(elem, to_lxb("class"), 5, to_lxb(val), val.len);
    return js.js_undefined();
}

// ──────────────────── CSS style helpers (called from JS CSSStyleDeclaration) ────────────────────

fn css_get_property(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_NewStringLen(ctx, "", 0);
    const dd = get_document_data(ctx.?) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    const style_str = str_arg(ctx, argv, 0) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    defer free_str(ctx, style_str.ptr);
    const prop_name = str_arg(ctx, argv, 1) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    defer free_str(ctx, prop_name.ptr);

    const decls = lxb.qb_css_parse_declarations(dd.css_parser, to_lxb(style_str), style_str.len);
    if (decls == null) return qjs.JS_NewStringLen(ctx, "", 0);
    defer lxb.qb_css_declarations_destroy(decls);

    var out_len: usize = 0;
    const result = lxb.qb_css_declaration_get_property(decls, to_lxb(prop_name), prop_name.len, &out_len);
    if (result == null) return qjs.JS_NewStringLen(ctx, "", 0);
    defer lxb.qb_css_free_string(result);
    return qjs.JS_NewStringLen(ctx, result, out_len);
}

fn css_get_priority(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_NewStringLen(ctx, "", 0);
    const dd = get_document_data(ctx.?) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    const style_str = str_arg(ctx, argv, 0) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    defer free_str(ctx, style_str.ptr);
    const prop_name = str_arg(ctx, argv, 1) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    defer free_str(ctx, prop_name.ptr);

    const decls = lxb.qb_css_parse_declarations(dd.css_parser, to_lxb(style_str), style_str.len);
    if (decls == null) return qjs.JS_NewStringLen(ctx, "", 0);
    defer lxb.qb_css_declarations_destroy(decls);

    var out_len: usize = 0;
    const result = lxb.qb_css_declaration_get_priority(decls, to_lxb(prop_name), prop_name.len, &out_len);
    if (result == null) return qjs.JS_NewStringLen(ctx, "", 0);
    defer lxb.qb_css_free_string(result);
    return qjs.JS_NewStringLen(ctx, result, out_len);
}

fn css_serialize_declarations(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_NewStringLen(ctx, "", 0);
    const dd = get_document_data(ctx.?) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    const style_str = str_arg(ctx, argv, 0) orelse return qjs.JS_NewStringLen(ctx, "", 0);
    defer free_str(ctx, style_str.ptr);

    const decls = lxb.qb_css_parse_declarations(dd.css_parser, to_lxb(style_str), style_str.len);
    if (decls == null) return qjs.JS_NewStringLen(ctx, "", 0);
    defer lxb.qb_css_declarations_destroy(decls);

    var out_len: usize = 0;
    const result = lxb.qb_css_declarations_serialize(decls, &out_len);
    if (result == null) return qjs.JS_NewStringLen(ctx, "", 0);
    defer lxb.qb_css_free_string(result);
    return qjs.JS_NewStringLen(ctx, result, out_len);
}

// ──────────────────── EventTarget methods (delegate to JS helpers) ────────────────────

fn call_global_helper(ctx: ?*qjs.JSContext, this: qjs.JSValue, name: [*:0]const u8, argc: c_int, argv: [*c]qjs.JSValue) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const helper = qjs.JS_GetPropertyStr(ctx, global, name);
    defer qjs.JS_FreeValue(ctx, helper);
    if (!qjs.JS_IsFunction(ctx, helper)) return js.js_undefined();
    return qjs.JS_Call(ctx, helper, this, argc, argv);
}

fn el_add_event_listener(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return call_global_helper(ctx, this, "__qb_addEventListener", argc, argv);
}

fn el_remove_event_listener(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return call_global_helper(ctx, this, "__qb_removeEventListener", argc, argv);
}

fn el_dispatch_event(ctx: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return call_global_helper(ctx, this, "__qb_dispatchEvent", argc, argv);
}

fn el_get_style(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const helper = qjs.JS_GetPropertyStr(ctx, global, "__qb_get_style");
    defer qjs.JS_FreeValue(ctx, helper);
    if (!qjs.JS_IsFunction(ctx, helper)) return qjs.JS_NewObject(ctx);
    var args = [_]qjs.JSValue{this};
    return qjs.JS_Call(ctx, helper, global, 1, &args);
}

fn el_get_class_list(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const helper = qjs.JS_GetPropertyStr(ctx, global, "__qb_get_class_list");
    defer qjs.JS_FreeValue(ctx, helper);
    if (!qjs.JS_IsFunction(ctx, helper)) return qjs.JS_NewObject(ctx);
    var args = [_]qjs.JSValue{this};
    const result = qjs.JS_Call(ctx, helper, global, 1, &args);
    return result;
}

fn el_get_node_value(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const node = js_to_node(this) orelse return js.js_null();
    const nt = lxb.qb_node_type(node);
    if (nt == lxb.QB_NODE_TYPE_TEXT or nt == lxb.QB_NODE_TYPE_COMMENT) {
        var len: usize = 0;
        const text = lxb.qb_node_text_content(node, &len);
        if (text == null) return js.js_null();
        defer lxb.qb_dom_document_destroy_text(lxb.qb_node_owner_document(node), @constCast(text));
        return qjs.JS_NewStringLen(ctx, @ptrCast(text), len);
    }
    return js.js_null();
}

// ──────────────────── document.body / document.head / document.documentElement ────────────────────

fn doc_get_body(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const dd = get_document_data(ctx.?) orelse return js.js_null();
    const body = lxb.qb_body(dd.doc) orelse return js.js_null();
    return node_to_js(ctx.?, body);
}

fn doc_get_head(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const dd = get_document_data(ctx.?) orelse return js.js_null();
    const head = lxb.qb_head(dd.doc) orelse return js.js_null();
    return node_to_js(ctx.?, head);
}

fn doc_get_document_element(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const dd = get_document_data(ctx.?) orelse return js.js_null();
    const root = lxb.qb_document_element(dd.doc) orelse return js.js_null();
    return node_to_js(ctx.?, root);
}

// ──────────────────── Install element prototype methods ────────────────────

fn define_getter(ctx: *qjs.JSContext, obj: qjs.JSValue, name: [*:0]const u8, getter: *const qjs.JSCFunction) void {
    const atom = qjs.JS_NewAtom(ctx, name);
    defer qjs.JS_FreeAtom(ctx, atom);
    _ = qjs.JS_DefinePropertyGetSet(
        ctx,
        obj,
        atom,
        qjs.JS_NewCFunction(ctx, getter, name, 0),
        js.js_undefined(),
        qjs.JS_PROP_HAS_GET | qjs.JS_PROP_CONFIGURABLE,
    );
}

fn define_getter_setter(ctx: *qjs.JSContext, obj: qjs.JSValue, name: [*:0]const u8, getter: *const qjs.JSCFunction, setter: *const qjs.JSCFunction) void {
    const atom = qjs.JS_NewAtom(ctx, name);
    defer qjs.JS_FreeAtom(ctx, atom);
    _ = qjs.JS_DefinePropertyGetSet(
        ctx,
        obj,
        atom,
        qjs.JS_NewCFunction(ctx, getter, name, 0),
        qjs.JS_NewCFunction(ctx, setter, name, 1),
        qjs.JS_PROP_HAS_GET | qjs.JS_PROP_HAS_SET | qjs.JS_PROP_CONFIGURABLE,
    );
}

fn install_element_proto(ctx: *qjs.JSContext, obj: qjs.JSValue) void {
    // Query methods
    _ = qjs.JS_SetPropertyStr(ctx, obj, "querySelector", qjs.JS_NewCFunction(ctx, &query_selector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "querySelectorAll", qjs.JS_NewCFunction(ctx, &query_selector_all, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &el_get_elements_by_class_name, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &el_get_elements_by_tag_name, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "matches", qjs.JS_NewCFunction(ctx, &el_matches, "matches", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "closest", qjs.JS_NewCFunction(ctx, &el_closest, "closest", 1));

    // Attribute methods
    _ = qjs.JS_SetPropertyStr(ctx, obj, "getAttribute", qjs.JS_NewCFunction(ctx, &el_get_attribute, "getAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "setAttribute", qjs.JS_NewCFunction(ctx, &el_set_attribute, "setAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "removeAttribute", qjs.JS_NewCFunction(ctx, &el_remove_attribute, "removeAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "hasAttribute", qjs.JS_NewCFunction(ctx, &el_has_attribute, "hasAttribute", 1));

    // Tree manipulation
    _ = qjs.JS_SetPropertyStr(ctx, obj, "appendChild", qjs.JS_NewCFunction(ctx, &el_append_child, "appendChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "removeChild", qjs.JS_NewCFunction(ctx, &el_remove_child, "removeChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "insertBefore", qjs.JS_NewCFunction(ctx, &el_insert_before, "insertBefore", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "replaceChild", qjs.JS_NewCFunction(ctx, &el_replace_child, "replaceChild", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "cloneNode", qjs.JS_NewCFunction(ctx, &el_clone_node, "cloneNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "contains", qjs.JS_NewCFunction(ctx, &el_contains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "remove", qjs.JS_NewCFunction(ctx, &el_remove, "remove", 0));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "before", qjs.JS_NewCFunction(ctx, &el_before, "before", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "after", qjs.JS_NewCFunction(ctx, &el_after, "after", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "prepend", qjs.JS_NewCFunction(ctx, &el_prepend, "prepend", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "append", qjs.JS_NewCFunction(ctx, &el_append, "append", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "replaceWith", qjs.JS_NewCFunction(ctx, &el_replace_with, "replaceWith", 1));

    // EventTarget
    _ = qjs.JS_SetPropertyStr(ctx, obj, "addEventListener", qjs.JS_NewCFunction(ctx, &el_add_event_listener, "addEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "removeEventListener", qjs.JS_NewCFunction(ctx, &el_remove_event_listener, "removeEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "dispatchEvent", qjs.JS_NewCFunction(ctx, &el_dispatch_event, "dispatchEvent", 1));

    // classList — delegates to JS-side DOMTokenList via __qb_get_class_list
    define_getter(ctx, obj, "classList", &el_get_class_list);

    // style — delegates to JS-side CSSStyleDeclaration via __qb_get_style
    define_getter(ctx, obj, "style", &el_get_style);

    // Read-only properties
    define_getter(ctx, obj, "tagName", &el_get_tag_name);
    define_getter(ctx, obj, "nodeName", &el_get_node_name);
    define_getter(ctx, obj, "nodeType", &el_get_node_type);
    define_getter(ctx, obj, "nodeValue", &el_get_node_value);
    define_getter(ctx, obj, "outerHTML", &el_get_outer_html);
    define_getter(ctx, obj, "parentNode", &el_get_parent_node);
    define_getter(ctx, obj, "parentElement", &el_get_parent_element);
    define_getter(ctx, obj, "children", &el_get_children);
    define_getter(ctx, obj, "childNodes", &el_get_child_nodes);
    define_getter(ctx, obj, "firstChild", &el_get_first_child);
    define_getter(ctx, obj, "lastChild", &el_get_last_child);
    define_getter(ctx, obj, "nextSibling", &el_get_next_sibling);
    define_getter(ctx, obj, "previousSibling", &el_get_previous_sibling);

    // Read-write properties
    define_getter_setter(ctx, obj, "id", &el_get_id, &el_set_id);
    define_getter_setter(ctx, obj, "className", &el_get_class_name, &el_set_class_name);
    define_getter_setter(ctx, obj, "innerHTML", &el_get_inner_html, &el_set_inner_html);
    define_getter_setter(ctx, obj, "textContent", &el_get_text_content, &el_set_text_content);
}

// ──────────────────── Class finalizers ────────────────────

fn document_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const ptr = qjs.JS_GetOpaque(val, document_class_id);
    if (ptr == null) return;
    const dd: *DocumentData = @ptrCast(@alignCast(ptr));
    lxb.qb_selectors_destroy(dd.selectors);
    lxb.qb_css_parser_destroy(dd.css_parser);
    _ = lxb.qb_document_destroy(dd.doc);
    types.gpa.destroy(dd);
}

const document_class_def = qjs.JSClassDef{
    .class_name = "Document",
    .finalizer = &document_finalizer,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

const element_class_def = qjs.JSClassDef{
    .class_name = "Element",
    .finalizer = null,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

// ──────────────────── Public: install DOM globals ────────────────────

pub fn install(ctx: *qjs.JSContext, global: qjs.JSValue) ?*DocumentData {
    const rt = qjs.JS_GetRuntime(ctx);

    // class IDs allocated under shared types.class_ids_mutex in worker.zig
    _ = qjs.JS_NewClass(rt, document_class_id, &document_class_def);
    _ = qjs.JS_NewClass(rt, element_class_id, &element_class_def);

    const doc = lxb.qb_document_create() orelse return null;
    const html = "<!DOCTYPE html><html><head></head><body></body></html>";
    if (lxb.qb_document_parse(doc, html, html.len) != 0) {
        _ = lxb.qb_document_destroy(doc);
        return null;
    }

    const css_parser = lxb.qb_css_parser_create() orelse {
        _ = lxb.qb_document_destroy(doc);
        return null;
    };

    const selectors = lxb.qb_selectors_create() orelse {
        lxb.qb_css_parser_destroy(css_parser);
        _ = lxb.qb_document_destroy(doc);
        return null;
    };

    const dd = types.gpa.create(DocumentData) catch return null;
    dd.* = .{ .doc = doc, .css_parser = css_parser, .selectors = selectors };

    const doc_obj = qjs.JS_NewObjectClass(ctx, @intCast(document_class_id));
    if (js.js_is_exception(doc_obj)) return null;
    _ = qjs.JS_SetOpaque(doc_obj, @ptrCast(dd));

    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElement", qjs.JS_NewCFunction(ctx, &doc_create_element, "createElement", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElementNS", qjs.JS_NewCFunction(ctx, &doc_create_element_ns, "createElementNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTextNode", qjs.JS_NewCFunction(ctx, &doc_create_text_node, "createTextNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createDocumentFragment", qjs.JS_NewCFunction(ctx, &doc_create_document_fragment, "createDocumentFragment", 0));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createComment", qjs.JS_NewCFunction(ctx, &doc_create_comment, "createComment", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementById", qjs.JS_NewCFunction(ctx, &doc_get_element_by_id, "getElementById", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &doc_get_elements_by_class_name, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &doc_get_elements_by_tag_name, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelector", qjs.JS_NewCFunction(ctx, &query_selector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelectorAll", qjs.JS_NewCFunction(ctx, &query_selector_all, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "addEventListener", qjs.JS_NewCFunction(ctx, &el_add_event_listener, "addEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "removeEventListener", qjs.JS_NewCFunction(ctx, &el_remove_event_listener, "removeEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "dispatchEvent", qjs.JS_NewCFunction(ctx, &el_dispatch_event, "dispatchEvent", 1));

    define_getter(ctx, doc_obj, "body", &doc_get_body);
    define_getter(ctx, doc_obj, "head", &doc_get_head);
    define_getter(ctx, doc_obj, "documentElement", &doc_get_document_element);

    _ = qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);

    // CSS style helpers (called from CSSStyleDeclaration in style.ts)
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_css_get_property", qjs.JS_NewCFunction(ctx, &css_get_property, "__qb_css_get_property", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_css_get_priority", qjs.JS_NewCFunction(ctx, &css_get_priority, "__qb_css_get_priority", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__qb_css_serialize", qjs.JS_NewCFunction(ctx, &css_serialize_declarations, "__qb_css_serialize", 1));

    return dd;
}

// ──────────────────── Elixir-facing DOM operations ────────────────────
// These run on the worker thread with direct access to DocumentData,
// bypassing QuickJS entirely. Results are returned as BEAM terms.

pub fn do_dom_query(dd: *DocumentData, selector: []const u8, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    const root = lxb.qb_doc_as_node(dd.doc) orelse return beam.make_into_atom("nil", .{ .env = env }).v;
    const list = lxb.qb_css_selectors_parse(dd.css_parser, to_lxb(selector), selector.len);
    if (lxb.qb_css_parser_status(dd.css_parser) != 0 or list == null)
        return beam.make_into_atom("nil", .{ .env = env }).v;
    defer lxb.qb_css_selector_list_destroy(dd.css_parser, list);

    var results = std.ArrayList(*lxb.lxb_dom_node_t){};
    var sctx = SelectorCtx{ .results = &results, .find_one = true };
    _ = lxb.qb_selectors_find(dd.selectors, root, list, selector_callback, @ptrCast(&sctx));

    defer results.deinit(types.gpa);
    if (results.items.len == 0) return beam.make_into_atom("nil", .{ .env = env }).v;

    return node_to_floki_term(dd, results.items[0], env);
}

pub fn do_dom_query_all(dd: *DocumentData, selector: []const u8, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    const root = lxb.qb_doc_as_node(dd.doc) orelse return beam.make_empty_list(.{ .env = env }).v;
    const list = lxb.qb_css_selectors_parse(dd.css_parser, to_lxb(selector), selector.len);
    if (lxb.qb_css_parser_status(dd.css_parser) != 0 or list == null)
        return beam.make_empty_list(.{ .env = env }).v;
    defer lxb.qb_css_selector_list_destroy(dd.css_parser, list);

    var results = std.ArrayList(*lxb.lxb_dom_node_t){};
    var sctx = SelectorCtx{ .results = &results, .find_one = false };
    _ = lxb.qb_selectors_find(dd.selectors, root, list, selector_callback, @ptrCast(&sctx));
    defer results.deinit(types.gpa);

    const opts = .{ .env = env };
    var elixir_list = beam.make_empty_list(opts);
    var i: usize = results.items.len;
    while (i > 0) {
        i -= 1;
        const term = beam.term{ .v = node_to_floki_term(dd, results.items[i], env) };
        elixir_list = beam.make_list_cell(term, elixir_list, opts);
    }
    return elixir_list.v;
}

pub fn do_dom_text(dd: *DocumentData, selector: []const u8, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    const opts = .{ .env = env };
    const root = lxb.qb_doc_as_node(dd.doc) orelse return beam.make(@as([]const u8, ""), opts).v;
    const list = lxb.qb_css_selectors_parse(dd.css_parser, to_lxb(selector), selector.len);
    if (lxb.qb_css_parser_status(dd.css_parser) != 0 or list == null)
        return beam.make(@as([]const u8, ""), opts).v;
    defer lxb.qb_css_selector_list_destroy(dd.css_parser, list);

    var results = std.ArrayList(*lxb.lxb_dom_node_t){};
    var sctx = SelectorCtx{ .results = &results, .find_one = true };
    _ = lxb.qb_selectors_find(dd.selectors, root, list, selector_callback, @ptrCast(&sctx));
    defer results.deinit(types.gpa);

    if (results.items.len == 0) return beam.make(@as([]const u8, ""), opts).v;

    var len: usize = 0;
    const text = lxb.qb_node_text_content(results.items[0], &len);
    if (text == null) return beam.make(@as([]const u8, ""), opts).v;
    defer lxb.qb_dom_document_destroy_text(lxb.qb_node_owner_document(results.items[0]), @constCast(text));
    return beam.make(@as([*]const u8, @ptrCast(text))[0..len], opts).v;
}

pub fn do_dom_attr(dd: *DocumentData, selector: []const u8, attr_name: []const u8, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    const opts = .{ .env = env };
    const root = lxb.qb_doc_as_node(dd.doc) orelse return beam.make_into_atom("nil", opts).v;
    const list_sel = lxb.qb_css_selectors_parse(dd.css_parser, to_lxb(selector), selector.len);
    if (lxb.qb_css_parser_status(dd.css_parser) != 0 or list_sel == null)
        return beam.make_into_atom("nil", opts).v;
    defer lxb.qb_css_selector_list_destroy(dd.css_parser, list_sel);

    var results = std.ArrayList(*lxb.lxb_dom_node_t){};
    var sctx = SelectorCtx{ .results = &results, .find_one = true };
    _ = lxb.qb_selectors_find(dd.selectors, root, list_sel, selector_callback, @ptrCast(&sctx));
    defer results.deinit(types.gpa);

    if (results.items.len == 0) return beam.make_into_atom("nil", opts).v;
    const elem = lxb.qb_node_as_element(results.items[0]) orelse return beam.make_into_atom("nil", opts).v;

    var val_len: usize = 0;
    const val = lxb.qb_element_get_attribute(elem, to_lxb(attr_name), attr_name.len, &val_len);
    if (val == null) return beam.make_into_atom("nil", opts).v;
    return beam.make(@as([*]const u8, @ptrCast(val))[0..val_len], opts).v;
}

pub fn do_dom_html(dd: *DocumentData, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    const opts = .{ .env = env };
    const node = lxb.qb_doc_as_node(dd.doc) orelse return beam.make(@as([]const u8, ""), opts).v;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(types.gpa);
    _ = lxb.qb_serialize_tree(node, serialize_callback, @ptrCast(&buf));
    return beam.make(buf.items, opts).v;
}

fn node_to_floki_term(dd: *DocumentData, node: *lxb.lxb_dom_node_t, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    const opts = .{ .env = env };
    const node_type = lxb.qb_node_type(node);

    if (node_type == lxb.QB_NODE_TYPE_TEXT) {
        var len: usize = 0;
        const text = lxb.qb_node_text_content(node, &len);
        if (text == null) return beam.make(@as([]const u8, ""), opts).v;
        defer lxb.qb_dom_document_destroy_text(lxb.qb_node_owner_document(node), @constCast(text));
        return beam.make(@as([*]const u8, @ptrCast(text))[0..len], opts).v;
    }

    if (node_type != lxb.QB_NODE_TYPE_ELEMENT) return beam.make_into_atom("nil", opts).v;

    const elem = lxb.qb_node_as_element(node) orelse return beam.make_into_atom("nil", opts).v;

    // Tag name
    var name_len: usize = 0;
    const name_ptr = lxb.qb_element_qualified_name(elem, &name_len);
    const tag_term = if (name_ptr != null)
        beam.make(@as([*]const u8, @ptrCast(name_ptr))[0..name_len], opts)
    else
        beam.make(@as([]const u8, ""), opts);

    // Attributes — list of {name, value} tuples
    const attrs_term = node_attrs_to_list(dd, elem, env);

    // Children — recursive
    var children_list = beam.make_empty_list(opts);
    var child_count: usize = 0;
    var counter: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(node);
    while (counter) |c| {
        child_count += 1;
        counter = lxb.qb_node_next(c);
    }

    if (child_count > 0) {
        const child_terms = types.gpa.alloc(e.ErlNifTerm, child_count) catch return beam.make_into_atom("nil", opts).v;
        defer types.gpa.free(child_terms);

        var idx: usize = 0;
        var child: ?*lxb.lxb_dom_node_t = lxb.qb_node_first_child(node);
        while (child) |c| {
            child_terms[idx] = node_to_floki_term(dd, c, env);
            idx += 1;
            child = lxb.qb_node_next(c);
        }

        var i: usize = child_count;
        while (i > 0) {
            i -= 1;
            children_list = beam.make_list_cell(beam.term{ .v = child_terms[i] }, children_list, opts);
        }
    }

    // {tag_name, attrs, children}
    return beam.make(.{ tag_term, beam.term{ .v = attrs_term }, children_list }, opts).v;
}

fn node_attrs_to_list(dd: *DocumentData, elem: *lxb.lxb_dom_element_t, env: ?*e.ErlNifEnv) e.ErlNifTerm {
    _ = dd;
    const opts = .{ .env = env };
    // Use the bridge to iterate attributes
    var attr_count: usize = 0;
    var attr: ?*lxb.lxb_dom_attr_t = lxb.qb_element_first_attr(elem);
    while (attr != null) {
        attr_count += 1;
        attr = lxb.qb_attr_next(attr);
    }

    if (attr_count == 0) return beam.make_empty_list(opts).v;

    const terms = types.gpa.alloc(e.ErlNifTerm, attr_count) catch return beam.make_empty_list(opts).v;
    defer types.gpa.free(terms);

    var idx: usize = 0;
    attr = lxb.qb_element_first_attr(elem);
    while (attr) |a| {
        var name_len: usize = 0;
        var val_len: usize = 0;
        const a_name = lxb.qb_attr_name(a, &name_len);
        const a_val = lxb.qb_attr_value(a, &val_len);

        const name_term = if (a_name != null)
            beam.make(@as([*]const u8, @ptrCast(a_name))[0..name_len], opts)
        else
            beam.make(@as([]const u8, ""), opts);

        const val_term = if (a_val != null)
            beam.make(@as([*]const u8, @ptrCast(a_val))[0..val_len], opts)
        else
            beam.make(@as([]const u8, ""), opts);

        terms[idx] = beam.make(.{ name_term, val_term }, opts).v;
        idx += 1;
        attr = lxb.qb_attr_next(a);
    }

    var result = beam.make_empty_list(opts);
    var i: usize = attr_count;
    while (i > 0) {
        i -= 1;
        result = beam.make_list_cell(beam.term{ .v = terms[i] }, result, opts);
    }
    return result.v;
}
