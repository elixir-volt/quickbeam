import fs from "node:fs";
import { compile } from "svelte/compiler";

const input = "test/fixtures/vm/svelte_catalog.svelte";
const output = "test/fixtures/vm/svelte_catalog.server.js";
const source = fs.readFileSync(input, "utf8");
const result = compile(source, {
  filename: input,
  generate: "server",
  dev: false,
});

fs.writeFileSync(
  output,
  `// Generated from svelte_catalog.svelte by svelte@5.56.4.\n${result.js.code}\n`,
);
