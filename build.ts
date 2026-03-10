import { readdir } from "node:fs/promises";
import path from "node:path";

const srcDir = "priv/ts";
const outDir = "priv/js";

const files = await readdir(srcDir);
const entrypoints = files
  .filter((f) => f.endsWith(".ts") && !f.endsWith(".d.ts"))
  .map((f) => path.join(srcDir, f));

const result = await Bun.build({
  entrypoints,
  outdir: outDir,
  format: "iife",
  target: "browser",
  minify: false,
  splitting: false,
  naming: "[name].js",
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

for (const output of result.outputs) {
  console.log(`→ ${output.path}`);
}
