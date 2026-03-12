defmodule QuickBEAM.Pool do
  @moduledoc """
  A pool of JS runtimes for concurrent request handling.

  Each runtime is initialized once with your setup code, then checked out
  for individual requests. After each use, the runtime is reset and
  re-initialized — giving you a clean slate with the setup already applied.

  ## Example

      {:ok, pool} = QuickBEAM.Pool.start_link(
        size: 10,
        init: fn rt ->
          QuickBEAM.eval(rt, File.read!("priv/js/app.js"))
        end
      )

      html = QuickBEAM.Pool.run(pool, fn rt ->
        {:ok, result} = QuickBEAM.call(rt, "renderPage", [assigns])
        result
      end)

  ## Options

    * `:size` — number of runtimes in the pool (default: 10)
    * `:name` — optional registered name for the pool
    * `:init` — function called on each runtime after creation and after each reset.
      Receives the runtime pid. Use it to load your JS code.
    * `:lazy` — if true, runtimes are created on first checkout (default: false)

  All other options are forwarded to `QuickBEAM.start/1` (`:handlers`,
  `:memory_limit`, `:max_stack_size`).
  """

  @behaviour NimblePool

  @pool_opts [:name, :size, :lazy, :init]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {pool_opts, worker_opts} = Keyword.split(opts, @pool_opts)

    NimblePool.start_link(
      worker: {__MODULE__, worker_opts ++ [init: Keyword.get(pool_opts, :init)]},
      pool_size: Keyword.get(pool_opts, :size, 10),
      lazy: Keyword.get(pool_opts, :lazy, false),
      name: Keyword.get(pool_opts, :name)
    )
  end

  @doc """
  Check out a runtime, run the given function, and check it back in.

  The runtime is automatically reset and re-initialized after each use.

      QuickBEAM.Pool.run(pool, fn rt ->
        {:ok, val} = QuickBEAM.eval(rt, "1 + 2")
        val
      end)
  """
  @spec run(GenServer.server(), (QuickBEAM.runtime() -> result), timeout()) :: result
        when result: var
  def run(pool, fun, timeout \\ 5000) do
    NimblePool.checkout!(
      pool,
      :checkout,
      fn _from, rt ->
        {fun.(rt), rt}
      end,
      timeout
    )
  end

  @impl NimblePool
  def init_worker(opts) do
    {init_fun, runtime_opts} = Keyword.pop(opts, :init)
    {:ok, rt} = QuickBEAM.Runtime.start_link(runtime_opts)
    if init_fun, do: init_fun.(rt)
    {:ok, rt, opts}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, rt, opts) do
    {:ok, rt, rt, opts}
  end

  @impl NimblePool
  def handle_checkin(rt, _from, _old_rt, opts) do
    init_fun = Keyword.get(opts, :init)

    case QuickBEAM.Runtime.reset(rt) do
      :ok ->
        if init_fun, do: init_fun.(rt)
        {:ok, rt, opts}

      {:error, _} ->
        {:remove, :reset_failed, opts}
    end
  end

  @impl NimblePool
  def terminate_worker(_reason, rt, opts) do
    QuickBEAM.Runtime.stop(rt)
    {:ok, opts}
  end
end
