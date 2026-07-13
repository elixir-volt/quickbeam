defmodule QuickBEAM.VM.Invocation do
  @moduledoc """
  Classifies every JavaScript invocation through one canonical call boundary.

  The module resolves references, bound functions, Promise methods and
  resolvers, built-ins, constructors, and ordinary bytecode functions into
  explicit actions. `QuickBEAM.VM.Interpreter` executes those actions because it
  owns frame scheduling, exception unwinding, and resumable native boundaries.
  """

  alias QuickBEAM.VM.{
    Builtin,
    Builtins,
    ConstructorBoundary,
    Execution,
    Frame,
    Function,
    Promise,
    Properties,
    Reference,
    Value
  }

  alias QuickBEAM.VM.Builtin.{Action, Call}

  @builtin_tags [:builtin, :declared_builtin, :primitive_method]

  @type action ::
          {:dispatch, term(), [term()], term(), term(), Execution.t(), boolean()}
          | {:enter, Function.t(), term(), tuple(), [term()], term(), term(), Execution.t(),
             boolean()}
          | {:complete, term(), term(), Execution.t(), boolean()}
          | {:error, term(), term(), Execution.t()}
          | {:host_call, [term()], term(), Execution.t(), boolean()}
          | {:object_assign, Reference.t(), [term()], term(), Execution.t(), boolean()}
          | {:array_iteration, String.t(), term(), [term()], term(), Execution.t(), boolean()}
          | {:promise_iterate, atom(), term(), term(), Execution.t(), boolean()}
          | {:set_iterate, Reference.t(), term(), term(), Execution.t(), boolean()}
          | {:iterator_value, term(), QuickBEAM.VM.IteratorBoundary.t(), Execution.t()}

  @doc "Plans one invocation without executing interpreter frames."
  @spec plan(term(), [term()], term(), term(), Execution.t(), boolean()) :: action()
  def plan(callable, arguments, this, caller, execution, tail? \\ false)

  def plan({:host_function, :beam_call}, arguments, _this, caller, execution, tail?),
    do: {:host_call, arguments, caller, execution, tail?}

  def plan(
        {:declared_builtin, _module, _handler} = callable,
        arguments,
        this,
        caller,
        execution,
        tail?
      ) do
    call = %Call{
      arguments: arguments,
      this: this,
      caller: caller,
      tail?: tail?,
      execution: execution
    }

    case Builtin.invoke(callable, call) do
      {:ok, value, execution} -> {:complete, value, caller, execution, tail?}
      {:error, reason, execution} -> {:error, {:type_error, reason}, caller, execution}
      %Action{value: action} -> action
    end
  end

  def plan({:promise_resolver, promise, kind}, arguments, _this, caller, execution, tail?) do
    value = Enum.at(arguments, 0, :undefined)
    result = if kind in [:resolve, :resolve_assimilated], do: {:ok, value}, else: {:error, value}

    execution =
      if kind in [:resolve_assimilated, :reject_assimilated],
        do: Promise.settle_assimilated(execution, promise, result),
        else: Promise.settle(execution, promise, result)

    {:complete, :undefined, caller, execution, tail?}
  end

  def plan(
        {:bound_function, target, _bound_this, bound_arguments},
        arguments,
        this,
        %ConstructorBoundary{} = caller,
        execution,
        tail?
      ),
      do: {:dispatch, target, bound_arguments ++ arguments, this, caller, execution, tail?}

  def plan(
        {:bound_function, target, bound_this, bound_arguments},
        arguments,
        _this,
        caller,
        execution,
        tail?
      ),
      do: {:dispatch, target, bound_arguments ++ arguments, bound_this, caller, execution, tail?}

  def plan(%Reference{} = reference, arguments, this, caller, execution, tail?) do
    case Builtins.callable(execution, reference) do
      nil ->
        {:error, {:not_callable, reference}, caller, execution}

      callable when elem(callable, 0) in @builtin_tags ->
        {:dispatch, callable, arguments, this, caller, execution, tail?}

      callable ->
        enter_action(callable, arguments, this, caller, execution, tail?, reference)
    end
  end

  def plan(
        {:primitive_method, :array, method},
        arguments,
        receiver,
        caller,
        execution,
        tail?
      )
      when method in ["filter", "forEach", "map", "reduce", "some"],
      do: {:array_iteration, method, receiver, arguments, caller, execution, tail?}

  def plan(callable, arguments, this, caller, execution, tail?)
      when is_tuple(callable) and elem(callable, 0) in @builtin_tags do
    case Builtins.call(callable, this, arguments, execution) do
      {:ok, value, execution} -> {:complete, value, caller, execution, tail?}
      {:error, reason, execution} -> {:error, {:type_error, reason}, caller, execution}
    end
  end

  def plan(callable, arguments, this, caller, execution, tail?),
    do: enter_action(callable, arguments, this, caller, execution, tail?, nil)

  @doc "Returns whether a value can be used as a JavaScript constructor."
  @spec constructable?(term(), Execution.t()) :: boolean()
  def constructable?(%Reference{} = constructor, execution) do
    case QuickBEAM.VM.Heap.fetch_object(execution, constructor) do
      {:ok, %{internal: :class_constructor}} ->
        true

      _other ->
        case Builtins.callable(execution, constructor) do
          nil -> false
          callable -> constructable?(callable, execution)
        end
    end
  end

  def constructable?(%Function{has_prototype: has_prototype}, _execution), do: has_prototype

  def constructable?({:closure, %Function{has_prototype: has_prototype}, _refs}, _execution),
    do: has_prototype

  def constructable?({:bound_function, target, _this, _arguments}, execution),
    do: constructable?(target, execution)

  def constructable?({:declared_builtin, _module, _handler} = callable, _execution),
    do: Builtin.constructable?(callable)

  def constructable?(_constructor, _execution), do: false

  @doc "Returns the object prototype used for a constructor allocation."
  @spec constructor_prototype(term(), Execution.t()) :: Reference.t() | nil
  def constructor_prototype({:bound_function, target, _this, _arguments}, execution),
    do: constructor_prototype(target, execution)

  def constructor_prototype(constructor, execution) do
    case Properties.get(constructor, "prototype", execution) do
      {:ok, %Reference{} = prototype} -> prototype
      _other -> nil
    end
  end

  @doc "Returns the prototype used by the ordinary `instanceof` algorithm."
  @spec instanceof_prototype(term(), Execution.t()) :: Properties.get_result()
  def instanceof_prototype({:bound_function, target, _this, _arguments}, execution),
    do: instanceof_prototype(target, execution)

  def instanceof_prototype(constructor, execution),
    do: Properties.get(constructor, "prototype", execution)

  @doc "Returns whether a VM value is callable by JavaScript."
  @spec callable?(term(), Execution.t()) :: boolean()
  def callable?(value, execution), do: typeof(value, execution) == "function"

  @doc "Returns the JavaScript `typeof` classification for a VM value."
  @spec typeof(term(), Execution.t()) :: String.t()
  def typeof(%Reference{} = reference, execution) do
    if Builtins.callable(execution, reference), do: "function", else: "object"
  end

  def typeof(value, _execution)
      when is_tuple(value) and
             elem(value, 0) in [
               :builtin,
               :declared_builtin,
               :bound_function,
               :host_function,
               :primitive_method,
               :promise_resolver
             ],
      do: "function"

  def typeof(value, _execution), do: Value.typeof(value)

  @doc "Builds a fresh explicit frame for an ordinary bytecode function call."
  @spec new_frame(Function.t(), term(), [term()], term(), tuple()) :: Frame.t()
  def new_frame(function, callable, arguments, this, closure_refs) do
    local_count = max(function.arg_count + function.var_count, 1)
    actual_arg_count = length(arguments)
    missing_arguments = max(function.arg_count - actual_arg_count, 0)
    arguments = arguments ++ List.duplicate(:undefined, missing_arguments)

    %Frame{
      function: function,
      callable: callable,
      closure_refs: closure_refs,
      locals: :erlang.make_tuple(local_count, :undefined),
      args: List.to_tuple(arguments),
      actual_arg_count: actual_arg_count,
      this: this
    }
  end

  defp enter_action(callable, arguments, this, caller, execution, tail?, frame_callable) do
    case callable_parts(callable) do
      {:ok, function, closure_refs} ->
        {:enter, function, frame_callable || callable, closure_refs, arguments, this, caller,
         execution, tail?}

      {:error, reason} ->
        {:error, reason, caller, execution}
    end
  end

  defp callable_parts(%Function{} = function), do: {:ok, function, {}}

  defp callable_parts({:closure, %Function{} = function, closure_refs}),
    do: {:ok, function, closure_refs}

  defp callable_parts(value), do: {:error, {:not_callable, value}}
end
