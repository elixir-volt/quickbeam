defmodule QuickBEAM.VM.Runtime do
  @moduledoc "Shared helpers for the BEAM JS runtime: coercion, callbacks, object creation."

  alias QuickBEAM.VM.{Heap, Invocation, RuntimeState}
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Semantics.Coercion
  alias QuickBEAM.VM.Runtime.Globals

  @doc "Returns the current runtime global binding map, building and caching it when needed."
  def global_bindings do
    case Heap.get_global_cache() do
      nil -> Globals.build()
      cached -> cached
    end
  end

  @doc "Looks up a globally registered constructor by JavaScript name."
  defdelegate global_constructor(name), to: QuickBEAM.VM.Runtime.ConstructorRegistry, as: :lookup
  @doc "Returns the class prototype associated with a globally registered constructor."
  defdelegate global_class_proto(name), to: QuickBEAM.VM.Runtime.ConstructorRegistry, as: :class_proto

  @doc "Invokes a global constructor and returns `fallback.()` when it is unavailable."
  defdelegate construct_global(name, args, fallback),
    to: QuickBEAM.VM.Runtime.ConstructorRegistry,
    as: :construct

  @doc "Invokes a global constructor and updates the constructed object map before returning it."
  defdelegate construct_global(name, args, fallback, update_object),
    to: QuickBEAM.VM.Runtime.ConstructorRegistry,
    as: :construct

  # ── Callback dispatch (used by higher-order array methods) ──

  @doc "Calls a JavaScript callback, converting JavaScript throws to `:undefined`."
  def call_callback_or_undefined(fun, args), do: Invocation.call_callback_or_undefined(fun, args)

  @doc false
  def call_callback(fun, args), do: call_callback_or_undefined(fun, args)

  @doc "Returns the active interpreter gas budget or the default budget outside evaluation."
  def gas_budget do
    case RuntimeState.current() do
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

  @doc "Stringifies a VM value using JavaScript conversion rules."
  def stringify(val), do: Values.stringify(val)

  @doc "Coerces simple runtime helper inputs to an integer, defaulting unsupported values to zero."
  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: trunc(n)
  def to_int(true), do: 1
  def to_int(false), do: 0
  def to_int(nil), do: 0
  def to_int(:undefined), do: 0
  def to_int(:nan), do: 0
  def to_int(:infinity), do: 0
  def to_int(:neg_infinity), do: 0

  def to_int({:bigint, _}) do
    throw({:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")})
  end

  def to_int(val) do
    n = to_number(val)
    if is_number(n), do: trunc(n), else: 0
  end

  @doc "Coerces simple runtime helper inputs to a float-like value."
  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0
  def to_float(:infinity), do: :infinity
  def to_float(:neg_infinity), do: :neg_infinity
  def to_float(:nan), do: :nan
  def to_float(_), do: 0.0

  @doc "Coerces a VM value to a JavaScript number-like value."
  def to_number({:bigint, n}), do: bigint_to_number(n)
  def to_number(val), do: Values.to_number(val)
  def to_number({:bigint, n}, _hint), do: bigint_to_number(n)
  def to_number(val, hint), do: Coercion.to_number(val, hint)

  defp bigint_to_number(n) when abs(n) <= 9_007_199_254_740_991, do: n
  defp bigint_to_number(n), do: n * 1.0

  @doc "Normalizes a possibly-negative index against a sequence length."
  def normalize_index(idx, len) when idx < 0, do: max(len + idx, 0)
  def normalize_index(idx, len), do: min(idx, len)

  @doc "Sorts JavaScript array-index-like keys before ordinary string keys."
  def sort_numeric_keys(keys), do: QuickBEAM.VM.ObjectModel.PropertyKey.sort_own_keys(keys)
end
