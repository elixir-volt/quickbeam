import { createSSRApp, h } from "vue";
import { renderToString } from "@vue/server-renderer";

function Catalog(props) {
  return h("main", { class: "catalog" }, [
    h("h1", null, props.title),
    h(
      "ul",
      null,
      props.products.map((product) =>
        h(
          "li",
          {
            class: product.inStock ? "available" : "sold-out",
            "data-id": product.id,
          },
          `${product.name}: $${(product.priceCents / 100).toFixed(2)}`,
        ),
      ),
    ),
  ]);
}

globalThis.__quickbeamSSRResult = (async function render() {
  const props = await Beam.call("load_props");
  const app = createSSRApp(Catalog, props);
  return renderToString(app);
})();

globalThis.__quickbeamSSRResult;
