defmodule QuickBEAM.VM.Value do
  @moduledoc """
  Type definitions and guards for JavaScript values in the BEAM VM.

  Spec:
  - ECMA-262 §6.1 ECMAScript Language Types
  - ECMA-262 §6.2 ECMAScript Specification Types

  Implementation notes:
  - `null` is represented as `nil`.
  - `undefined` is represented as `:undefined`.
  - Object identity is represented as `{:obj, heap_ref}`.
  - Built-in functions are represented as `{:builtin, name, callback_or_map}`.
  - Abrupt completions are represented with `throw({:js_throw, value})`; see
    `QuickBEAM.VM.SpecTypes.Completion`.
  """

  @type heap_ref :: reference() | pos_integer()
  @type object :: {:obj, heap_ref()}
  @type closure :: {:closure, map(), QuickBEAM.VM.Function.t()}
  @type builtin :: {:builtin, binary(), function() | map()}
  @type bound :: {:bound, non_neg_integer(), term(), term(), list()}
  @type symbol :: {:symbol, binary()} | {:symbol, binary(), reference()}
  @type bigint :: {:bigint, integer()}
  @type js_value ::
          nil
          | :undefined
          | :nan
          | :infinity
          | :neg_infinity
          | boolean()
          | number()
          | binary()
          | object()
          | closure()
          | builtin()
          | bound()
          | symbol()
          | bigint()

  defguard is_object(v) when is_tuple(v) and tuple_size(v) == 2 and elem(v, 0) == :obj

  defguard is_symbol(v)
           when is_tuple(v) and (tuple_size(v) == 2 or tuple_size(v) == 3) and
                  elem(v, 0) == :symbol

  defguard is_bigint(v) when is_tuple(v) and tuple_size(v) == 2 and elem(v, 0) == :bigint
  defguard is_closure(v) when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :closure
  defguard is_builtin(v) when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :builtin
  defguard is_nullish(v) when v == nil or v == :undefined

  @doc "Returns true when the VM value is null or undefined."
  def nullish?(value), do: value == nil or value == :undefined

  @doc "Returns true when the VM value is a Symbol primitive."
  def symbol?({:symbol, _}), do: true
  def symbol?({:symbol, _, _}), do: true
  def symbol?(_), do: false

  @doc "Returns the Symbol description/name payload."
  def symbol_name({:symbol, name}), do: name
  def symbol_name({:symbol, name, _ref}), do: name

  @doc "Returns true when a function value has a constructor prototype property."
  def has_function_prototype?(%QuickBEAM.VM.Function{has_prototype: true}), do: true

  def has_function_prototype?({:closure, _, %QuickBEAM.VM.Function{has_prototype: true}}),
    do: true

  def has_function_prototype?(%QuickBEAM.VM.Function{func_kind: 1}), do: true
  def has_function_prototype?({:closure, _, %QuickBEAM.VM.Function{func_kind: 1}}), do: true
  def has_function_prototype?(_), do: false

  @doc "Returns true when a VM function value executes in strict mode."
  def strict_function?({:closure, _, %QuickBEAM.VM.Function{is_strict_mode: strict}}), do: strict
  def strict_function?(%QuickBEAM.VM.Function{is_strict_mode: strict}), do: strict
  def strict_function?(_), do: false

  @doc "Returns true when an execution context is currently strict."
  def strict_context?(%{current_func: current_func}), do: strict_function?(current_func)
  def strict_context?(_), do: false

  @doc "Returns true when the VM value is represented as a callable/function object."
  def function_like?({:closure, _, _}), do: true
  def function_like?({:builtin, _, _}), do: true
  def function_like?({:bound, _, _, _, _}), do: true
  def function_like?(%QuickBEAM.VM.Function{}), do: true
  def function_like?(_), do: false

  @doc "Returns true when the VM value has ECMAScript object semantics."
  def object_like?({:obj, _}), do: true
  def object_like?({:regexp, _, _}), do: true
  def object_like?({:regexp, _, _, _}), do: true
  def object_like?(value), do: function_like?(value)
end
