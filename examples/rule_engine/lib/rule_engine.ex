defmodule RuleEngine do
  @moduledoc """
  User-defined business rules evaluated safely in isolated JS runtimes.

  Each rule gets its own QuickBEAM runtime with `apis: false` (no browser/node
  APIs), memory limits, and execution timeouts. Rules can only interact with
  the host through explicitly registered handlers.
  """

  use Supervisor

  @default_memory_limit 4 * 1024 * 1024
  @default_timeout 1_000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: RuleEngine.Registry},
      {DynamicSupervisor, name: RuleEngine.Runtimes, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Load a rule from a JS source string.

  The source should define top-level functions callable via `call/3`.

  ## Options

    * `:handlers` — map of handler names to Elixir functions, callable
      from JS via `await Beam.call(name, ...args)`
    * `:memory_limit` — max JS heap in bytes (default: 4 MB)
    * `:timeout` — default execution timeout in ms (default: 1000)
  """
  def load(rule_id, source, opts \\ []) do
    memory_limit = Keyword.get(opts, :memory_limit, @default_memory_limit)
    handlers = Keyword.get(opts, :handlers, %{})

    spec = {
      QuickBEAM,
      name: via(rule_id),
      id: rule_id,
      apis: false,
      handlers: handlers,
      memory_limit: memory_limit
    }

    case DynamicSupervisor.start_child(RuleEngine.Runtimes, spec) do
      {:ok, _pid} ->
        QuickBEAM.eval(via(rule_id), source)

      {:error, {:already_started, _}} ->
        {:error, :already_loaded}

      error ->
        error
    end
  end

  @doc """
  Reload a rule with new source code.

  Resets the runtime to a fresh context, then evaluates the new source.
  Other rules are unaffected.
  """
  def reload(rule_id, source) do
    ref = via(rule_id)

    case Registry.lookup(RuleEngine.Registry, rule_id) do
      [{_pid, _}] ->
        QuickBEAM.reset(ref)
        QuickBEAM.eval(ref, source)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Call a function defined in a loaded rule."
  def call(rule_id, fn_name, args \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    QuickBEAM.call(via(rule_id), fn_name, args, timeout: timeout)
  end

  @doc "Unload a rule and stop its runtime."
  def unload(rule_id) do
    case Registry.lookup(RuleEngine.Registry, rule_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(RuleEngine.Runtimes, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "List all loaded rule IDs."
  def list do
    Registry.select(RuleEngine.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp via(rule_id) do
    {:via, Registry, {RuleEngine.Registry, rule_id}}
  end
end
