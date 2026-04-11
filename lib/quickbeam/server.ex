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
        websockets = Map.put(state.websockets, socket_id, {pid, ref})
        {:noreply, %{state | websockets: websockets}}
      end

      defp pop_websocket(state, ref) do
        case Enum.find(state.websockets, fn {_socket_id, {_pid, monitor_ref}} -> monitor_ref == ref end) do
          {socket_id, {_pid, _monitor_ref}} ->
            {true, %{state | websockets: Map.delete(state.websockets, socket_id)}}

          nil ->
            {false, state}
        end
      end

      defp shutdown_websockets(state) do
        for {_socket_id, {pid, ref}} <- state.websockets do
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
