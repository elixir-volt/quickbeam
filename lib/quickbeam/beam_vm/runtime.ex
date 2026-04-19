defmodule QuickBEAM.BeamVM.Runtime do

  @moduledoc "Shared helpers for the BEAM JS runtime: coercion, callbacks, object creation."

  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.{Builtin, Interpreter}

  def global_bindings do
    case Heap.get_global_cache() do
      nil -> QuickBEAM.BeamVM.Runtime.Globals.build()
      cached -> cached
    end
  end

  # ── Callback dispatch (used by higher-order array methods) ──

  def call_callback(fun, args) do
    case fun do
      %Bytecode.Function{} = f ->
        Interpreter.invoke(f, args, 10_000_000)

      {:closure, _, %Bytecode.Function{}} = c ->
        Interpreter.invoke(c, args, 10_000_000)

      other ->
        try do
          Builtin.call(other, args, nil)
        catch
          {:js_throw, _} -> :undefined
        end
    end
  end

  # ── Shared helpers (public for cross-module use) ──

  def new_object do
    Heap.wrap(%{})
  end

  defdelegate truthy?(val), to: Values

  def strict_equal?(a, b), do: a === b

  def stringify(val), do: Values.stringify(val)

  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: trunc(n)
  def to_int(_), do: 0

  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0
  def to_float(_), do: 0.0

  def to_number({:bigint, n}), do: n
  def to_number(val), do: Values.to_number(val)

  def normalize_index(idx, len) when idx < 0, do: max(len + idx, 0)
  def normalize_index(idx, len), do: min(idx, len)

  def sort_numeric_keys(keys) do
    {numeric, strings} =
      Enum.split_with(keys, fn
        k when is_integer(k) -> true
        k when is_binary(k) -> match?({_, ""}, Integer.parse(k))
        _ -> false
      end)

    sorted =
      Enum.sort_by(numeric, fn
        k when is_integer(k) -> k
        k when is_binary(k) -> elem(Integer.parse(k), 0)
      end)
      |> Enum.map(fn
        k when is_integer(k) -> Integer.to_string(k)
        k -> k
      end)

    sorted ++ Enum.filter(strings, &is_binary/1)
  end
end
