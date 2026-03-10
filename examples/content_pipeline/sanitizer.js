const TAGS = /<[^>]*>/g;

Process.onMessage((post) => {
  beam.callSync("forward", "classifier", {
    ...post,
    title: post.title.replace(TAGS, ""),
    body: post.body.replace(TAGS, ""),
  });
});
