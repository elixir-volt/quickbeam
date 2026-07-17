defmodule QuickBEAM.Examples.VMRenderer do
  @moduledoc """
  Owns the explicit lifecycle of one immutable pinned SSR bundle.
  """

  use GenServer

  @source """
  globalThis.__quickbeamSSRResult = (async function render() {
    const props = await Beam.call("load_props");
    const items = props.products
      .map((product) => `<li data-id="${product.id}">${product.name}</li>`)
      .join("");

    return `<main><h1>${props.title}</h1><ul>${items}</ul></main>`;
  })();

  globalThis.__quickbeamSSRResult;
  """

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the lightweight handle shared by isolated request processes."
  def pinned_program(server \\ __MODULE__), do: GenServer.call(server, :pinned_program)

  @impl true
  def init(_opts) do
    with {:ok, program} <- QuickBEAM.VM.compile(@source, filename: "vm_ssr.js"),
         {:ok, pinned} <- QuickBEAM.VM.pin(program) do
      {:ok, pinned}
    end
  end

  @impl true
  def handle_call(:pinned_program, _from, pinned), do: {:reply, pinned, pinned}

  @impl true
  def terminate(_reason, pinned) do
    QuickBEAM.VM.unpin(pinned)
    :ok
  end
end

children = [QuickBEAM.Examples.VMRenderer]
{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
pinned = QuickBEAM.Examples.VMRenderer.pinned_program()

renders =
  1..8
  |> Enum.map(fn id ->
    Task.async(fn ->
      props = %{
        "title" => "Catalog #{id}",
        "products" => [%{"id" => id, "name" => "Product #{id}"}]
      }

      QuickBEAM.VM.eval(pinned,
        profile: :ssr,
        handlers: %{"load_props" => fn [] -> props end},
        max_steps: 100_000,
        memory_limit: 16 * 1024 * 1024,
        timeout: 2_000
      )
    end)
  end)
  |> Task.await_many(5_000)

Enum.each(renders, fn {:ok, html} -> IO.puts(html) end)
Supervisor.stop(supervisor)
