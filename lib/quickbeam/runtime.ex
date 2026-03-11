defmodule QuickBEAM.Runtime do
  @moduledoc false
  use GenServer
  require Logger

  @enforce_keys [:resource]
  defstruct [:resource, handlers: %{}, monitors: %{}, workers: %{}, pending: %{}]

  @type t :: %__MODULE__{
          resource: reference(),
          handlers: map(),
          monitors: map(),
          workers: map(),
          pending: map()
        }

  def child_spec(opts) do
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec eval(GenServer.server(), String.t(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def eval(server, code, opts \\ []) when is_binary(code) do
    timeout_ms = Keyword.get(opts, :timeout, 0)
    GenServer.call(server, {:eval, code, timeout_ms}, :infinity)
  end

  @spec call(GenServer.server(), String.t(), list(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def call(server, fn_name, args \\ [], opts \\ []) when is_binary(fn_name) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout, 0)
    GenServer.call(server, {:call, fn_name, args, timeout_ms}, :infinity)
  end

  @spec compile(GenServer.server(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def compile(server, code) when is_binary(code) do
    GenServer.call(server, {:compile, code}, :infinity)
  end

  @spec load_bytecode(GenServer.server(), binary()) ::
          {:ok, term()} | {:error, String.t()}
  def load_bytecode(server, bytecode) when is_binary(bytecode) do
    GenServer.call(server, {:load_bytecode, bytecode}, :infinity)
  end

  @spec load_module(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def load_module(server, name, code) when is_binary(name) and is_binary(code) do
    GenServer.call(server, {:load_module, name, code}, :infinity)
  end

  @spec reset(GenServer.server()) :: :ok | {:error, String.t()}
  def reset(server) do
    GenServer.call(server, :reset, :infinity)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @spec memory_usage(GenServer.server()) :: map()
  def memory_usage(server) do
    GenServer.call(server, :memory_usage, :infinity)
  end

  @spec send_message(GenServer.server(), term()) :: :ok
  def send_message(server, message) do
    GenServer.cast(server, {:send_message, message})
  end

  @spec dom_find(GenServer.server(), String.t()) :: {:ok, term()} | {:ok, nil}
  def dom_find(server, selector) do
    GenServer.call(server, {:dom_find, selector}, :infinity)
  end

  @spec dom_find_all(GenServer.server(), String.t()) :: {:ok, list()}
  def dom_find_all(server, selector) do
    GenServer.call(server, {:dom_find_all, selector}, :infinity)
  end

  @spec dom_text(GenServer.server(), String.t()) :: {:ok, String.t()}
  def dom_text(server, selector) do
    GenServer.call(server, {:dom_text, selector}, :infinity)
  end

  @spec dom_attr(GenServer.server(), String.t(), String.t()) :: {:ok, String.t() | nil}
  def dom_attr(server, selector, attr_name) do
    GenServer.call(server, {:dom_attr, selector, attr_name}, :infinity)
  end

  @spec dom_html(GenServer.server()) :: {:ok, String.t()}
  def dom_html(server) do
    GenServer.call(server, :dom_html, :infinity)
  end

  @builtin_handlers %{
    "__url_parse" => &QuickBEAM.URL.parse/1,
    "__url_recompose" => &QuickBEAM.URL.recompose/1,
    "__url_dissect_query" => &QuickBEAM.URL.dissect_query/1,
    "__url_compose_query" => &QuickBEAM.URL.compose_query/1,
    "__crypto_digest" => &QuickBEAM.SubtleCrypto.digest/1,
    "__crypto_generate_key" => &QuickBEAM.SubtleCrypto.generate_key/1,
    "__crypto_sign" => &QuickBEAM.SubtleCrypto.sign/1,
    "__crypto_verify" => &QuickBEAM.SubtleCrypto.verify/1,
    "__crypto_encrypt" => &QuickBEAM.SubtleCrypto.encrypt/1,
    "__crypto_decrypt" => &QuickBEAM.SubtleCrypto.decrypt/1,
    "__crypto_derive_bits" => &QuickBEAM.SubtleCrypto.derive_bits/1,
    "__compress" => &QuickBEAM.Compression.compress/1,
    "__decompress" => &QuickBEAM.Compression.decompress/1,
    "__fetch" => &QuickBEAM.Fetch.fetch/1,
    "__buffer_encode" => &QuickBEAM.Buffer.encode/1,
    "__buffer_decode" => &QuickBEAM.Buffer.decode/1,
    "__buffer_byte_length" => &QuickBEAM.Buffer.byte_length/1,
    # {:with_caller, fun/2} — receives [args, caller_pid] instead of [args]
    "__broadcast_join" => {:with_caller, &QuickBEAM.BroadcastChannel.join/2},
    "__broadcast_post" => {:with_caller, &QuickBEAM.BroadcastChannel.post/2},
    "__broadcast_leave" => {:with_caller, &QuickBEAM.BroadcastChannel.leave/2},
    "__worker_spawn" => {:with_caller, &QuickBEAM.WorkerAPI.spawn_worker/2},
    "__worker_terminate" => &QuickBEAM.WorkerAPI.terminate_worker/1,
    "__locks_request" => {:with_caller, &QuickBEAM.LocksAPI.request_lock/2},
    "__locks_release" => {:with_caller, &QuickBEAM.LocksAPI.release_lock/2},
    "__locks_query" => &QuickBEAM.LocksAPI.query_locks/1,
    "__storage_get" => &QuickBEAM.Storage.get_item/1,
    "__storage_set" => &QuickBEAM.Storage.set_item/1,
    "__storage_remove" => &QuickBEAM.Storage.remove_item/1,
    "__storage_clear" => &QuickBEAM.Storage.clear/1,
    "__storage_key" => &QuickBEAM.Storage.key/1,
    "__storage_length" => &QuickBEAM.Storage.length/1,
    "__eventsource_open" => {:with_caller, &QuickBEAM.EventSource.open/2},
    "__eventsource_close" => &QuickBEAM.EventSource.close/1
  }

  @ts_dir Path.join([__DIR__, "../../priv/ts"]) |> Path.expand()

  # Standalone modules — each is a self-contained TS file, transformed individually
  @standalone_modules ~w[url crypto-subtle compression buffer process]

  # Web-APIs bundle — barrel file that imports from 16+ internal modules
  @web_apis_barrel "web-apis.ts"

  @builtin_js (
                # Register @external_resource for all TS source files
                for ts <- Path.wildcard(Path.join(@ts_dir, "*.ts")),
                    not String.ends_with?(ts, ".d.ts") do
                  @external_resource ts
                end

                # 1. Transform standalone modules (single-file, no imports)
                standalone =
                  for name <- @standalone_modules do
                    path = Path.join(@ts_dir, "#{name}.ts")
                    source = File.read!(path)

                    OXC.transform!(source, Path.basename(path))
                    |> then(&"(() => {\n#{&1}\n})();\n")
                  end

                # 2. Bundle web-apis (resolves imports, topo-sorts, wraps in IIFE)
                barrel_source = File.read!(Path.join(@ts_dir, @web_apis_barrel))

                bundled_names =
                  Regex.scan(~r/from '\.\/([\w-]+)'/, barrel_source)
                  |> Enum.map(fn [_, name] -> name end)

                side_effect_names =
                  Regex.scan(~r/^import '\.\/([\w-]+)'/m, barrel_source)
                  |> Enum.map(fn [_, name] -> name end)

                all_bundle_names = Enum.uniq(["web-apis" | bundled_names ++ side_effect_names])

                bundle_files =
                  for name <- all_bundle_names do
                    path = Path.join(@ts_dir, "#{name}.ts")
                    {"#{name}.ts", File.read!(path)}
                  end

                web_apis_js = OXC.bundle!(bundle_files)

                standalone ++ [web_apis_js]
              )

  @impl true
  def init(opts) do
    handlers = Keyword.get(opts, :handlers, %{})
    merged_handlers = Map.merge(@builtin_handlers, handlers)

    nif_opts =
      opts
      |> Keyword.take([:memory_limit, :max_stack_size])
      |> Map.new()

    resource = QuickBEAM.Native.start_runtime(self(), nif_opts)
    state = %__MODULE__{resource: resource, handlers: merged_handlers}
    install_builtins(state)

    case load_script(state, opts) do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp load_script(state, opts) do
    case Keyword.fetch(opts, :script) do
      :error -> :ok
      {:ok, path} -> eval_script(state, path)
    end
  end

  defp eval_script(state, path) do
    with {:ok, code} <- read_script(path),
         {:ok, _} <- sync_eval(state.resource, code) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:script_not_found, path, reason}}

      {:error, {:file_read_error, _, reason}} ->
        {:error, {:script_not_found, path, reason}}

      {:error, value} when is_map(value) ->
        {:error, {:script_error, path, QuickBEAM.JSError.from_js_value(value)}}

      {:error, reason} ->
        {:error, {:script_error, path, reason}}
    end
  end

  defp read_script(path) do
    case File.read(path) do
      {:ok, source} ->
        cond do
          has_imports?(source, path) ->
            QuickBEAM.JS.Bundler.bundle_file(path)

          typescript?(path) ->
            OXC.transform(source, Path.basename(path))

          true ->
            {:ok, source}
        end

      {:error, _} = error ->
        error
    end
  end

  defp typescript?(path), do: String.ends_with?(path, ".ts") or String.ends_with?(path, ".tsx")

  defp has_imports?(source, path) do
    case OXC.parse(source, Path.basename(path)) do
      {:ok, ast} -> Enum.any?(ast.body, &(&1.type == "ImportDeclaration"))
      {:error, _} -> false
    end
  end

  @snapshot_builtins_js """
  globalThis.__qb_builtins = Object.create(null);
  for (const k of Object.getOwnPropertyNames(globalThis))
    globalThis.__qb_builtins[k] = true;
  """

  defp install_builtins(state) do
    for js <- @builtin_js do
      sync_eval(state.resource, js)
    end

    sync_eval(state.resource, @snapshot_builtins_js)
  end

  defp sync_eval(resource, code) do
    ref = QuickBEAM.Native.eval(resource, code, 0)
    await_ref(ref)
  end

  defp await_ref(ref) do
    receive do
      {^ref, result} -> result
    after
      30_000 -> {:error, "NIF timeout"}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    handlers =
      state.handlers
      |> Map.keys()
      |> Enum.reject(&String.starts_with?(&1, "__"))
      |> Enum.sort()

    {:reply, handlers, state}
  end

  @impl true
  def handle_call({:eval, code, timeout_ms}, from, state) do
    ref = QuickBEAM.Native.eval(state.resource, code, timeout_ms)

    transform = fn
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call({:compile, code}, from, state) do
    ref = QuickBEAM.Native.compile(state.resource, code)

    transform = fn
      {:ok, {:bytes, bytecode}} -> {:ok, bytecode}
      {:ok, bytecode} -> {:ok, bytecode}
      {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call({:load_bytecode, bytecode}, from, state) do
    ref = QuickBEAM.Native.load_bytecode(state.resource, bytecode)

    transform = fn
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call({:call, fn_name, args, timeout_ms}, from, state) do
    ref = QuickBEAM.Native.call_function(state.resource, fn_name, args, timeout_ms)

    transform = fn
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call({:load_module, name, code}, from, state) do
    ref = QuickBEAM.Native.load_module(state.resource, name, code)

    transform = fn
      {:ok, _} -> :ok
      {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call(:reset, from, state) do
    ref = QuickBEAM.Native.reset_runtime(state.resource)

    transform = fn
      {:ok, _} -> :ok
      {:error, msg} -> {:error, msg}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call(:memory_usage, from, state) do
    ref = QuickBEAM.Native.memory_usage(state.resource)
    {:noreply, put_pending(state, ref, from, fn {:ok, v} -> v; other -> other end)}
  end

  def handle_call({:dom_find, selector}, from, state) do
    ref = QuickBEAM.Native.dom_find(state.resource, selector)
    {:noreply, put_pending(state, ref, from)}
  end

  def handle_call({:dom_find_all, selector}, from, state) do
    ref = QuickBEAM.Native.dom_find_all(state.resource, selector)
    {:noreply, put_pending(state, ref, from)}
  end

  def handle_call({:dom_text, selector}, from, state) do
    ref = QuickBEAM.Native.dom_text(state.resource, selector)
    {:noreply, put_pending(state, ref, from)}
  end

  def handle_call({:dom_attr, selector, attr_name}, from, state) do
    ref = QuickBEAM.Native.dom_attr(state.resource, selector, attr_name)
    {:noreply, put_pending(state, ref, from)}
  end

  def handle_call(:dom_html, from, state) do
    ref = QuickBEAM.Native.dom_html(state.resource)
    {:noreply, put_pending(state, ref, from)}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    QuickBEAM.Native.send_message(state.resource, message)
    {:noreply, state}
  end

  @impl true
  def handle_info({:console, level, message}, state) do
    Logger.log(console_level(level), message)
    {:noreply, state}
  end

  def handle_info({:beam_call, call_id, "__process_monitor", [pid, callback_id]}, state) do
    ref = Process.monitor(pid)
    monitors = Map.put(state.monitors, ref, callback_id)
    QuickBEAM.Native.resolve_call_term(state.resource, call_id, ref)
    {:noreply, %{state | monitors: monitors}}
  end

  def handle_info({:beam_call, call_id, "__process_demonitor", [ref]}, state) do
    {callback_id, monitors} = Map.pop(state.monitors, ref)
    if ref, do: Process.demonitor(ref, [:flush])
    QuickBEAM.Native.resolve_call_term(state.resource, call_id, callback_id)
    {:noreply, %{state | monitors: monitors}}
  end

  def handle_info({:beam_call, call_id, handler_name, args}, state) do
    resource = state.resource
    handlers = state.handlers

    caller = self()

    case Map.get(handlers, handler_name) do
      nil ->
        QuickBEAM.Native.reject_call_term(resource, call_id, "Unknown handler: #{handler_name}")

      handler ->
        Task.start(fn ->
          try do
            args = if is_list(args), do: args, else: [args]

            result =
              case handler do
                {:with_caller, fun} -> fun.(args, caller)
                fun -> fun.(args)
              end

            QuickBEAM.Native.resolve_call_term(resource, call_id, result)
          rescue
            e ->
              QuickBEAM.Native.reject_call_term(resource, call_id, Exception.message(e))
          end
        end)
    end

    {:noreply, state}
  end

  def handle_info({:worker_monitor, child_pid}, state) do
    ref = Process.monitor(child_pid)
    workers = Map.put(state.workers, ref, child_pid)
    {:noreply, %{state | workers: workers}}
  end

  def handle_info({:worker_error_from_child, child_pid, error}, state) do
    message =
      if is_struct(error), do: Map.get(error, :message, "Worker error"), else: "Worker error"

    QuickBEAM.Native.send_message(state.resource, ["__worker_err", child_pid, message])
    {:noreply, state}
  end

  def handle_info({:eventsource_open, id}, state) do
    QuickBEAM.Native.send_message(state.resource, ["__eventsource_open", id])
    {:noreply, state}
  end

  def handle_info({:eventsource_event, id, event}, state) do
    QuickBEAM.Native.send_message(state.resource, [
      "__eventsource_event",
      id,
      event.type,
      event.data,
      event.id
    ])

    {:noreply, state}
  end

  def handle_info({:eventsource_error, id, reason}, state) do
    QuickBEAM.Native.send_message(state.resource, ["__eventsource_error", id, reason])
    {:noreply, state}
  end

  def handle_info({:broadcast_message, channel, data}, state) do
    resource = state.resource

    Task.start(fn ->
      QuickBEAM.Native.call_function(resource, "__qb_broadcast_dispatch", [channel, data], 0)
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        case Map.pop(state.monitors, ref) do
          {nil, _} ->
            {:noreply, state}

          {callback_id, monitors} ->
            QuickBEAM.Native.send_message(state.resource, ["__qb_down", callback_id, reason])
            {:noreply, %{state | monitors: monitors}}
        end

      {child_pid, workers} ->
        unless reason == :normal do
          message = inspect(reason)
          QuickBEAM.Native.send_message(state.resource, ["__worker_err", child_pid, message])
        end

        {:noreply, %{state | workers: workers}}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, nil}, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}

      {{from, transform}, pending} ->
        GenServer.reply(from, transform.(result))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(msg, state) do
    QuickBEAM.Native.send_message(state.resource, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{resource: resource} = state) do
    drain_beam_calls(resource, state.handlers)
    QuickBEAM.Native.stop_runtime(resource)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp drain_beam_calls(resource, handlers) do
    receive do
      {:beam_call, call_id, handler_name, args} ->
        handle_beam_call_sync(resource, handlers, call_id, handler_name, args)
        drain_beam_calls(resource, handlers)
    after
      0 -> :ok
    end
  end

  defp handle_beam_call_sync(resource, handlers, call_id, handler_name, args) do
    case Map.get(handlers, handler_name) do
      nil ->
        QuickBEAM.Native.reject_call_term(resource, call_id, "Unknown handler: #{handler_name}")

      handler ->
        try do
          args = if is_list(args), do: args, else: [args]

          result =
            case handler do
              {:with_caller, fun} -> fun.(args, self())
              fun -> fun.(args)
            end

          QuickBEAM.Native.resolve_call_term(resource, call_id, result)
        rescue
          e -> QuickBEAM.Native.reject_call_term(resource, call_id, Exception.message(e))
        end
    end
  end

  defp put_pending(state, ref, from, transform \\ nil) do
    %{state | pending: Map.put(state.pending, ref, {from, transform})}
  end

  defp console_level("error"), do: :error
  defp console_level("warning"), do: :warning
  defp console_level(_), do: :info
end
