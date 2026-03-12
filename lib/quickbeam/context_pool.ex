defmodule QuickBEAM.ContextPool do
  @moduledoc """
  A pool of JS runtime threads that host lightweight contexts.

  Each pool thread runs a single `JSRuntime` that can hold many
  `JSContext` instances. Contexts are ~50KB each (no dedicated OS thread),
  making it practical to run thousands concurrently.

  ## Example

      # Start a pool (one runtime thread by default)
      {:ok, pool} = QuickBEAM.ContextPool.start_link(name: MyApp.JSPool)

      # Create lightweight contexts on it
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: MyApp.JSPool)
      {:ok, 42} = QuickBEAM.Context.eval(ctx, "40 + 2")

  ## Options

    * `:name` — registered name for the pool
    * `:memory_limit` — maximum JS heap in bytes (default: 256 MB)
    * `:max_stack_size` — maximum JS call stack in bytes (default: 1 MB)
  """
  use GenServer

  defstruct [:resource, next_id: 1]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc false
  @spec create_context(GenServer.server(), pid()) :: {reference(), pos_integer()}
  def create_context(pool, owner_pid) do
    GenServer.call(pool, {:create_context, owner_pid}, :infinity)
  end

  @impl true
  def init(opts) do
    nif_opts =
      opts
      |> Keyword.take([:memory_limit, :max_stack_size])
      |> Map.new()

    resource = QuickBEAM.Native.pool_start(nif_opts)
    {:ok, %__MODULE__{resource: resource}}
  end

  @impl true
  def handle_call({:create_context, owner_pid}, _from, state) do
    context_id = state.next_id
    ref = QuickBEAM.Native.pool_create_context(state.resource, context_id, owner_pid)

    receive do
      {^ref, {:ok, ^context_id}} ->
        {:reply, {state.resource, context_id}, %{state | next_id: context_id + 1}}

      {^ref, {:error, reason}} ->
        {:reply, {:error, reason}, state}
    after
      30_000 -> {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    QuickBEAM.Native.pool_stop(state.resource)
    :ok
  end
end
