defmodule QuickBEAM.VM.Opcodes.Values do
  @moduledoc """
  Executes coercion, comparison, arithmetic, and value-test opcode families.

  Operations delegate to the canonical value, invocation, and property semantic
  layers. Results are explicit `:next` or `:throw` actions consumed by the
  interpreter.
  """

  alias QuickBEAM.VM.{Execution, Frame, Invocation, Properties, Reference, Value}

  @binary_operations [
    :add,
    :sub,
    :mul,
    :div,
    :mod,
    :pow,
    :lt,
    :lte,
    :gt,
    :gte,
    :eq,
    :neq,
    :strict_eq,
    :strict_neq,
    :and,
    :or,
    :xor,
    :shl,
    :sar,
    :shr
  ]

  @unary_operations [
    :neg,
    :plus,
    :not,
    :lnot,
    :inc,
    :dec,
    :is_undefined_or_null,
    :is_undefined,
    :is_null
  ]

  @opcodes @binary_operations ++
             @unary_operations ++
             [
               :post_inc,
               :post_dec,
               :to_propkey,
               :to_propkey2,
               :to_object,
               :is_function,
               :typeof,
               :typeof_is_function,
               :typeof_is_undefined,
               :in,
               :instanceof
             ]

  @type action ::
          {:next, Frame.t(), Execution.t()}
          | {:throw, term(), Frame.t(), Execution.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported value-semantic opcode."
  @spec execute(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute(name, [], %{stack: [right, left | stack]} = frame, execution)
      when name in @binary_operations do
    next(%{frame | stack: [Value.binary(name, left, right) | stack]}, execution)
  end

  def execute(name, [], %{stack: [value | stack]} = frame, execution)
      when name in @unary_operations do
    next(%{frame | stack: [Value.unary(name, value) | stack]}, execution)
  end

  def execute(:post_inc, [], %{stack: [value | stack]} = frame, execution),
    do: next(%{frame | stack: [Value.unary(:inc, value), value | stack]}, execution)

  def execute(:post_dec, [], %{stack: [value | stack]} = frame, execution),
    do: next(%{frame | stack: [Value.unary(:dec, value), value | stack]}, execution)

  def execute(:to_propkey, [], frame, execution), do: next(frame, execution)

  def execute(:to_propkey2, [], %{stack: [_key, object | _]} = frame, execution)
      when object in [nil, :undefined],
      do: {:throw, {:type_error, :cannot_convert_to_object}, frame, execution}

  def execute(:to_propkey2, [], frame, execution), do: next(frame, execution)

  def execute(:to_object, [], %{stack: [value | _]} = frame, execution)
      when value in [nil, :undefined],
      do: {:throw, {:type_error, :cannot_convert_to_object}, frame, execution}

  def execute(:to_object, [], frame, execution), do: next(frame, execution)

  def execute(:is_function, [], %{stack: [value | stack]} = frame, execution),
    do: next(%{frame | stack: [Invocation.callable?(value, execution) | stack]}, execution)

  def execute(:typeof, [], %{stack: [value | stack]} = frame, execution),
    do: next(%{frame | stack: [Invocation.typeof(value, execution) | stack]}, execution)

  def execute(:typeof_is_function, [], %{stack: [value | stack]} = frame, execution),
    do: next(%{frame | stack: [Invocation.callable?(value, execution) | stack]}, execution)

  def execute(:typeof_is_undefined, [], %{stack: [value | stack]} = frame, execution),
    do: next(%{frame | stack: [Value.unary(:is_undefined, value) | stack]}, execution)

  def execute(:in, [], %{stack: [object, key | stack]} = frame, execution),
    do:
      next(
        %{frame | stack: [Properties.has_property?(object, key, execution) | stack]},
        execution
      )

  def execute(
        :instanceof,
        [],
        %{stack: [constructor, object | stack]} = frame,
        execution
      ) do
    with "function" <- Invocation.typeof(constructor, execution),
         {:ok, %Reference{} = prototype} <-
           Invocation.instanceof_prototype(constructor, execution) do
      result =
        is_struct(object, Reference) and
          Properties.prototype_chain_contains?(object, prototype, execution)

      next(%{frame | stack: [result | stack]}, execution)
    else
      _invalid -> {:throw, {:type_error, :invalid_instanceof_target}, frame, execution}
    end
  end

  defp next(frame, execution), do: {:next, frame, execution}
end
