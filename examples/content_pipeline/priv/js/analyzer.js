Beam.onMessage((post) => {
  document.body.innerHTML = post.html

  const headings = [...document.querySelectorAll("h1, h2, h3")].map(h => ({
    level: parseInt(h.tagName[1]),
    text: h.textContent
  }))

  const links = [...document.querySelectorAll("a[href]")].map(a => ({
    href: a.getAttribute("href"),
    text: a.textContent
  }))

  const codeBlocks = [...document.querySelectorAll("pre code")].map(code => {
    const cls = code.getAttribute("class") || ""
    const lang = cls.replace("language-", "") || "text"
    return { lang, lines: code.textContent.split("\n").length }
  })

  const text = document.body.textContent || ""
  const words = text.split(/\s+/).filter(w => w.length > 0).length
  const readingTime = Math.ceil(words / 200)

  Beam.callSync("forward", "enricher", {
    ...post,
    headings,
    links,
    code_blocks: codeBlocks,
    word_count: words,
    reading_time: readingTime
  })
})
