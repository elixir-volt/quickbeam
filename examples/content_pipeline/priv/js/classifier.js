const SPAM_PATTERNS = [
  /buy now/i, /free money/i, /click here/i,
  /viagra/i, /\$\$\$/i, /act now/i,
];

Beam.onMessage((post) => {
  const text = post.title + " " + post.body;
  const spam_score = SPAM_PATTERNS.reduce(
    (score, pat) => score + (pat.test(text) ? 1 : 0),
    0,
  );

  Beam.callSync("forward", "enricher", {
    ...post,
    spam_score,
    is_spam: spam_score >= 2,
  });
});
