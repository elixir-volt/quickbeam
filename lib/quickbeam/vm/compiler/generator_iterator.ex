defmodule QuickBEAM.VM.Compiler.GeneratorIterator do
  @moduledoc """
  Iterator protocol for compiled generator functions.

  Compiled generators throw `{:generator_yield, value, continuation}` to
  suspend. The continuation is a `fun(arg)` that resumes the generator
  body from the yield point with `arg` as the yield return value.
  """

  require QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.InternalMethods
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.IteratorResult
  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.Promise, as: Promise

  @generator_ref_key "__generator_ref__"

  @doc "Builds the runtime value represented by this module."
  def build(gen_ref, generator_fun \\ nil) do
    QuickBEAM.VM.Builtin.object extends: generator_object_prototype(generator_fun) do
      prop(@generator_ref_key, gen_ref)

      method "next", constructable: false do
        do_next(gen_ref, argument_or_undefined(args))
      end

      method "return", constructable: false do
        do_return(gen_ref, argument_or_undefined(args))
      end

      method "throw", constructable: false do
        do_throw(gen_ref, argument_or_undefined(args))
      end

      symbol :iterator do
        method constructable: false do
          this
        end
      end
    end
  end

  @doc "Builds async data for iterator protocol for compiled generator functions."
  def build_async(gen_ref, generator_fun \\ nil) do
    QuickBEAM.VM.Builtin.object extends: generator_object_prototype(generator_fun) do
      method "next", constructable: false do
        Promise.resolved(do_next(gen_ref, argument_or_undefined(args)))
      end

      method "return", constructable: false do
        Promise.resolved(do_return(gen_ref, argument_or_undefined(args)))
      end

      symbol :iterator do
        method constructable: false do
          this
        end
      end
    end
  end

  defp generator_object_prototype(generator_fun) do
    case InternalMethods.get(generator_fun, "prototype") do
      {:obj, _} = proto -> proto
      _ -> Runtime.global_class_proto("Iterator")
    end
  end

  defp do_next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, continuation: cont} = state when is_function(cont, 1) ->
        resume(gen_ref, state, cont, arg)

      %{state: :executing} ->
        QuickBEAM.VM.JSThrow.type_error!("Generator is already executing")

      _ ->
        done(:undefined)
    end
  end

  defp do_return(gen_ref, val) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, mode: :yield_star, continuation: cont} = state
      when is_function(cont, 1) ->
        resume(gen_ref, state, cont, RuntimeHelpers.generator_return_resume(val))

      %{state: :suspended, mode: :yield_cleanup, continuation: cont} = state
      when is_function(cont, 1) ->
        resume(gen_ref, state, cont, RuntimeHelpers.generator_return_resume(val))

      %{state: :executing} ->
        QuickBEAM.VM.JSThrow.type_error!("Generator is already executing")

      %{state: :suspended} ->
        Heap.put_obj(gen_ref, %{state: :completed})
        done(val)

      _ ->
        Heap.put_obj(gen_ref, %{state: :completed})
        done(val)
    end
  end

  defp do_throw(gen_ref, val) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, mode: :initial} ->
        Heap.put_obj(gen_ref, %{state: :completed})
        throw({:js_throw, val})

      %{state: :suspended, continuation: _cont} ->
        Heap.put_obj(gen_ref, %{state: :completed})
        throw({:js_throw, val})

      %{state: :executing} ->
        QuickBEAM.VM.JSThrow.type_error!("Generator is already executing")

      _ ->
        Heap.put_obj(gen_ref, %{state: :completed})
        throw({:js_throw, val})
    end
  end

  defp resume(gen_ref, state, cont, arg) do
    Heap.put_obj(gen_ref, Map.put(state, :state, :executing))
    result = cont.(arg)
    Heap.put_obj(gen_ref, %{state: :completed})
    done(result)
  catch
    {:generator_yield, val, next_cont} ->
      Heap.put_obj(gen_ref, %{state: :suspended, continuation: next_cont})
      yield(val)

    {:generator_yield_star, val, next_cont} ->
      Heap.put_obj(gen_ref, %{state: :suspended, continuation: next_cont, mode: :yield_star})
      val

    {:generator_return, val} ->
      Heap.put_obj(gen_ref, %{state: :completed})
      done(val)

    {:js_throw, _} = thrown ->
      Heap.put_obj(gen_ref, %{state: :completed})
      throw(thrown)
  end

  defp argument_or_undefined([value | _]), do: value
  defp argument_or_undefined([]), do: :undefined

  defp yield(val), do: IteratorResult.new(val, false)
  defp done(val), do: IteratorResult.new(val, true)
end
