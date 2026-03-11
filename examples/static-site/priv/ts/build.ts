/// <reference types="quickbeam-types" />
import { marked } from "marked"
import fs from "node:fs"
import path from "node:path"

declare const contentDir: string
declare const outputDir: string

interface FrontMatter {
  title: string
  date?: string
  draft?: boolean
  [key: string]: unknown
}

function parseFrontMatter(source: string): { meta: FrontMatter; body: string } {
  if (!source.startsWith("---\n")) {
    return { meta: { title: "Untitled" }, body: source }
  }
  const end = source.indexOf("\n---\n", 4)
  if (end === -1) {
    return { meta: { title: "Untitled" }, body: source }
  }
  const yaml = source.slice(4, end)
  const meta: Record<string, string> = {}
  for (const line of yaml.split("\n")) {
    const colon = line.indexOf(":")
    if (colon > 0) {
      const key = line.slice(0, colon).trim()
      const val = line.slice(colon + 1).trim()
      meta[key] = val
    }
  }
  return { meta: meta as unknown as FrontMatter, body: source.slice(end + 5) }
}

function renderPage(title: string, content: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>${title}</title>
  <style>
    body { max-width: 640px; margin: 2rem auto; font-family: system-ui; line-height: 1.6; padding: 0 1rem; }
    pre { background: #f4f4f4; padding: 1rem; overflow-x: auto; border-radius: 4px; }
    code { font-size: 0.9em; }
    a { color: #0366d6; }
  </style>
</head>
<body>
  <nav><a href="index.html">← Home</a></nav>
  <article>${content}</article>
</body>
</html>`
}

function renderIndex(posts: { slug: string; title: string; date: string }[]): string {
  const items = posts
    .sort((a, b) => b.date.localeCompare(a.date))
    .map(p => `<li><time>${p.date}</time> — <a href="${p.slug}.html">${p.title}</a></li>`)
    .join("\n    ")

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Blog</title>
  <style>
    body { max-width: 640px; margin: 2rem auto; font-family: system-ui; line-height: 1.6; padding: 0 1rem; }
    time { color: #666; font-variant-numeric: tabular-nums; }
    a { color: #0366d6; }
    ul { list-style: none; padding: 0; }
    li { margin: 0.5rem 0; }
  </style>
</head>
<body>
  <h1>Blog</h1>
  <ul>
    ${items}
  </ul>
</body>
</html>`
}

fs.mkdirSync(outputDir, { recursive: true })

const files = fs.readdirSync(contentDir).filter((f: string) => f.endsWith(".md"))
const posts: { slug: string; title: string; date: string }[] = []

for (const file of files) {
  const source = fs.readFileSync(path.join(contentDir, file), "utf-8")
  const { meta, body } = parseFrontMatter(source)

  if (String(meta.draft) === "true") continue

  const slug = path.basename(file, ".md")
  const html = marked.parse(body) as string
  const page = renderPage(meta.title, html)

  fs.writeFileSync(path.join(outputDir, `${slug}.html`), page)
  posts.push({ slug, title: meta.title, date: meta.date || "undated" })

  console.log(`  ${slug}.html → ${meta.title}`)
}

fs.writeFileSync(path.join(outputDir, "index.html"), renderIndex(posts))
console.log(`  index.html → Index (${posts.length} posts)`)
