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

  @spec send_message(GenServer.server(), term()) :: :ok
  def send_message(server, message) do
    GenServer.cast(server, {:send_message, message})
  end

  @impl true
  def init(opts) do
    handlers = Keyword.get(opts, :handlers, %{})

    case QuickBEAM.Native.start_runtime(self()) do
      resource when is_reference(resource) ->
        {:ok, %__MODULE__{resource: resource, handlers: handlers}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:eval, code}, from, state) do
    resource = state.resource

    Task.start(fn ->
      result =
        case QuickBEAM.Native.eval(resource, code) do
          {:ok, json} -> decode_result(json)
          {:error, msg} -> {:error, msg}
        end

      GenServer.reply(from, result)
    end)

    {:noreply, state}
  end

  def handle_call({:call, fn_name, args}, from, state) do
    resource = state.resource
    args_json = Jason.encode!(args)

    Task.start(fn ->
      result =
        case QuickBEAM.Native.call_function(resource, fn_name, args_json) do
          {:ok, json} -> decode_result(json)
          {:error, msg} -> {:error, msg}
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
          {:error, msg} -> {:error, msg}
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

  @impl true
  def handle_cast({:send_message, message}, state) do
    QuickBEAM.Native.send_message(state.resource, Jason.encode!(message))
    {:noreply, state}
  end

  @impl true
  def handle_info({:beam_call, call_id, handler_name, args_json}, state) do
    resource = state.resource
    handlers = state.handlers

    args =
      case Jason.decode(args_json) do
        {:ok, decoded} -> decoded
        _ -> []
      end

    case Map.get(handlers, handler_name) do
      nil ->
        QuickBEAM.Native.reject_call(resource, call_id, "Unknown handler: #{handler_name}")

      handler when is_function(handler) ->
        Task.start(fn ->
          try do
            result =
              case args do
                args when is_list(args) -> handler.(args)
                _ -> handler.([args])
              end

            QuickBEAM.Native.resolve_call(resource, call_id, Jason.encode!(result))
          rescue
            e ->
              QuickBEAM.Native.reject_call(resource, call_id, Exception.message(e))
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

  defp decode_result(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:ok, json}
    end
  end
end
