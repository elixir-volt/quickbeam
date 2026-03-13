defmodule QuickBEAM.ContextPool do
  @moduledoc """
  A pool of JS runtime threads that host lightweight contexts.

  Each pool thread runs a single `JSRuntime` that can hold many
  `JSContext` instances. Contexts are ~58 KB to ~429 KB each depending
  on API surface (no dedicated OS thread), making it practical to run
  thousands concurrently.

  ## Example

      # Start a pool with 4 runtime threads
      {:ok, pool} = QuickBEAM.ContextPool.start_link(name: MyApp.JSPool, size: 4)

      # Create lightweight contexts on it
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: MyApp.JSPool)
      {:ok, 42} = QuickBEAM.Context.eval(ctx, "40 + 2")

  ## Options

    * `:name` — registered name for the pool
    * `:size` — number of runtime threads (default: `System.schedulers_online()`)
    * `:memory_limit` — maximum JS heap per thread in bytes (default: 256 MB)
    * `:max_stack_size` — maximum JS call stack in bytes (default: 1 MB)
  """
  use GenServer

  defstruct [:threads, next_id: 1, next_thread: 0]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc false
  @spec create_context(GenServer.server(), pid(), keyword()) :: {reference(), pos_integer()}
  def create_context(pool, owner_pid, opts \\ []) do
    GenServer.call(pool, {:create_context, owner_pid, opts}, :infinity)
  end

  @impl true
  def init(opts) do
    size = Keyword.get(opts, :size, System.schedulers_online())

    nif_opts =
      opts
      |> Keyword.take([:memory_limit, :max_stack_size])
      |> Map.new()

    threads =
      for _ <- 1..size do
        QuickBEAM.Native.pool_start(nif_opts)
      end
      |> List.to_tuple()

    {:ok, %__MODULE__{threads: threads}}
  end

  @impl true
  def handle_call({:create_context, owner_pid, opts}, _from, state) do
    context_id = state.next_id
    thread_idx = rem(state.next_thread, tuple_size(state.threads))
    resource = elem(state.threads, thread_idx)
    memory_limit = Keyword.get(opts, :memory_limit, 0)
    max_reductions = Keyword.get(opts, :max_reductions, 0)

    ref = QuickBEAM.Native.pool_create_context(resource, context_id, owner_pid, memory_limit, max_reductions)

    receive do
      {^ref, {:ok, ^context_id}} ->
        new_state = %{state | next_id: context_id + 1, next_thread: thread_idx + 1}
        {:reply, {resource, context_id}, new_state}

      {^ref, {:error, reason}} ->
        {:reply, {:error, reason}, state}
    after
      30_000 -> {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    for i <- 0..(tuple_size(state.threads) - 1) do
      QuickBEAM.Native.pool_stop(elem(state.threads, i))
    end

    :ok
  end
end
