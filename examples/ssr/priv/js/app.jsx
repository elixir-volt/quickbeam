import { h as createElement, render } from "preact"

function Nav() {
  return (
    <nav>
      <a href="/">Home</a>
      <a href="/about">About</a>
    </nav>
  )
}

function PostList({ posts }) {
  return (
    <div>
      <Nav />
      <h1>Blog</h1>
      {posts.map(post =>
        <div class="post" key={post.slug}>
          <h2><a href={"/post/" + post.slug}>{post.title}</a></h2>
          <div class="meta">
            <time>{post.date}</time>
            {" · "}
            {post.tags.map(tag => <span class="tag" key={tag}>{tag}</span>)}
          </div>
          <p>{post.excerpt}</p>
        </div>
      )}
    </div>
  )
}

function PostDetail({ post }) {
  return (
    <div>
      <Nav />
      <article>
        <h1>{post.title}</h1>
        <div class="meta">
          <time>{post.date}</time>
          {" · "}
          {post.tags.map(tag => <span class="tag" key={tag}>{tag}</span>)}
        </div>
        <div id="content">{post.body}</div>
      </article>
    </div>
  )
}

function About() {
  return (
    <div>
      <Nav />
      <h1>About</h1>
      <p>Rendered by Preact inside QuickBEAM — a JS runtime living in the BEAM.</p>
      <p>No Node.js. No V8. Just QuickJS, OTP supervision, and a native DOM backed by lexbor.</p>
    </div>
  )
}

function NotFound() {
  return (
    <div>
      <Nav />
      <h1>404</h1>
      <p>Page not found.</p>
    </div>
  )
}

function renderPage(route, data) {
  let vnode
  switch (route) {
    case "index":   vnode = <PostList posts={data} />; break
    case "post":    vnode = <PostDetail post={data} />; break
    case "about":   vnode = <About />; break
    default:        vnode = <NotFound />; break
  }
  render(vnode, document.body)
}

globalThis.renderPage = renderPage
