defmodule QuickBEAM.VM.Interpreter.Generator do
  @moduledoc "Generator and async function execution: suspends/resumes frames and wraps results in iterator or Promise objects."

  import QuickBEAM.VM.Builtin, only: [object: 2]

  alias QuickBEAM.VM.{Heap, JSThrow, RuntimeState}
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Promise, as: Promise

  @generator_ref_key "__generator_ref__"

  @doc "Invokes the runtime object represented by this module."
  def invoke(frame, gas, ctx, generator_fun \\ nil) do
    gen_ref = make_ref()
    suspend(gen_ref, frame, gas, ctx)
    build_iterator(gen_ref, &next/2, &return_value/2, generator_fun)
  end

  @doc "Invokes the runtime object asynchronously."
  def invoke_async(frame, gas, ctx) do
    result = Interpreter.run_frame(frame, [], gas, ctx)
    Promise.adopt(result)
  catch
    {:generator_return, val} -> Promise.adopt(val)
    {:js_throw, val} -> Promise.rejected(val)
  end

  @doc "Invokes an async generator runtime object."
  def invoke_async_generator(frame, gas, ctx, generator_fun \\ nil) do
    gen_ref = make_ref()
    suspend(gen_ref, frame, gas, ctx)

    build_iterator(
      gen_ref,
      &async_next/2,
      fn _ref, val ->
        Promise.resolved(done_result(val))
      end,
      generator_fun
    )
  end

  # ── Sync generator ──

  defp next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended} = s ->
        RuntimeState.with_context(s.ctx, fn -> resume_sync(gen_ref, s, arg) end)

      _ ->
        done_result(:undefined)
    end
  end

  defp resume_sync(gen_ref, s, arg) do
    result = Interpreter.run_frame(s.pc, s.frame, [false, arg | s.stack], s.gas, s.ctx)
    complete(gen_ref)
    done_result(result)
  catch
    {:generator_yield, val, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc)
      yield_result(val)

    {:generator_yield_star, val, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc, :yield_star)
      val

    {:generator_return, val} ->
      complete(gen_ref)
      done_result(val)

    {:js_throw, _} = thrown ->
      complete(gen_ref)
      throw(thrown)
  end

  # ── Async generator ──

  defp async_next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended} = s ->
        RuntimeState.with_context(s.ctx, fn -> resume_async(gen_ref, s, arg) end)

      _ ->
        Promise.resolved(done_result(:undefined))
    end
  end

  defp resume_async(gen_ref, s, arg) do
    result = Interpreter.run_frame(s.pc, s.frame, [false, arg | s.stack], s.gas, s.ctx)
    complete(gen_ref)
    Promise.resolved(done_result(result))
  catch
    {:generator_yield, val, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc)
      Promise.resolved(yield_result(val))

    {:generator_return, val} ->
      complete(gen_ref)
      Promise.resolved(done_result(val))

    {:js_throw, _} = thrown ->
      complete(gen_ref)
      throw(thrown)
  end

  # ── Shared helpers ──

  def throw_value(gen_ref, val) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, mode: :initial} ->
        complete(gen_ref)
        throw({:js_throw, val})

      %{state: :suspended} = s ->
        RuntimeState.with_context(s.ctx, fn -> resume_throw(gen_ref, s, val) end)

      _ ->
        throw({:js_throw, val})
    end
  end

  defp return_value(gen_ref, val) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, mode: :initial} ->
        complete(gen_ref)
        done_result(val)

      %{state: :suspended} = s ->
        RuntimeState.with_context(s.ctx, fn -> resume_return(gen_ref, s, val) end)

      _ ->
        done_result(val)
    end
  end

  defp resume_throw(gen_ref, _s, val) do
    complete(gen_ref)
    throw({:js_throw, val})
  end

  defp resume_return(gen_ref, s, val) do
    result = Interpreter.run_frame(s.pc, s.frame, [true, val | s.stack], s.gas, s.ctx)
    complete(gen_ref)
    done_result(result)
  catch
    {:generator_yield, yielded, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc)
      yield_result(yielded)

    {:generator_yield_star, yielded, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc, :yield_star)
      yielded

    {:generator_return, returned} ->
      complete(gen_ref)
      done_result(returned)

    {:js_throw, _} = thrown ->
      complete(gen_ref)
      throw(thrown)
  end

  defp suspend(gen_ref, frame, gas, ctx) do
    Interpreter.run_frame(frame, [], gas, ctx)
  catch
    {:generator_yield, _val, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc, :initial)

    {:generator_yield_star, _val, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc, :yield_star)
  end

  defp save_suspended(ref, pc, frame, stack, gas, ctx, mode \\ :yield) do
    Heap.put_obj(ref, %{
      state: :suspended,
      mode: mode,
      pc: pc,
      frame: frame,
      stack: stack,
      gas: gas,
      ctx: ctx
    })
  end

  defp complete(ref), do: Heap.put_obj(ref, %{state: :completed})

  defp yield_result(val), do: Heap.wrap(%{"value" => val, "done" => false})
  defp done_result(val), do: Heap.wrap(%{"value" => val, "done" => true})

  def prototype_object do
    object extends:
             QuickBEAM.VM.Runtime.global_class_proto("Iterator") || Heap.get_object_prototype() do
      method "next", length: 1, constructable: false do
        next(generator_ref!(this), argument_or_undefined(args))
      end

      method "return", length: 1, constructable: false do
        return_value(generator_ref!(this), argument_or_undefined(args))
      end

      method "throw", length: 1, constructable: false do
        throw_value(generator_ref!(this), argument_or_undefined(args))
      end

      symbol :iterator do
        method length: 0, constructable: false do
          this
        end
      end

      symbol :toStringTag do
        data("Generator", writable: false, enumerable: false, configurable: true)
      end
    end
  end

  defp build_iterator(gen_ref, next_impl, return_impl, generator_fun) do
    object extends: generator_object_prototype(generator_fun) do
      prop(@generator_ref_key, gen_ref)

      method "next", constructable: false do
        next_impl.(gen_ref, argument_or_undefined(args))
      end

      method "return", constructable: false do
        return_impl.(gen_ref, argument_or_undefined(args))
      end

      symbol :iterator do
        method constructable: false do
          this
        end
      end
    end
  end

  defp generator_ref!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{@generator_ref_key => gen_ref} -> gen_ref
      _ -> JSThrow.type_error!("Generator method called on incompatible receiver")
    end
  end

  defp generator_ref!(_),
    do: JSThrow.type_error!("Generator method called on incompatible receiver")

  defp argument_or_undefined([value | _]), do: value
  defp argument_or_undefined([]), do: :undefined

  defp generator_object_prototype(generator_fun) do
    case QuickBEAM.VM.ObjectModel.Get.get(generator_fun, "prototype") do
      {:obj, _} = proto -> proto
      _ -> QuickBEAM.VM.Runtime.global_class_proto("Iterator")
    end
  end
end
