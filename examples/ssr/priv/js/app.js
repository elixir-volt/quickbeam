import { h, render } from "preact"

function Nav() {
  return h("nav", null,
    h("a", { href: "/" }, "Home"),
    h("a", { href: "/about" }, "About")
  )
}

function PostList({ posts }) {
  return h("div", null,
    h(Nav),
    h("h1", null, "Blog"),
    posts.map(post =>
      h("div", { class: "post", key: post.slug },
        h("h2", null, h("a", { href: "/post/" + post.slug }, post.title)),
        h("div", { class: "meta" },
          h("time", null, post.date),
          " · ",
          post.tags.map(tag => h("span", { class: "tag", key: tag }, tag))
        ),
        h("p", null, post.excerpt)
      )
    )
  )
}

function PostDetail({ post }) {
  return h("div", null,
    h(Nav),
    h("article", null,
      h("h1", null, post.title),
      h("div", { class: "meta" },
        h("time", null, post.date),
        " · ",
        post.tags.map(tag => h("span", { class: "tag", key: tag }, tag))
      ),
      h("div", { id: "content" }, post.body)
    )
  )
}

function About() {
  return h("div", null,
    h(Nav),
    h("h1", null, "About"),
    h("p", null, "Rendered by Preact inside QuickBEAM — a JS runtime living in the BEAM."),
    h("p", null, "No Node.js. No V8. Just QuickJS, OTP supervision, and a native DOM backed by lexbor.")
  )
}

function NotFound() {
  return h("div", null,
    h(Nav),
    h("h1", null, "404"),
    h("p", null, "Page not found.")
  )
}

function renderPage(route, data) {
  let vnode
  switch (route) {
    case "index":   vnode = h(PostList, { posts: data }); break
    case "post":    vnode = h(PostDetail, { post: data }); break
    case "about":   vnode = h(About); break
    default:        vnode = h(NotFound); break
  }
  render(vnode, document.body)
}

globalThis.renderPage = renderPage
