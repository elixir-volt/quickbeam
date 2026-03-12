defmodule ContentPipeline do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def submit(post) do
    QuickBEAM.send_message(:parser, post)
  end

  @impl true
  def init(opts) do
    collector = Keyword.get(opts, :collector, self())
    js_dir = Keyword.get(opts, :js_dir, Path.join(:code.priv_dir(:content_pipeline), "js"))

    forward = fn [stage, msg] ->
      QuickBEAM.send_message(String.to_existing_atom(stage), msg)
    end

    children = [
      {QuickBEAM,
       name: :parser,
       id: :parser,
       script: Path.join(js_dir, "parser.js"),
       handlers: %{"forward" => forward}},
      {QuickBEAM,
       name: :analyzer,
       id: :analyzer,
       script: Path.join(js_dir, "analyzer.js"),
       handlers: %{"forward" => forward}},
      {QuickBEAM,
       name: :enricher,
       id: :enricher,
       script: Path.join(js_dir, "enricher.js"),
       handlers: %{
         "done" => fn [result] -> send(collector, {:done, result}) end
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
