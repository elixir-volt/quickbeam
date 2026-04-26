defmodule QuickBEAM.VM.Runtime.Symbol do
  @moduledoc "JS `Symbol` built-in: constructor, global symbol registry (`Symbol.for`/`keyFor`), and well-known symbol constants."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap

  @doc "Builds the JavaScript constructor object for this runtime builtin."
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

  static_val("iterator", {:symbol, "Symbol.iterator"})
  static_val("toPrimitive", {:symbol, "Symbol.toPrimitive"})
  static_val("hasInstance", {:symbol, "Symbol.hasInstance"})
  static_val("toStringTag", {:symbol, "Symbol.toStringTag"})
  static_val("asyncIterator", {:symbol, "Symbol.asyncIterator"})
  static_val("isConcatSpreadable", {:symbol, "Symbol.isConcatSpreadable"})
  static_val("species", {:symbol, "Symbol.species"})
  static_val("match", {:symbol, "Symbol.match"})
  static_val("replace", {:symbol, "Symbol.replace"})
  static_val("search", {:symbol, "Symbol.search"})
  static_val("split", {:symbol, "Symbol.split"})
  static_val("unscopables", {:symbol, "Symbol.unscopables"})

  static "for" do
    key = hd(args)

    case Heap.get_symbol(key) do
      nil ->
        sym = {:symbol, key}
        Heap.put_symbol(key, sym)
        sym

      existing ->
        existing
    end
  end

  static "keyFor" do
    case hd(args) do
      {:symbol, key} -> key
      _ -> :undefined
    end
  end
end
