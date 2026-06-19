defmodule QuickBEAM.VM.JSThrow do
  @moduledoc "Helpers for throwing JS errors from the BEAM VM."

  alias QuickBEAM.VM.Heap

  @doc "Throws a JavaScript `TypeError` with the given message."
  def type_error!(message), do: throw({:js_throw, Heap.make_error(message, "TypeError")})

  def reference_error!(message),
    do: throw({:js_throw, Heap.make_error(message, "ReferenceError")})

  def range_error!(message), do: throw({:js_throw, Heap.make_error(message, "RangeError")})
  def syntax_error!(message), do: throw({:js_throw, Heap.make_error(message, "SyntaxError")})
  def error!(message), do: throw({:js_throw, Heap.make_error(message, "Error")})
end
