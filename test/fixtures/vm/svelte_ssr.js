import Catalog from "./svelte_catalog.server.js";

class FixtureRenderer {
  constructor(shared = { body: "", head: "" }, type = "body") {
    this.shared = shared;
    this.type = type;
  }

  component(render) {
    render(this);
  }

  child(render) {
    render(this);
  }

  head(render) {
    render(new FixtureRenderer(this.shared, "head"));
  }

  title(render) {
    render(this);
  }

  push(fragment) {
    this.shared[this.type] += fragment;
  }
}

globalThis.__quickbeamSSRResult = (async function renderCatalog() {
  const props = await Beam.call("load_props");
  const renderer = new FixtureRenderer();
  Catalog(renderer, props);
  return renderer.shared;
})();

globalThis.__quickbeamSSRResult;
