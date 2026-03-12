import { marked } from "marked"

Beam.onMessage((post) => {
  const html = marked.parse(post.body)

  Beam.callSync("forward", "analyzer", { ...post, html })
})
