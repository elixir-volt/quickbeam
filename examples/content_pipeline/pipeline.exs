Mix.install([{:quickbeam, path: "../.."}])

# Each stage is a supervised JS runtime.
# Kill any one of them — the supervisor restarts it,
# the others keep running.

dir = __DIR__

forward = fn [stage, msg] ->
  QuickBEAM.send_message(String.to_existing_atom(stage), msg)
end

children = [
  {QuickBEAM,
   name: :sanitizer, id: :sanitizer,
   script: Path.join(dir, "sanitizer.js"),
   handlers: %{"forward" => forward}},
  {QuickBEAM,
   name: :classifier, id: :classifier,
   script: Path.join(dir, "classifier.js"),
   handlers: %{"forward" => forward}},
  {QuickBEAM,
   name: :enricher, id: :enricher,
   script: Path.join(dir, "enricher.js"),
   handlers: %{
     "done" => fn [result] -> send(:pipeline, {:done, result}) end
   }}
]

{:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one)
Process.register(self(), :pipeline)

posts = [
  %{id: 1, title: "<b>Hello</b> World", body: "<p>A post about Elixir and JS.</p>", author: "alice"},
  %{id: 2, title: "Buy Now! Free Money!!!", body: "Click here for $$$ — act now!", author: "spammer"},
  %{id: 3, title: "QuickBEAM Release", body: "JS runtimes as BEAM processes.", author: "bob"},
]

for post <- posts do
  QuickBEAM.send_message(:sanitizer, post)
end

for _ <- posts do
  receive do
    {:done, result} ->
      spam = if result["is_spam"], do: " [SPAM]", else: ""
      IO.puts("#{result["id"]}#{spam} | #{result["title"]} (#{result["word_count"]} words)")
  after
    5_000 -> IO.puts("timeout")
  end
end
