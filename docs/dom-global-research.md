# Native DOM Library Research

Goal: find a **native C library** that provides a real DOM tree, usable from
both the Zig/NIF layer (exposing it to Elixir) and from QuickJS (exposing
`document`, `querySelector`, `createElement`, etc. as JS globals).

---

## The Winner: Lexbor

**Lexbor** is the clear best fit.

| | |
|---|---|
| Language | Pure C99, zero external dependencies |
| License | Apache-2.0 |
| Stars | 1.8k |
| Modules | Core, DOM, HTML, CSS, Selectors, Encoding, URL |
| HTML parser | Full HTML5 spec conformance, passes all tree-builder tests |
| DOM | Implements the DOM spec — nodes, attributes, events, tree manipulation |
| CSS Selectors | Level 4 selectors: `:has()`, `:is()`, `:not()`, `:nth-child()`, attribute selectors, combinators — the works |
| Performance | Tested against 200M+ pages with ASAN; used by PHP's DOM extension since PHP 8.4 |
| Size | Modular — you can link just `liblexbor-html` (pulls in core + dom + tag + ns) |
| Existing Elixir bindings | `fast_html` (hex package) is a NIF wrapper around lexbor, used by Floki as its fast parser backend |

### Why Lexbor

1. **It already IS what Floki uses.** The `fast_html` hex package wraps lexbor
   for HTML parsing. But `fast_html` only exposes parse → tuple-tree. It
   doesn't expose the live DOM, selectors engine, or mutation APIs. We'd go
   deeper.

2. **C99, no deps, embeddable.** Fits perfectly into a Zig NIF build.
   Zig's C interop means we can `@cImport` lexbor headers directly and call
   its functions from the same shared library that hosts the QuickJS runtime.

3. **Real DOM tree in C.** Lexbor doesn't give you a serialized tuple tree —
   it holds a live `lxb_dom_node_t` graph in memory. You can walk it, mutate
   it, query it with CSS selectors, serialize back to HTML.

4. **querySelector / querySelectorAll built-in.** The Selectors module
   combines HTML + DOM + CSS into `lxb_selectors_find()` which is exactly
   what backs `document.querySelector()`.

5. **createElement, setAttribute, appendChild, etc.** The DOM module has C
   functions for all standard mutations: `lxb_dom_document_create_element()`,
   `lxb_dom_node_insert_child()`, `lxb_dom_element_set_attribute()`, etc.

### Integration Architecture

```
┌──────────────────────────────────────────────────────┐
│                   QuickBEAM Runtime                  │
│                                                      │
│  ┌─────────────┐    ┌──────────────────────────────┐ │
│  │  QuickJS-NG  │    │       Lexbor (C)             │ │
│  │              │    │  ┌──────┐ ┌───┐ ┌─────────┐ │ │
│  │  JS globals: │◄──►│  │ HTML │ │DOM│ │Selectors│ │ │
│  │  document    │    │  │Parser│ │   │ │  Engine │ │ │
│  │  Element     │    │  └──────┘ └───┘ └─────────┘ │ │
│  │  Node        │    └──────────────────────────────┘ │
│  └─────────────┘                                      │
│         ▲                        ▲                    │
│         │       Zig NIF          │                    │
│         └────────────────────────┘                    │
│                                                       │
│  Elixir:  QuickBEAM.DOM.parse(html)                  │
│           QuickBEAM.DOM.query(doc, "div.foo")         │
│           QuickBEAM.DOM.serialize(doc)                │
└───────────────────────────────────────────────────────┘
```

**JS side:** Expose lexbor DOM nodes as QuickJS objects. `document.createElement("div")`
calls through to `lxb_dom_document_create_element()`. `el.querySelector(".foo")`
calls through to `lxb_selectors_find()`. The DOM tree lives in C memory,
QuickJS just holds opaque pointers with getters/setters.

**Elixir side:** NIFs that create/parse/query/serialize documents. The document
handle is an opaque resource. Elixir code can parse HTML into a DOM, run CSS
selectors, extract text/attributes, mutate, and serialize back — all without
JS involvement.

### Key lexbor C APIs we'd wrap

```c
// Parse HTML into a DOM document
lxb_html_document_t *doc = lxb_html_document_create();
lxb_html_document_parse(doc, html, html_len);

// Create elements
lxb_dom_element_t *el = lxb_dom_document_create_element(doc, "div", 3, NULL);

// Set attributes
lxb_dom_element_set_attribute(el, "class", 5, "container", 9);

// Append children
lxb_dom_node_insert_child(parent_node, child_node);

// CSS selector query
lxb_selectors_t *sel = lxb_selectors_create();
lxb_selectors_init(sel);
lxb_css_selector_list_t *list = lxb_css_selectors_parse(parser, "div.foo > p", 11);
lxb_selectors_find(sel, root_node, list, callback, ctx);

// Get text content
const lxb_char_t *text = lxb_dom_node_text_content(node, &len);

// Serialize to HTML
lxb_html_serialize_tree_str(node, &str);
```

---

## Alternatives Considered

### lol-html (Cloudflare)

| | |
|---|---|
| Language | Rust |
| Model | Streaming rewriter, not a DOM tree |

**Verdict: No.** lol-html is a streaming HTML rewriter with CSS selectors —
it doesn't build a DOM tree at all. You get callbacks on elements as they
stream past. Great for rewriting proxied HTML, wrong for a `document` global.

### libxml2

| | |
|---|---|
| Language | C |
| Model | Full DOM, but XML-focused |

**Verdict: Maybe, but worse fit.** libxml2 has a DOM API, XPath, and XML/HTML
parsing. But it's XML-first, the HTML parser isn't HTML5-spec-compliant,
it has tons of external dependencies (iconv, zlib, etc.), and the API is
verbose and dated. Lexbor is purpose-built for modern HTML5.

### html5ever (Servo)

| | |
|---|---|
| Language | Rust |
| Model | Parser only, no DOM |

**Verdict: No.** html5ever is just a parser/tokenizer. It doesn't include
a DOM implementation — you bring your own tree sink. And being Rust means
extra FFI complexity vs. pure C.

### Gumbo (Google)

| | |
|---|---|
| Language | C |
| Model | Parser only, read-only tree |

**Verdict: No.** Gumbo parses HTML5 into a read-only tree. No mutation,
no CSS selectors, no serialization. Also unmaintained since ~2016.

---

## Recommendation

**Use lexbor directly via Zig `@cImport`.** It's pure C99 with no deps,
designed to be embedded, and provides the complete pipeline:
HTML5 parsing → DOM tree → CSS selector queries → DOM mutation → HTML serialization.

Both the JS `document` global and Elixir DOM functions would be thin wrappers
around the same lexbor document in memory.
