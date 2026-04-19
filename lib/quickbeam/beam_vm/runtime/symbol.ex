defmodule QuickBEAM.BeamVM.Runtime.Symbol do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin

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
    build_methods do
      val("iterator", {:symbol, "Symbol.iterator"})
      val("toPrimitive", {:symbol, "Symbol.toPrimitive"})
      val("hasInstance", {:symbol, "Symbol.hasInstance"})
      val("toStringTag", {:symbol, "Symbol.toStringTag"})
      val("asyncIterator", {:symbol, "Symbol.asyncIterator"})
      val("isConcatSpreadable", {:symbol, "Symbol.isConcatSpreadable"})
      val("species", {:symbol, "Symbol.species"})
      val("match", {:symbol, "Symbol.match"})
      val("replace", {:symbol, "Symbol.replace"})
      val("search", {:symbol, "Symbol.search"})
      val("split", {:symbol, "Symbol.split"})

      method "for" do
        do_symbol_for(hd(args))
      end

      method "keyFor" do
        do_symbol_key_for(hd(args))
      end
    end
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
