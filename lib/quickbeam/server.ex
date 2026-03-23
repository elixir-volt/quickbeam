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
    end
  end
end
