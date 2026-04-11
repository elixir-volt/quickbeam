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

      defp js_error_transform do
        fn
          {:ok, value} -> {:ok, value}
          {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
        end
      end

      # ── Shared handle_call clauses ──

      @impl true
      def handle_call({:eval, code, timeout_ms}, from, state) do
        ref = nif_eval(state, code, timeout_ms)
        {:noreply, put_pending(state, ref, from, js_error_transform())}
      end

      @impl true
      def handle_call({:call, fn_name, args, timeout_ms}, from, state) do
        ref = nif_call(state, fn_name, args, timeout_ms)
        {:noreply, put_pending(state, ref, from, js_error_transform())}
      end

      @impl true
      def handle_call({:dom_find, selector}, from, state) do
        ref = nif_dom_find(state, selector)
        {:noreply, put_pending(state, ref, from)}
      end

      @impl true
      def handle_call({:dom_find_all, selector}, from, state) do
        ref = nif_dom_find_all(state, selector)
        {:noreply, put_pending(state, ref, from)}
      end

      @impl true
      def handle_call({:dom_text, selector}, from, state) do
        ref = nif_dom_text(state, selector)
        {:noreply, put_pending(state, ref, from)}
      end

      @impl true
      def handle_call(:dom_html, from, state) do
        ref = nif_dom_html(state)
        {:noreply, put_pending(state, ref, from)}
      end

      # memory_usage is NOT shared — Runtime unwraps {:ok, v} → v,
      # Context returns {:ok, map}. Each module implements its own.

      @impl true
      def handle_call(:reset, from, state) do
        ref = nif_reset(state)

        transform = fn
          {:ok, _} -> :ok
          {:error, msg} -> {:error, msg}
        end

        {:noreply, put_pending(state, ref, from, transform)}
      end

      @impl true
      def handle_call({:get_global, name}, from, state) do
        ref = nif_get_global(state, name)
        {:noreply, put_pending(state, ref, from, js_error_transform())}
      end

      @impl true
      def handle_call({:set_global, name, value}, _from, state) do
        nif_set_global(state, name, value)
        {:reply, :ok, state}
      end

      @impl true
      def handle_cast({:send_message, message}, state) do
        nif_send_message(state, message)
        {:noreply, state}
      end

      # ── WebSocket helpers ──

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
