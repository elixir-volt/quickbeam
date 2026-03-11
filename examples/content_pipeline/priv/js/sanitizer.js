const TAGS = /<[^>]*>/g;

Beam.onMessage((post) => {
  Beam.callSync("forward", "classifier", {
    ...post,
    title: post.title.replace(TAGS, ""),
    body: post.body.replace(TAGS, ""),
  });
});
