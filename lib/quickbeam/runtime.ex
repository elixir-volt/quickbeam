defmodule QuickBEAM.Runtime do
  @moduledoc false
  use GenServer

  @enforce_keys [:resource]
  defstruct [:resource, handlers: %{}]

  @type t :: %__MODULE__{resource: reference(), handlers: map()}

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

  @spec eval(GenServer.server(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def eval(server, code) when is_binary(code) do
    GenServer.call(server, {:eval, code}, :infinity)
  end

  @spec call(GenServer.server(), String.t(), list()) :: {:ok, term()} | {:error, String.t()}
  def call(server, fn_name, args \\ []) when is_binary(fn_name) and is_list(args) do
    GenServer.call(server, {:call, fn_name, args}, :infinity)
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
    # {:with_caller, fun/2} — receives [args, caller_pid] instead of [args]
    "__broadcast_join" => {:with_caller, &QuickBEAM.BroadcastChannel.join/2},
    "__broadcast_post" => {:with_caller, &QuickBEAM.BroadcastChannel.post/2},
    "__broadcast_leave" => {:with_caller, &QuickBEAM.BroadcastChannel.leave/2}
  }

  @priv_js_dir Path.join([__DIR__, "../../priv/js"]) |> Path.expand()

  @js_load_order ~w[
    url
    crypto-subtle
    compression
    web-apis
  ]

  @builtin_js (for name <- @js_load_order do
                 path = Path.join(@priv_js_dir, "#{name}.js")
                 @external_resource path
                 File.read!(path)
               end)

  @impl true
  def init(opts) do
    handlers = Keyword.get(opts, :handlers, %{})
    merged_handlers = Map.merge(@builtin_handlers, handlers)

    resource = QuickBEAM.Native.start_runtime(self())
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
    with {:ok, code} <- File.read(path),
         {:ok, _} <- QuickBEAM.Native.eval(state.resource, code) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:script_not_found, path, reason}}

      {:error, value} ->
        {:error, {:script_error, path, QuickBEAM.JSError.from_js_value(value)}}
    end
  end

  defp install_builtins(state) do
    for js <- @builtin_js do
      QuickBEAM.Native.eval(state.resource, js)
    end
  end

  @impl true
  def handle_call({:eval, code}, from, state) do
    resource = state.resource

    Task.start(fn ->
      result =
        case QuickBEAM.Native.eval(resource, code) do
          {:ok, value} -> {:ok, value}
          {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
        end

      GenServer.reply(from, result)
    end)

    {:noreply, state}
  end

  def handle_call({:call, fn_name, args}, from, state) do
    resource = state.resource

    Task.start(fn ->
      result =
        case QuickBEAM.Native.call_function(resource, fn_name, args) do
          {:ok, value} -> {:ok, value}
          {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
        end

      GenServer.reply(from, result)
    end)

    {:noreply, state}
  end

  def handle_call({:load_module, name, code}, from, state) do
    resource = state.resource

    Task.start(fn ->
      result =
        case QuickBEAM.Native.load_module(resource, name, code) do
          {:ok, _} -> :ok
          {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
        end

      GenServer.reply(from, result)
    end)

    {:noreply, state}
  end

  def handle_call(:reset, from, state) do
    resource = state.resource

    Task.start(fn ->
      result =
        case QuickBEAM.Native.reset_runtime(resource) do
          {:ok, _} -> :ok
          {:error, msg} -> {:error, msg}
        end

      GenServer.reply(from, result)
    end)

    {:noreply, state}
  end

  def handle_call(:memory_usage, _from, state) do
    {:reply, QuickBEAM.Native.memory_usage(state.resource), state}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    QuickBEAM.Native.send_message(state.resource, message)
    {:noreply, state}
  end

  @impl true
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

  def handle_info({:broadcast_message, channel, data}, state) do
    resource = state.resource

    Task.start(fn ->
      QuickBEAM.Native.call_function(resource, "__qb_broadcast_dispatch", [channel, data])
    end)

    {:noreply, state}
  end

  def handle_info(msg, state) do
    QuickBEAM.Native.send_message(state.resource, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{resource: resource}) do
    QuickBEAM.Native.stop_runtime(resource)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
