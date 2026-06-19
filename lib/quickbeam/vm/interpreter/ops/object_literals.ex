defmodule QuickBEAM.VM.Interpreter.Ops.ObjectLiterals do
  @moduledoc "Shared object-literal helpers used by interpreter object op dispatch."

  alias QuickBEAM.VM.Heap

  def array_from(values) do
    ref = make_ref()
    Heap.put_obj(ref, values)

    values
    |> Enum.with_index()
    |> Enum.each(fn {_value, index} ->
      Heap.put_prop_desc(ref, Integer.to_string(index), %{
        writable: true,
        enumerable: true,
        configurable: true
      })
    end)

    {:obj, ref}
  end
end
