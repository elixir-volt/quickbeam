defmodule QuickBEAM.Runtime do
  use GenServer

  @enforce_keys [:resource]
  defstruct [:resource, handlers: %{}]

  @type t :: %__MODULE__{resource: reference(), handlers: map()}

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
    "__crypto_digest" => &QuickBEAM.SubtleCrypto.digest/1,
    "__crypto_generate_key" => &QuickBEAM.SubtleCrypto.generate_key/1,
    "__crypto_sign" => &QuickBEAM.SubtleCrypto.sign/1,
    "__crypto_verify" => &QuickBEAM.SubtleCrypto.verify/1,
    "__crypto_encrypt" => &QuickBEAM.SubtleCrypto.encrypt/1,
    "__crypto_decrypt" => &QuickBEAM.SubtleCrypto.decrypt/1,
    "__crypto_derive_bits" => &QuickBEAM.SubtleCrypto.derive_bits/1,
    "__compress" => &QuickBEAM.Compression.compress/1,
    "__decompress" => &QuickBEAM.Compression.decompress/1
  }

  @priv_js_dir Path.join([__DIR__, "../../priv/js"]) |> Path.expand()
  @url_js_path Path.join(@priv_js_dir, "url.js")
  @crypto_js_path Path.join(@priv_js_dir, "crypto-subtle.js")
  @external_resource @url_js_path
  @external_resource @crypto_js_path
  @compression_js_path Path.join(@priv_js_dir, "compression.js")
  @external_resource @compression_js_path
  @url_js File.read!(@url_js_path)
  @crypto_js File.read!(@crypto_js_path)
  @compression_js File.read!(@compression_js_path)

  @impl true
  def init(opts) do
    handlers = Keyword.get(opts, :handlers, %{})
    merged_handlers = Map.merge(@builtin_handlers, handlers)

    case QuickBEAM.Native.start_runtime(self()) do
      resource when is_reference(resource) ->
        state = %__MODULE__{resource: resource, handlers: merged_handlers}
        install_builtins(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp install_builtins(state) do
    QuickBEAM.Native.eval(state.resource, @url_js)
    QuickBEAM.Native.eval(state.resource, @crypto_js)
    QuickBEAM.Native.eval(state.resource, @compression_js)
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

    case Map.get(handlers, handler_name) do
      nil ->
        QuickBEAM.Native.reject_call_term(resource, call_id, "Unknown handler: #{handler_name}")

      handler when is_function(handler) ->
        Task.start(fn ->
          try do
            args = if is_list(args), do: args, else: [args]
            result = handler.(args)
            QuickBEAM.Native.resolve_call_term(resource, call_id, result)
          rescue
            e ->
              QuickBEAM.Native.reject_call_term(resource, call_id, Exception.message(e))
          end
        end)
    end

    {:noreply, state}
  end

  def handle_info({:beam_message, _name, _message}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{resource: resource}) do
    QuickBEAM.Native.stop_runtime(resource)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
