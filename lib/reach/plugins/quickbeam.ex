if Code.ensure_loaded?(Reach.Plugin) do
  defmodule Reach.Plugins.QuickBEAM do
    @moduledoc false
    alias Reach.IR.Node

    def analyze(_all_nodes, _opts), do: []

    def analyze_embedded(_all_nodes, _opts), do: {[], []}

    def classify_effect(%Node{type: :call, meta: %{module: QuickBEAM, function: function}})
        when function in [
               :eval,
               :call,
               :load_module,
               :load_bytecode,
               :send_message,
               :start,
               :stop,
               :reset
             ],
        do: :io

    def classify_effect(%Node{type: :call, meta: %{module: QuickBEAM, function: function}})
        when function in [
               :compile,
               :disasm,
               :globals,
               :get_global,
               :info,
               :memory_usage,
               :coverage
             ],
        do: :read

    def classify_effect(%Node{type: :call, meta: %{module: QuickBEAM, function: :set_global}}),
      do: :write

    def classify_effect(_node), do: nil
  end
end
