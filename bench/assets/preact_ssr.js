import { Fragment, cloneElement, h, toChildArray } from "preact";

(() => {
  const createElement = h;
  const clone = cloneElement;
  const flatten = toChildArray;
  const Frag = Fragment;

  function formatPrice(cents) {
    return `$${(cents / 100).toFixed(2)}`;
  }

  function Badge({ tone, text }) {
    return createElement("span", { class: `badge badge-${tone}` }, text);
  }

  function Stat({ label, value }) {
    return createElement(
      "div",
      { class: "stat" },
      createElement("dt", null, label),
      createElement("dd", null, value)
    );
  }

  function ProductRow({ product, selectedId }) {
    const selected = product.id === selectedId;

    return createElement(
      "li",
      {
        class: selected ? "product is-selected" : "product",
        "data-id": product.id,
        key: product.id
      },
      createElement(
        "div",
        { class: "product-main" },
        createElement("h3", null, product.name),
        createElement("p", null, product.description),
        createElement(
          Frag,
          null,
          product.tags.map((tag, index) =>
            createElement(Badge, {
              key: `${product.id}:${tag}:${index}`,
              tone: index % 2 === 0 ? "info" : "muted",
              text: tag
            })
          )
        )
      ),
      createElement(
        "aside",
        { class: "product-side" },
        Stat({ label: "Price", value: formatPrice(product.priceCents) }),
        Stat({ label: "Stock", value: product.inStock ? "In stock" : "Backorder" }),
        Stat({ label: "Rating", value: product.rating.toFixed(1) })
      )
    );
  }

  function ProductList({ title, subtitle, products, selectedId, footerNote }) {
    const inStock = products.filter((product) => product.inStock).length;
    const averagePrice =
      products.reduce((sum, product) => sum + product.priceCents, 0) / products.length;

    return createElement(
      "section",
      { class: "catalog" },
      createElement(
        "header",
        { class: "catalog-header" },
        createElement("h1", null, title),
        createElement("p", null, subtitle),
        createElement(
          "div",
          { class: "catalog-meta" },
          Stat({ label: "Products", value: products.length }),
          Stat({ label: "Available", value: inStock }),
          Stat({ label: "Avg price", value: formatPrice(averagePrice) })
        )
      ),
      createElement(
        "ul",
        { class: "products" },
        products.map((product) => ProductRow({ product, selectedId }))
      ),
      createElement("footer", { class: "catalog-footer" }, footerNote)
    );
  }

  function summarizeTree(node) {
    if (node == null || typeof node === "boolean") {
      return { elements: 0, text: 0, selected: 0 };
    }

    if (typeof node === "string" || typeof node === "number") {
      return { elements: 0, text: String(node).length, selected: 0 };
    }

    const props = node.props || {};
    const children = flatten(props.children);
    let elements = 1;
    let text = 0;
    let selected = props.class && props.class.includes("is-selected") ? 1 : 0;

    for (const child of children) {
      const stats = summarizeTree(child);
      elements += stats.elements;
      text += stats.text;
      selected += stats.selected;
    }

    return { elements, text, selected };
  }

  return function renderApp(props) {
    const tree = clone(ProductList(props), { "data-bench": "preact" });
    const stats = summarizeTree(tree);
    return `${stats.elements}:${stats.text}:${stats.selected}`;
  };
})();
