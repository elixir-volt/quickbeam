#include "lexbor/html/parser.h"
#include "lexbor/html/serialize.h"
#include "lexbor/html/interfaces/document.h"
#include "lexbor/dom/interfaces/element.h"
#include "lexbor/dom/interfaces/text.h"
#include "lexbor/dom/interfaces/document.h"
#include "lexbor/dom/interfaces/node.h"
#include "lexbor/dom/collection.h"
#include "lexbor/css/css.h"
#include "lexbor/selectors/selectors.h"

#include "lexbor_bridge.h"

lxb_html_document_t *qb_document_create(void) {
    return lxb_html_document_create();
}

lxb_html_document_t *qb_document_destroy(lxb_html_document_t *doc) {
    return lxb_html_document_destroy(doc);
}

lxb_status_t qb_document_parse(lxb_html_document_t *doc,
                                const lxb_char_t *html, size_t len) {
    return lxb_html_document_parse(doc, html, len);
}

lxb_dom_document_t *qb_dom_document(lxb_html_document_t *doc) {
    return &doc->dom_document;
}

lxb_dom_node_t *qb_body(lxb_html_document_t *doc) {
    if (!doc->body) return NULL;
    return lxb_dom_interface_node(doc->body);
}

lxb_dom_node_t *qb_head(lxb_html_document_t *doc) {
    if (!doc->head) return NULL;
    return lxb_dom_interface_node(doc->head);
}

lxb_dom_node_t *qb_document_element(lxb_html_document_t *doc) {
    if (!doc->dom_document.element) return NULL;
    return lxb_dom_interface_node(doc->dom_document.element);
}

lxb_dom_node_t *qb_doc_as_node(lxb_html_document_t *doc) {
    return lxb_dom_interface_node(doc);
}

lxb_dom_element_t *qb_create_element(lxb_dom_document_t *doc,
                                      const lxb_char_t *tag, size_t len) {
    return lxb_dom_document_create_element(doc, tag, len, NULL);
}

lxb_dom_text_t *qb_create_text_node(lxb_dom_document_t *doc,
                                     const lxb_char_t *text, size_t len) {
    return lxb_dom_document_create_text_node(doc, text, len);
}

lxb_dom_node_t *qb_element_as_node(lxb_dom_element_t *elem) {
    return lxb_dom_interface_node(elem);
}

lxb_dom_node_t *qb_text_as_node(lxb_dom_text_t *text) {
    return lxb_dom_interface_node(text);
}

lxb_dom_element_t *qb_node_as_element(lxb_dom_node_t *node) {
    return lxb_dom_interface_element(node);
}

void qb_node_insert_child(lxb_dom_node_t *parent, lxb_dom_node_t *child) {
    lxb_dom_node_insert_child(parent, child);
}

void qb_node_remove(lxb_dom_node_t *node) {
    lxb_dom_node_remove(node);
}

lxb_dom_node_type_t qb_node_type(lxb_dom_node_t *node) {
    return node->type;
}

lxb_dom_node_t *qb_node_first_child(lxb_dom_node_t *node) {
    return node->first_child;
}

lxb_dom_node_t *qb_node_next(lxb_dom_node_t *node) {
    return node->next;
}

lxb_dom_node_t *qb_node_parent(lxb_dom_node_t *node) {
    return node->parent;
}

lxb_dom_document_t *qb_node_owner_document(lxb_dom_node_t *node) {
    return node->owner_document;
}

const lxb_char_t *qb_element_qualified_name(lxb_dom_element_t *elem, size_t *len) {
    return lxb_dom_element_qualified_name(elem, len);
}

const lxb_char_t *qb_element_get_attribute(lxb_dom_element_t *elem,
                                            const lxb_char_t *name, size_t name_len,
                                            size_t *value_len) {
    return lxb_dom_element_get_attribute(elem, name, name_len, value_len);
}

lxb_status_t qb_element_set_attribute(lxb_dom_element_t *elem,
                                       const lxb_char_t *name, size_t name_len,
                                       const lxb_char_t *value, size_t value_len) {
    lxb_dom_attr_t *attr = lxb_dom_element_set_attribute(elem, name, name_len,
                                                          value, value_len);
    return attr ? LXB_STATUS_OK : LXB_STATUS_ERROR;
}

lxb_status_t qb_element_remove_attribute(lxb_dom_element_t *elem,
                                          const lxb_char_t *name, size_t name_len) {
    return lxb_dom_element_remove_attribute(elem, name, name_len);
}

lxb_dom_collection_t *qb_collection_make(lxb_dom_document_t *doc, size_t cap) {
    return lxb_dom_collection_make(doc, cap);
}

void qb_collection_destroy(lxb_dom_collection_t *col) {
    lxb_dom_collection_destroy(col, true);
}

size_t qb_collection_length(lxb_dom_collection_t *col) {
    return lxb_dom_collection_length(col);
}

lxb_dom_element_t *qb_collection_element(lxb_dom_collection_t *col, size_t idx) {
    return lxb_dom_collection_element(col, idx);
}

lxb_status_t qb_elements_by_attr(lxb_dom_element_t *root,
                                  lxb_dom_collection_t *col,
                                  const lxb_char_t *name, size_t name_len,
                                  const lxb_char_t *value, size_t value_len) {
    return lxb_dom_elements_by_attr(root, col, name, name_len,
                                    value, value_len, true);
}

const lxb_char_t *qb_node_text_content(lxb_dom_node_t *node, size_t *len) {
    return lxb_dom_node_text_content(node, len);
}

lxb_status_t qb_node_text_content_set(lxb_dom_node_t *node,
                                       const lxb_char_t *text, size_t len) {
    return lxb_dom_node_text_content_set(node, text, len);
}

void qb_dom_document_destroy_text(lxb_dom_document_t *doc, lxb_char_t *text) {
    lxb_dom_document_destroy_text(doc, text);
}

lxb_status_t qb_serialize_tree(lxb_dom_node_t *node,
                                qb_serialize_cb_f cb, void *ctx) {
    return lxb_html_serialize_tree_cb(node, (lxb_html_serialize_cb_f)cb, ctx);
}

lxb_dom_node_t *qb_parse_fragment(lxb_html_document_t *doc,
                                   lxb_dom_element_t *context_elem,
                                   const lxb_char_t *html, size_t len) {
    lxb_html_element_t *frag =
        lxb_html_document_parse_fragment(doc, context_elem, html, len);
    if (!frag) return NULL;
    return lxb_dom_interface_node(frag);
}

lxb_css_parser_t *qb_css_parser_create(void) {
    lxb_css_parser_t *parser = lxb_css_parser_create();
    if (!parser) return NULL;
    if (lxb_css_parser_init(parser, NULL) != LXB_STATUS_OK) {
        lxb_css_parser_destroy(parser, true);
        return NULL;
    }
    return parser;
}

void qb_css_parser_destroy(lxb_css_parser_t *parser) {
    lxb_css_parser_destroy(parser, true);
}

lxb_selectors_t *qb_selectors_create(void) {
    lxb_selectors_t *sel = lxb_selectors_create();
    if (!sel) return NULL;
    if (lxb_selectors_init(sel) != LXB_STATUS_OK) {
        lxb_selectors_destroy(sel, true);
        return NULL;
    }
    return sel;
}

void qb_selectors_destroy(lxb_selectors_t *sel) {
    lxb_selectors_destroy(sel, true);
}

lxb_css_selector_list_t *qb_css_selectors_parse(lxb_css_parser_t *parser,
                                                  const lxb_char_t *sel, size_t len) {
    return lxb_css_selectors_parse(parser, sel, len);
}

lxb_status_t qb_css_parser_status(lxb_css_parser_t *parser) {
    return parser->status;
}

void qb_css_selector_list_destroy(lxb_css_selector_list_t *list) {
    lxb_css_selector_list_destroy_memory(list);
}

lxb_status_t qb_selectors_find(lxb_selectors_t *sel,
                                lxb_dom_node_t *root,
                                lxb_css_selector_list_t *list,
                                qb_selector_cb_f cb, void *ctx) {
    return lxb_selectors_find(sel, root, list,
                              (lxb_selectors_cb_f)cb, ctx);
}
