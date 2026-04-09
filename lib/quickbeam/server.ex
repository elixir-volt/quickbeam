defmodule QuickBEAM.Server do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @spec call(GenServer.server(), String.t(), list(), keyword()) ::
              QuickBEAM.js_result()
      def call(server, fn_name, args \\ [], opts \\ [])
          when is_binary(fn_name) and is_list(args) do
        timeout_ms = Keyword.get(opts, :timeout, 0)
        GenServer.call(server, {:call, fn_name, args, timeout_ms}, :infinity)
      end

      defp handle_pending_ref(ref, result, state) do
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

      defp put_pending(state, ref, from, transform \\ nil) do
        %{state | pending: Map.put(state.pending, ref, {from, transform})}
      end

      defp handle_websocket_started(socket_id, pid, state) do
        ref = Process.monitor(pid)
        websockets = Map.put(state.websockets, ref, {pid, socket_id})
        {:noreply, %{state | websockets: websockets}}
      end

      defp pop_websocket(state, ref) do
        case Map.pop(state.websockets, ref) do
          {{_pid, _socket_id}, websockets} -> {true, %{state | websockets: websockets}}
          {nil, _} -> {false, state}
        end
      end

      defp shutdown_websockets(state) do
        for {ref, {pid, _id}} <- state.websockets do
          Process.exit(pid, :shutdown)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            5_000 -> :ok
          end
        end
      end
    end
  end
end
