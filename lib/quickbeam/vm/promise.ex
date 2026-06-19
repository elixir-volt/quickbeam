defmodule QuickBEAM.VM.Promise do
  @moduledoc """
  Promise object state, reactions, and Promise-resolution adoption.

  Spec relation:
  - ECMA-262 §27.2 Promise Objects
  - ECMA-262 §9.5 Jobs and Host Operations to Enqueue Jobs, via `QuickBEAM.VM.JobQueue`
  """

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Builtin, only: [arg: 3]

  alias QuickBEAM.VM.{Builtin, Heap, JobQueue, Runtime}
  alias QuickBEAM.VM.Execution.PrimitivePrototypeState
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.{Class, Get, PropertyDescriptor}
  alias QuickBEAM.VM.Semantics.PropertyAccess

  @doc "Creates or returns a resolved Promise state value."
  def resolved(val), do: make_promise(:resolved, val)
  @doc "Creates or returns a rejected Promise state value."
  def rejected(val), do: make_promise(:rejected, val)

  @doc "Creates a pending Promise state value."
  def pending, do: make_promise(:pending, nil)

  @doc "Returns promise values as-is, otherwise wraps a value in a resolved Promise."
  def adopt({:obj, ref} = promise) do
    case Heap.get_obj(ref, %{}) do
      %{promise_state() => state} when state in [:resolved, :rejected, :pending] ->
        promise

      _ ->
        adopt_thenable(promise)
    end
  end

  def adopt(val), do: resolved(val)

  @doc "Implements Promise.prototype.then state transitions."
  def promise_then(args, {:obj, promise_ref}) do
    case Heap.get_obj(promise_ref, %{}) do
      %{promise_state() => state} when state in [:resolved, :rejected, :pending] ->
        then_impl(args, promise_ref)

      _ ->
        throw(
          {:js_throw,
           Heap.make_error("Promise.prototype.then called on incompatible receiver", "TypeError")}
        )
    end
  end

  def promise_then(_args, _this),
    do:
      throw(
        {:js_throw,
         Heap.make_error("Promise.prototype.then called on incompatible receiver", "TypeError")}
      )

  @doc "Implements Promise.prototype.catch state transitions."
  def promise_catch(args, this) do
    then = primitive_then_override(this) || PropertyAccess.get_property(this, "then")

    unless Builtin.callable?(then) do
      throw({:js_throw, Heap.make_error("not a function", "TypeError")})
    end

    Invocation.invoke_with_receiver(then, [:undefined, arg(args, 0, nil)], this)
  end

  defp primitive_then_override(value) when is_boolean(value),
    do: PrimitivePrototypeState.then_override("Boolean")

  defp primitive_then_override(value) when is_number(value),
    do: PrimitivePrototypeState.then_override("Number")

  defp primitive_then_override(value) when is_binary(value),
    do: PrimitivePrototypeState.then_override("String")

  defp primitive_then_override({:symbol, _, _}),
    do: PrimitivePrototypeState.then_override("Symbol")

  defp primitive_then_override({:symbol, _}), do: PrimitivePrototypeState.then_override("Symbol")

  defp primitive_then_override(_value), do: nil

  @doc "Implements Promise.prototype.finally state transitions."
  def promise_finally([callback | _], this), do: invoke_finally_then(this, callback)
  def promise_finally(_args, this), do: invoke_finally_then(this, nil)

  @doc "Resolves a Promise state with normal Promise-resolution adoption."
  def resolve_adopt(ref, {:obj, obj_ref} = obj) do
    case Heap.get_obj(obj_ref, %{}) do
      %{promise_state() => state} when state in [:resolved, :rejected, :pending] ->
        resolve_or_chain(ref, obj)

      _ ->
        resolve_or_chain(ref, adopt_thenable(obj))
    end
  end

  def resolve_adopt(ref, val), do: resolve_or_chain(ref, val)

  @doc "Resolves a Promise state and drains queued reactions."
  def resolve(ref, state, val) do
    existing = Heap.get_obj(ref, %{})
    updated = promise_obj(state, val, ref)

    updated =
      case existing do
        %{"__proto__" => proto} -> Map.put(updated, "__proto__", proto)
        _ -> updated
      end

    Heap.put_obj(ref, updated)

    for {on_fulfilled, on_rejected, child_ref} <- pop_waiters(ref) do
      handler =
        case state do
          :resolved -> on_fulfilled
          :rejected -> on_rejected
        end

      handler = if callable?(handler), do: handler, else: fn v -> v end
      JobQueue.enqueue_promise_reaction(child_ref, handler, val)
    end
  end

  @doc "Runs queued microtasks until the queue is empty."
  def drain_microtasks, do: JobQueue.drain_microtasks()

  @doc "Settles a reaction child promise from a queued Promise job result."
  def resolve_reaction_result({:rejected, err}, child_ref), do: resolve(child_ref, :rejected, err)
  def resolve_reaction_result(result_val, child_ref), do: resolve_or_chain(child_ref, result_val)

  # ── Internal ──

  defp invoke_finally_then(this, callback) do
    then = Get.get(this, "then")

    unless Builtin.callable?(then) do
      throw({:js_throw, Heap.make_error("not a function", "TypeError")})
    end

    handlers =
      if Builtin.callable?(callback) do
        [
          finalizer_function(fn value -> finalize(callback, :resolved, value) end),
          finalizer_function(fn reason -> finalize(callback, :rejected, reason) end)
        ]
      else
        [callback, callback]
      end

    Invocation.invoke_with_receiver(then, handlers, this)
  end

  defp finalizer_function(callback) do
    fun = {:builtin, "resolve", fn args, _ -> callback.(arg(args, 0, :undefined)) end}
    Builtin.put_function_metadata(fun, "", 1)
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  defp make_promise(state, val) do
    ref = make_ref()
    Heap.put_obj(ref, promise_obj(state, val, ref))
    {:obj, ref}
  end

  defp adopt_thenable(obj) do
    case then_member(obj) do
      {:ok, then_fn} ->
        if Builtin.callable?(then_fn) do
          adopt_with_then(obj, then_fn)
        else
          resolved(obj)
        end

      {:error, reason} ->
        rejected(reason)
    end
  end

  defp then_member(obj) do
    try do
      {:ok, Get.get(obj, "then")}
    catch
      {:js_throw, reason} -> {:error, reason}
    end
  end

  defp adopt_with_then(obj, then_fn) do
    ref = make_ref()
    Heap.put_obj(ref, promise_obj(:pending, nil, ref))

    resolve_fn = finalizer_function(fn value -> settle_adopt_once(ref, value) end)
    reject_fn = finalizer_function(fn reason -> settle_reject_once(ref, reason) end)

    try do
      Invocation.invoke_method_runtime(then_fn, obj, [resolve_fn, reject_fn])
    catch
      {:js_throw, reason} -> settle_reject_once(ref, reason)
    end

    {:obj, ref}
  end

  defp settle_adopt_once(ref, value) do
    unless settled?(ref), do: resolve_adopt(ref, value)
    :undefined
  end

  defp settle_reject_once(ref, reason) do
    unless settled?(ref), do: resolve(ref, :rejected, reason)
    :undefined
  end

  defp settled?(ref) do
    case Heap.get_obj(ref, %{}) do
      %{promise_state() => state} when state in [:resolved, :rejected] -> true
      _ -> false
    end
  end

  defp promise_obj(state, val, _ref) do
    base = %{
      promise_state() => state,
      promise_value() => val
    }

    case promise_proto() do
      nil -> base
      proto -> Map.put(base, "__proto__", proto)
    end
  end

  defp pending_child do
    ref = make_ref()
    Heap.put_obj(ref, promise_obj(:pending, nil, ref))
    ref
  end

  defp then_impl(args, promise_ref) do
    on_fulfilled = arg(args, 0, nil)
    on_rejected = arg(args, 1, nil)
    {child_promise, child_ref} = new_reaction_promise(promise_ref)

    case Heap.get_obj(promise_ref, %{}) do
      %{promise_state() => state, promise_value() => val} when state in [:resolved, :rejected] ->
        handler = if state == :resolved, do: on_fulfilled, else: on_rejected

        if callable?(handler) do
          JobQueue.enqueue_promise_reaction(child_ref, handler, val)
          child_promise
        else
          resolve(child_ref, state, val)
          child_promise
        end

      %{promise_state() => :pending} ->
        waiters = Heap.get_promise_waiters(promise_ref)

        Heap.put_promise_waiters(promise_ref, [
          {on_fulfilled, on_rejected, child_ref} | waiters
        ])

        child_promise

      _ ->
        resolved(:undefined)
    end
  end

  defp new_reaction_promise(promise_ref) do
    case promise_species_constructor(promise_ref) do
      :default ->
        child_ref = pending_child()
        {{:obj, child_ref}, child_ref}

      constructor ->
        promise = construct_capability_promise(constructor)

        case promise do
          {:obj, child_ref} ->
            {promise, child_ref}

          _ ->
            throw(
              {:js_throw,
               Heap.make_error("Promise capability did not return an object", "TypeError")}
            )
        end
    end
  end

  defp promise_species_constructor(promise_ref) do
    constructor = Get.get({:obj, promise_ref}, "constructor")

    cond do
      constructor == :undefined ->
        :default

      constructor == nil or not constructor_like?(constructor) ->
        throw({:js_throw, Heap.make_error("Promise constructor is not an object", "TypeError")})

      true ->
        species = Get.get(constructor, {:symbol, "Symbol.species"})

        cond do
          species in [:undefined, nil] and promise_subclass_constructor?(constructor) ->
            constructor

          species in [:undefined, nil] ->
            :default

          true ->
            species
        end
    end
  end

  defp constructor_like?({:obj, _}), do: true
  defp constructor_like?(value), do: Builtin.callable?(value)

  defp promise_subclass_constructor?(constructor) do
    case Class.get_super(constructor) do
      {:builtin, "Promise", _} -> true
      _ -> false
    end
  end

  defp construct_capability_promise(constructor) do
    captured = make_ref()
    Heap.put_obj(captured, %{"resolve" => :undefined, "reject" => :undefined})

    executor =
      capability_executor(fn args ->
        current = Heap.get_obj(captured, %{})

        if current["resolve"] != :undefined or current["reject"] != :undefined do
          throw(
            {:js_throw,
             Heap.make_error("Promise capability executor already called", "TypeError")}
          )
        end

        Heap.put_obj(captured, %{
          "resolve" => arg(args, 0, :undefined),
          "reject" => arg(args, 1, :undefined)
        })

        :undefined
      end)

    promise = Invocation.construct_runtime(constructor, constructor, [executor])

    case Heap.get_obj(captured, %{}) do
      %{"resolve" => resolve, "reject" => reject}
      when resolve != :undefined and reject != :undefined ->
        unless Builtin.callable?(resolve) and Builtin.callable?(reject) do
          throw(
            {:js_throw,
             Heap.make_error(
               "Promise capability executor arguments must be callable",
               "TypeError"
             )}
          )
        end

        promise

      _ ->
        throw(
          {:js_throw,
           Heap.make_error("Promise constructor did not provide resolving functions", "TypeError")}
        )
    end
  end

  defp capability_executor(callback) when is_function(callback, 1) do
    fun = {:builtin, "__promiseCapabilityExecutor", fn args, _ -> callback.(args) end}
    Builtin.put_function_metadata(fun, "", 2)
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  defp finalize(callback, state, value) do
    result =
      if callable?(callback) do
        try do
          Invocation.invoke_callback_or_throw(callback, [])
        catch
          {:js_throw, err} -> {:rejected, err}
        end
      else
        :undefined
      end

    case result do
      {:rejected, reason} ->
        {:rejected, reason}

      {:obj, ref} = promise ->
        case Heap.get_obj(ref, %{}) do
          %{promise_state() => :rejected, promise_value() => reason} -> {:rejected, reason}
          %{promise_state() => :pending} -> promise
          _ -> finally_original(state, value)
        end

      _ ->
        finally_original(state, value)
    end
  end

  defp finally_original(:resolved, value), do: value
  defp finally_original(:rejected, reason), do: {:rejected, reason}

  defp promise_proto, do: Runtime.global_class_proto("Promise")

  defp resolve_or_chain(child_ref, {:obj, r}) do
    case Heap.get_obj(r, %{}) do
      %{promise_state() => :resolved, promise_value() => v} ->
        resolve(child_ref, :resolved, v)

      %{promise_state() => :rejected, promise_value() => v} ->
        resolve(child_ref, :rejected, v)

      %{promise_state() => :pending} ->
        waiters = Heap.get_promise_waiters(r)

        Heap.put_promise_waiters(r, [
          {fn v -> resolve(child_ref, :resolved, v) end, nil, child_ref} | waiters
        ])

      _ ->
        resolve(child_ref, :resolved, {:obj, r})
    end
  end

  defp resolve_or_chain(child_ref, val), do: resolve(child_ref, :resolved, val)

  defp callable?(nil), do: false
  defp callable?(:undefined), do: false
  defp callable?(_), do: true

  defp pop_waiters(ref) do
    waiters = Heap.get_promise_waiters(ref)
    Heap.delete_promise_waiters(ref)
    waiters
  end
end
