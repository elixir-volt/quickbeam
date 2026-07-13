defmodule QuickBEAM.VM.Invocation do
  @moduledoc """
  Classifies every JavaScript invocation through one canonical call boundary.

  The module resolves references, bound functions, Promise methods and
  resolvers, built-ins, constructors, and ordinary bytecode functions into
  explicit actions. `QuickBEAM.VM.Interpreter` executes those actions because it
  owns frame scheduling, exception unwinding, and resumable native boundaries.
  """

  alias QuickBEAM.VM.{
    Builtins,
    ConstructorBoundary,
    Execution,
    Frame,
    Function,
    Promise,
    PromiseExecutorBoundary,
    PromiseReference,
    Properties,
    Reference,
    Value
  }

  @builtin_tags [:builtin, :builtin_method, :primitive_method]
  @error_constructors ~w(Error EvalError RangeError ReferenceError SyntaxError TypeError URIError)

  @type action ::
          {:dispatch, term(), [term()], term(), term(), Execution.t(), boolean()}
          | {:enter, Function.t(), term(), tuple(), [term()], term(), term(), Execution.t(),
             boolean()}
          | {:complete, term(), term(), Execution.t(), boolean()}
          | {:error, term(), term(), Execution.t()}
          | {:host_call, [term()], term(), Execution.t(), boolean()}
          | {:object_assign, Reference.t(), [term()], term(), Execution.t(), boolean()}
          | {:array_iteration, String.t(), term(), [term()], term(), Execution.t(), boolean()}

  @doc "Plans one invocation without executing interpreter frames."
  @spec plan(term(), [term()], term(), term(), Execution.t(), boolean()) :: action()
  def plan(callable, arguments, this, caller, execution, tail? \\ false)

  def plan({:host_function, :beam_call}, arguments, _this, caller, execution, tail?),
    do: {:host_call, arguments, caller, execution, tail?}

  def plan({:builtin, "Promise"}, [executor | _], _this, caller, execution, tail?) do
    {promise, execution} = Promise.new(execution)

    boundary = %PromiseExecutorBoundary{
      promise: promise,
      caller: caller,
      depth: execution.depth,
      tail?: tail?
    }

    if typeof(executor, execution) == "function" do
      resolve = {:promise_resolver, promise, :resolve}
      reject = {:promise_resolver, promise, :reject}
      {:dispatch, executor, [resolve, reject], :undefined, boundary, execution, false}
    else
      execution =
        Promise.settle(
          execution,
          promise,
          {:error, {:type_error, :promise_executor_not_callable}}
        )

      {:complete, promise, caller, execution, tail?}
    end
  end

  def plan({:builtin, "Promise"}, _arguments, _this, caller, execution, tail?) do
    {promise, execution} = Promise.new(execution)

    execution =
      Promise.settle(execution, promise, {:error, {:type_error, :missing_promise_executor}})

    {:complete, promise, caller, execution, tail?}
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

  def plan(
        {:function_method, "bind"},
        [bound_this | bound_arguments],
        target,
        caller,
        execution,
        false
      ),
      do:
        {:complete, {:bound_function, target, bound_this, bound_arguments}, caller, execution,
         false}

  def plan({:function_method, "call"}, arguments, target, caller, execution, tail?) do
    {this, arguments} =
      case arguments do
        [this | rest] -> {this, rest}
        [] -> {:undefined, []}
      end

    {:dispatch, target, arguments, this, caller, execution, tail?}
  end

  def plan(
        {:promise_method, "then"},
        arguments,
        %PromiseReference{} = promise,
        caller,
        execution,
        tail?
      ) do
    on_fulfilled = Enum.at(arguments, 0, :undefined)
    on_rejected = Enum.at(arguments, 1, :undefined)
    {result, execution} = Promise.react(execution, promise, on_fulfilled, on_rejected)
    {:complete, result, caller, execution, tail?}
  end

  def plan(
        {:promise_method, "catch"},
        arguments,
        %PromiseReference{} = promise,
        caller,
        execution,
        tail?
      ) do
    on_rejected = Enum.at(arguments, 0, :undefined)
    {result, execution} = Promise.react(execution, promise, :undefined, on_rejected)
    {:complete, result, caller, execution, tail?}
  end

  def plan(
        {:promise_method, "finally"},
        arguments,
        %PromiseReference{} = promise,
        caller,
        execution,
        tail?
      ) do
    callback = Enum.at(arguments, 0, :undefined)
    {result, execution} = Promise.finally(execution, promise, callback)
    {:complete, result, caller, execution, tail?}
  end

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
        {:builtin_method, "Object", "assign"},
        [%Reference{} = target | sources],
        _this,
        caller,
        execution,
        tail?
      ),
      do: {:object_assign, target, sources, caller, execution, tail?}

  def plan({:builtin_method, "Object", "assign"}, _arguments, _this, caller, execution, _tail?),
    do: {:error, {:type_error, :not_an_object}, caller, execution}

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
    case Builtins.callable(execution, constructor) do
      nil -> false
      callable -> constructable?(callable, execution)
    end
  end

  def constructable?(%Function{has_prototype: has_prototype}, _execution), do: has_prototype

  def constructable?({:closure, %Function{has_prototype: has_prototype}, _refs}, _execution),
    do: has_prototype

  def constructable?({:bound_function, target, _this, _arguments}, execution),
    do: constructable?(target, execution)

  def constructable?({:builtin, name}, _execution),
    do:
      name in (["Array", "Boolean", "Number", "Object", "Promise", "Set", "String"] ++
                 @error_constructors)

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
               :builtin_method,
               :bound_function,
               :function_method,
               :host_function,
               :primitive_method,
               :promise_method,
               :promise_resolver
             ],
      do: "function"

  def typeof(value, _execution), do: Value.typeof(value)

  @doc "Builds a fresh explicit frame for an ordinary bytecode function call."
  @spec new_frame(Function.t(), term(), [term()], term(), tuple()) :: Frame.t()
  def new_frame(function, callable, arguments, this, closure_refs) do
    local_count = max(function.arg_count + function.var_count, 1)

    %Frame{
      function: function,
      callable: callable,
      closure_refs: closure_refs,
      locals: :erlang.make_tuple(local_count, :undefined),
      args: List.to_tuple(arguments),
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
