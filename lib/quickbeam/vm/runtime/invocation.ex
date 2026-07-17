defmodule QuickBEAM.VM.Runtime.Invocation do
  @moduledoc """
  Classifies every JavaScript invocation through one canonical call boundary.

  The module resolves references, bound functions, Promise methods and
  resolvers, built-ins, constructors, and ordinary bytecode functions into
  explicit actions. `QuickBEAM.VM.Interpreter` executes those actions because it
  owns frame scheduling, exception unwinding, and resumable native boundaries.
  """

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Runtime, as: BuiltinRuntime
  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Callable
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference

  alias QuickBEAM.VM.Builtin.Action
  alias QuickBEAM.VM.Builtin.Call

  @builtin_tags [:builtin, :declared_builtin, :primitive_method]

  @type action ::
          {:dispatch, term(), [term()], term(), term(), State.t(), boolean()}
          | {:enter, Function.t(), term(), tuple(), [term()], term(), term(), State.t(),
             boolean()}
          | {:complete, term(), term(), State.t(), boolean()}
          | {:error, term(), term(), State.t()}
          | {:host_call, [term()], term(), State.t(), boolean()}
          | {:object_assign, Reference.t(), [term()], term(), State.t(), boolean()}
          | {:array_iteration, String.t(), term(), [term()], term(), State.t(), boolean()}
          | {:promise_iterate, atom(), term(), term(), State.t(), boolean()}
          | {:set_iterate, Reference.t(), term(), term(), State.t(), boolean()}
          | {:iterator_value, term(), QuickBEAM.VM.Runtime.Boundary.Iterator.t(), State.t()}

  @doc "Plans one invocation without executing interpreter frames."
  @spec plan(term(), [term()], term(), term(), State.t(), boolean()) :: action()
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
        %Boundary.Constructor{} = caller,
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
    case BuiltinRuntime.callable(execution, reference) do
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
    case BuiltinRuntime.call(callable, this, arguments, execution) do
      {:ok, value, execution} -> {:complete, value, caller, execution, tail?}
      {:error, reason, execution} -> {:error, {:type_error, reason}, caller, execution}
    end
  end

  def plan(callable, arguments, this, caller, execution, tail?),
    do: enter_action(callable, arguments, this, caller, execution, tail?, nil)

  @doc "Returns whether a value can be used as a JavaScript constructor."
  @spec constructable?(term(), State.t()) :: boolean()
  def constructable?(%Reference{} = constructor, execution) do
    case QuickBEAM.VM.Runtime.Heap.fetch_object(execution, constructor) do
      {:ok, %{internal: :class_constructor}} ->
        true

      _other ->
        case BuiltinRuntime.callable(execution, constructor) do
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
  @spec constructor_prototype(term(), State.t()) :: Reference.t() | nil
  def constructor_prototype({:bound_function, target, _this, _arguments}, execution),
    do: constructor_prototype(target, execution)

  def constructor_prototype(constructor, execution) do
    case Property.get(constructor, "prototype", execution) do
      {:ok, %Reference{} = prototype} -> prototype
      _other -> nil
    end
  end

  @doc "Returns the prototype used by the ordinary `instanceof` algorithm."
  @spec instanceof_prototype(term(), State.t()) :: Property.get_result()
  def instanceof_prototype({:bound_function, target, _this, _arguments}, execution),
    do: instanceof_prototype(target, execution)

  def instanceof_prototype(constructor, execution),
    do: Property.get(constructor, "prototype", execution)

  @doc "Returns whether a VM value is callable by JavaScript."
  @spec callable?(term(), State.t()) :: boolean()
  defdelegate callable?(value, execution), to: Callable

  @doc "Returns the JavaScript `typeof` classification for a VM value."
  @spec typeof(term(), State.t()) :: String.t()
  defdelegate typeof(value, execution), to: Callable

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
