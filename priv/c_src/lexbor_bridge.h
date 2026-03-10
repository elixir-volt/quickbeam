#ifndef QUICKBEAM_LEXBOR_BRIDGE_H
#define QUICKBEAM_LEXBOR_BRIDGE_H

#include <stddef.h>

#ifndef LEXBOR_BASE_H
typedef unsigned char lxb_char_t;
typedef unsigned int lxb_status_t;
typedef unsigned int lxb_dom_node_type_t;
typedef struct lxb_html_document lxb_html_document_t;
typedef struct lxb_dom_document lxb_dom_document_t;
typedef struct lxb_dom_node lxb_dom_node_t;
typedef struct lxb_dom_element lxb_dom_element_t;
typedef struct lxb_dom_text lxb_dom_text_t;
typedef struct lxb_dom_attr lxb_dom_attr_t;
typedef struct lxb_dom_collection lxb_dom_collection_t;
typedef struct lxb_css_parser lxb_css_parser_t;
typedef struct lxb_css_selector_list lxb_css_selector_list_t;
typedef struct lxb_selectors lxb_selectors_t;
#endif

typedef lxb_status_t
(*qb_selector_cb_f)(void *node, unsigned int specificity, void *ctx);

typedef lxb_status_t
(*qb_serialize_cb_f)(const lxb_char_t *data, size_t len, void *ctx);

lxb_html_document_t *qb_document_create(void);
lxb_html_document_t *qb_document_destroy(lxb_html_document_t *doc);
lxb_status_t qb_document_parse(lxb_html_document_t *doc,
                                const lxb_char_t *html, size_t len);

lxb_dom_document_t *qb_dom_document(lxb_html_document_t *doc);
lxb_dom_node_t *qb_body(lxb_html_document_t *doc);
lxb_dom_node_t *qb_head(lxb_html_document_t *doc);
lxb_dom_node_t *qb_document_element(lxb_html_document_t *doc);
lxb_dom_node_t *qb_doc_as_node(lxb_html_document_t *doc);

lxb_dom_element_t *qb_create_element(lxb_dom_document_t *doc,
                                      const lxb_char_t *tag, size_t len);
lxb_dom_text_t *qb_create_text_node(lxb_dom_document_t *doc,
                                     const lxb_char_t *text, size_t len);

lxb_dom_node_t *qb_element_as_node(lxb_dom_element_t *elem);
lxb_dom_node_t *qb_text_as_node(lxb_dom_text_t *text);
lxb_dom_element_t *qb_node_as_element(lxb_dom_node_t *node);

void qb_node_insert_child(lxb_dom_node_t *parent, lxb_dom_node_t *child);
void qb_node_remove(lxb_dom_node_t *node);

lxb_dom_node_type_t qb_node_type(lxb_dom_node_t *node);
lxb_dom_node_t *qb_node_first_child(lxb_dom_node_t *node);
lxb_dom_node_t *qb_node_next(lxb_dom_node_t *node);
lxb_dom_node_t *qb_node_parent(lxb_dom_node_t *node);
lxb_dom_document_t *qb_node_owner_document(lxb_dom_node_t *node);

const lxb_char_t *qb_element_qualified_name(lxb_dom_element_t *elem, size_t *len);
const lxb_char_t *qb_element_get_attribute(lxb_dom_element_t *elem,
                                            const lxb_char_t *name, size_t name_len,
                                            size_t *value_len);
lxb_status_t qb_element_set_attribute(lxb_dom_element_t *elem,
                                       const lxb_char_t *name, size_t name_len,
                                       const lxb_char_t *value, size_t value_len);
lxb_status_t qb_element_remove_attribute(lxb_dom_element_t *elem,
                                          const lxb_char_t *name, size_t name_len);

lxb_dom_attr_t *qb_element_first_attr(lxb_dom_element_t *elem);
lxb_dom_attr_t *qb_attr_next(lxb_dom_attr_t *attr);
const lxb_char_t *qb_attr_name(lxb_dom_attr_t *attr, size_t *len);
const lxb_char_t *qb_attr_value(lxb_dom_attr_t *attr, size_t *len);

lxb_dom_collection_t *qb_collection_make(lxb_dom_document_t *doc, size_t cap);
void qb_collection_destroy(lxb_dom_collection_t *col);
size_t qb_collection_length(lxb_dom_collection_t *col);
lxb_dom_element_t *qb_collection_element(lxb_dom_collection_t *col, size_t idx);
lxb_status_t qb_elements_by_attr(lxb_dom_element_t *root,
                                  lxb_dom_collection_t *col,
                                  const lxb_char_t *name, size_t name_len,
                                  const lxb_char_t *value, size_t value_len);

const lxb_char_t *qb_node_text_content(lxb_dom_node_t *node, size_t *len);
lxb_status_t qb_node_text_content_set(lxb_dom_node_t *node,
                                       const lxb_char_t *text, size_t len);
void qb_dom_document_destroy_text(lxb_dom_document_t *doc, lxb_char_t *text);

lxb_status_t qb_serialize_tree(lxb_dom_node_t *node,
                                qb_serialize_cb_f cb, void *ctx);
lxb_dom_node_t *qb_parse_fragment(lxb_html_document_t *doc,
                                   lxb_dom_element_t *context_elem,
                                   const lxb_char_t *html, size_t len);

lxb_css_parser_t *qb_css_parser_create(void);
void qb_css_parser_destroy(lxb_css_parser_t *parser);
lxb_selectors_t *qb_selectors_create(void);
void qb_selectors_destroy(lxb_selectors_t *sel);

lxb_css_selector_list_t *qb_css_selectors_parse(lxb_css_parser_t *parser,
                                                  const lxb_char_t *sel, size_t len);
lxb_status_t qb_css_parser_status(lxb_css_parser_t *parser);
void qb_css_selector_list_destroy(lxb_css_parser_t *parser,
                                   lxb_css_selector_list_t *list);
lxb_status_t qb_selectors_find(lxb_selectors_t *sel,
                                lxb_dom_node_t *root,
                                lxb_css_selector_list_t *list,
                                qb_selector_cb_f cb, void *ctx);

#define QB_NODE_TYPE_ELEMENT    1
#define QB_NODE_TYPE_TEXT       3
#define QB_NODE_TYPE_DOCUMENT   9

#endif
