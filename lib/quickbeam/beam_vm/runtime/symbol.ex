defmodule QuickBEAM.BeamVM.Runtime.Symbol do
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  def constructor do
    fn args, _this ->
      desc =
        case args do
          [s | _] when is_binary(s) -> s
          _ -> ""
        end

      {:symbol, desc, make_ref()}
    end
  end

  def statics do
    %{
      "iterator" => {:symbol, "Symbol.iterator"},
      "toPrimitive" => {:symbol, "Symbol.toPrimitive"},
      "hasInstance" => {:symbol, "Symbol.hasInstance"},
      "toStringTag" => {:symbol, "Symbol.toStringTag"},
      "asyncIterator" => {:symbol, "Symbol.asyncIterator"},
      "isConcatSpreadable" => {:symbol, "Symbol.isConcatSpreadable"},
      "species" => {:symbol, "Symbol.species"},
      "match" => {:symbol, "Symbol.match"},
      "replace" => {:symbol, "Symbol.replace"},
      "search" => {:symbol, "Symbol.search"},
      "split" => {:symbol, "Symbol.split"},
      "for" => {:builtin, "for", fn [key | _], _this -> do_symbol_for(key) end},
      "keyFor" => {:builtin, "keyFor", fn [sym | _], _this -> do_symbol_key_for(sym) end}
    }
  end

  defp do_symbol_for(key) do
    case Heap.get_symbol(key) do
      nil ->
        sym = {:symbol, key}
        Heap.put_symbol(key, sym)
        sym

      existing ->
        existing
    end
  end

  defp do_symbol_key_for(sym) do
    case sym do
      {:symbol, key} -> key
      {:symbol, key, _ref} -> key
      _ -> :undefined
    end
  end
end
