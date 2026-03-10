Process.onMessage((post) => {
  beam.callSync("done", {
    ...post,
    word_count: post.body.split(/\s+/).filter((w) => w.length > 0).length,
    processed_at: new Date().toISOString(),
  });
});
