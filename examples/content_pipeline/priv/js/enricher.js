const SPAM_PATTERNS = [
  /buy now/i, /free money/i, /click here/i,
  /\$\$\$/i, /act now/i, /limited offer/i,
]

Beam.onMessage((post) => {
  const text = (post.title + " " + post.html).toLowerCase()
  const spam_score = SPAM_PATTERNS.reduce(
    (score, pat) => score + (pat.test(text) ? 1 : 0), 0
  )

  Beam.callSync("done", {
    ...post,
    spam_score,
    is_spam: spam_score >= 2,
    processed_at: new Date().toISOString()
  })
})
