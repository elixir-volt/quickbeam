defmodule PluginSandbox do
  @moduledoc """
  Multi-tenant plugin execution with isolated JS runtimes.

  Each plugin runs in its own QuickBEAM runtime with:
  - Memory limits (default 2 MB)
  - Execution timeouts
  - Only approved handlers (no filesystem, no network unless granted)

  Plugins are just JavaScript. They receive events and return results
  through a capability-based handler system.
  """

  use Supervisor

  @default_memory_limit 2 * 1024 * 1024
  @default_timeout 1_000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: PluginSandbox.Registry},
      {DynamicSupervisor, name: PluginSandbox.Runtimes, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Load a plugin from source code with the given capabilities.

  ## Capabilities

    * `:kv` — read/write to a per-plugin key-value store
    * `:http` — make outbound HTTP requests via `fetch`
    * `:log` — write to the application log

  ## Options

    * `:memory_limit` — max JS heap in bytes (default: 2 MB)
    * `:timeout` — default execution timeout in ms (default: 1000)
  """
  def load_plugin(plugin_id, source, capabilities \\ [], opts \\ []) do
    memory_limit = Keyword.get(opts, :memory_limit, @default_memory_limit)

    handlers = build_handlers(plugin_id, capabilities)
    apis = if :http in capabilities, do: [:browser], else: false

    spec = {
      QuickBEAM,
      name: via(plugin_id),
      id: plugin_id,
      handlers: handlers,
      apis: apis,
      memory_limit: memory_limit
    }

    case DynamicSupervisor.start_child(PluginSandbox.Runtimes, spec) do
      {:ok, _pid} ->
        QuickBEAM.eval(via(plugin_id), source)
        :ok

      {:error, {:already_started, _}} ->
        {:error, :already_loaded}

      error ->
        error
    end
  end

  @doc "Unload a plugin and stop its runtime."
  def unload_plugin(plugin_id) do
    case Registry.lookup(PluginSandbox.Registry, plugin_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(PluginSandbox.Runtimes, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Call a function exported by the plugin."
  def call_plugin(plugin_id, fn_name, args \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    QuickBEAM.call(via(plugin_id), fn_name, args, timeout: timeout)
  end

  @doc "Send an event to the plugin's message handler."
  def send_event(plugin_id, event) do
    QuickBEAM.send_message(via(plugin_id), event)
  end

  @doc "List all loaded plugin IDs."
  def list_plugins do
    Registry.select(PluginSandbox.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp via(plugin_id) do
    {:via, Registry, {PluginSandbox.Registry, plugin_id}}
  end

  defp build_handlers(plugin_id, capabilities) do
    base = %{}

    base
    |> maybe_add_kv(plugin_id, capabilities)
    |> maybe_add_log(plugin_id, capabilities)
  end

  defp maybe_add_kv(handlers, plugin_id, capabilities) do
    if :kv in capabilities do
      table = :"plugin_kv_#{plugin_id}"

      if :ets.info(table) == :undefined do
        :ets.new(table, [:set, :public, :named_table])
      end

      Map.merge(handlers, %{
        "kv.get" => fn [key] ->
          case :ets.lookup(table, key) do
            [{_, val}] -> val
            [] -> nil
          end
        end,
        "kv.set" => fn [key, value] ->
          :ets.insert(table, {key, value})
          nil
        end,
        "kv.delete" => fn [key] ->
          :ets.delete(table, key)
          nil
        end,
        "kv.keys" => fn _ ->
          :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
        end
      })
    else
      handlers
    end
  end

  defp maybe_add_log(handlers, plugin_id, capabilities) do
    if :log in capabilities do
      Map.put(handlers, "log", fn [message] ->
        require Logger
        Logger.info("[plugin:#{plugin_id}] #{message}")
        nil
      end)
    else
      handlers
    end
  end
end
