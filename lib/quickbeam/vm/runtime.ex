defmodule QuickBEAM.VM.Runtime do
  @moduledoc "Shared helpers for the BEAM JS runtime: coercion, callbacks, object creation."

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.Interpreter.{Context, Values}
  alias QuickBEAM.VM.Runtime.Globals

  @doc "Returns the current runtime global binding map, building and caching it when needed."
  def global_bindings do
    case Heap.get_global_cache() do
      nil -> Globals.build()
      cached -> cached
    end
  end

  @doc "Looks up a globally registered constructor by JavaScript name."
  defdelegate global_constructor(name), to: QuickBEAM.VM.Runtime.Constructors, as: :lookup
  @doc "Returns the class prototype associated with a globally registered constructor."
  defdelegate global_class_proto(name), to: QuickBEAM.VM.Runtime.Constructors, as: :class_proto

  @doc "Invokes a global constructor and returns `fallback.()` when it is unavailable."
  defdelegate construct_global(name, args, fallback),
    to: QuickBEAM.VM.Runtime.Constructors,
    as: :construct

  @doc "Invokes a global constructor and updates the constructed object map before returning it."
  defdelegate construct_global(name, args, fallback, update_object),
    to: QuickBEAM.VM.Runtime.Constructors,
    as: :construct

  # ── Callback dispatch (used by higher-order array methods) ──

  @doc "Calls a JavaScript callback using the active invocation context."
  def call_callback(fun, args), do: Invocation.call_callback(fun, args)

  @doc "Returns the active interpreter gas budget or the default budget outside evaluation."
  def gas_budget do
    case Heap.get_ctx() do
      %{gas: gas} -> gas
      _ -> Context.default_gas()
    end
  end

  # ── Shared helpers (public for cross-module use) ──

  @doc "Creates an empty JavaScript object value."
  def new_object do
    Heap.wrap(%{})
  end

  @doc "Returns JavaScript truthiness for a VM value."
  defdelegate truthy?(val), to: Values

  @doc "Returns strict BEAM equality for places that need identity-style comparison."
  def strict_equal?(a, b), do: a === b

  @doc "Stringifies a VM value using JavaScript conversion rules."
  def stringify(val), do: Values.stringify(val)

  @doc "Coerces simple runtime helper inputs to an integer, defaulting unsupported values to zero."
  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: trunc(n)
  def to_int(_), do: 0

  @doc "Coerces simple runtime helper inputs to a float-like value."
  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0
  def to_float(:infinity), do: :infinity
  def to_float(:neg_infinity), do: :neg_infinity
  def to_float(:nan), do: :nan
  def to_float(_), do: 0.0

  @doc "Coerces a VM value to a JavaScript number-like value."
  def to_number({:bigint, n}), do: n
  def to_number(val), do: Values.to_number(val)

  @doc "Normalizes a possibly-negative index against a sequence length."
  def normalize_index(idx, len) when idx < 0, do: max(len + idx, 0)
  def normalize_index(idx, len), do: min(idx, len)

  @max_array_index 4_294_967_294

  @doc "Sorts JavaScript array-index-like keys before ordinary string keys."
  def sort_numeric_keys(keys) do
    {numeric, strings} =
      Enum.split_with(keys, fn
        k when is_integer(k) and k >= 0 and k <= @max_array_index ->
          true

        k when is_binary(k) ->
          case Integer.parse(k) do
            {n, ""} when n >= 0 and n <= @max_array_index -> true
            _ -> false
          end

        _ ->
          false
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
