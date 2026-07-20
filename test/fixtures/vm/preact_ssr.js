import { h } from "preact";
import renderToString from "preact-render-to-string";

function App({ title, products }) {
  return h(
    "main",
    { class: "catalog" },
    h("h1", null, title),
    h(
      "ul",
      null,
      products.map((product) =>
        h(
          "li",
          { class: product.inStock ? "available" : "backorder", "data-id": product.id },
          product.name,
          ": $",
          (product.priceCents / 100).toFixed(2)
        )
      )
    )
  );
}

globalThis.__quickbeamSSRResult = (async function render() {
  const props = await Beam.call("load_props");
  return renderToString(h(App, props));
})();

globalThis.__quickbeamSSRResult;
