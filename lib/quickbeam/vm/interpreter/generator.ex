defmodule QuickBEAM.VM.Interpreter.Generator do
  @moduledoc "Generator and async function execution: suspends/resumes frames and wraps results in iterator or Promise objects."

  import QuickBEAM.VM.Builtin, only: [object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.PromiseState, as: Promise

  @doc "Invokes the runtime object represented by this module."
  def invoke(frame, gas, ctx) do
    gen_ref = make_ref()
    suspend(gen_ref, frame, gas, ctx)
    build_iterator(gen_ref, &next/2, &return_value/2)
  end

  @doc "Invokes the runtime object asynchronously."
  def invoke_async(frame, gas, ctx) do
    result = Interpreter.run_frame(frame, [], gas, ctx)
    Promise.resolved(result)
  catch
    {:generator_return, val} -> Promise.resolved(val)
    {:js_throw, val} -> Promise.rejected(val)
  end

  @doc "Invokes an async generator runtime object."
  def invoke_async_generator(frame, gas, ctx) do
    gen_ref = make_ref()
    suspend(gen_ref, frame, gas, ctx)

    build_iterator(gen_ref, &async_next/2, fn _ref, val ->
      Promise.resolved(done_result(val))
    end)
  end

  # ── Sync generator ──

  defp next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended} = s ->
        Heap.put_ctx(s.ctx)
        resume_sync(gen_ref, s, arg)

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
      save_suspended(gen_ref, sp, sf, ss, sg, sc)
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
        prev_ctx = Heap.get_ctx()
        Heap.put_ctx(s.ctx)

        try do
          resume_async(gen_ref, s, arg)
        after
          if prev_ctx, do: Heap.put_ctx(prev_ctx)
        end

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

  defp return_value(gen_ref, val) do
    complete(gen_ref)
    done_result(val)
  end

  defp suspend(gen_ref, frame, gas, ctx) do
    Interpreter.run_frame(frame, [], gas, ctx)
  catch
    {:generator_yield, _val, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc)

    {:generator_yield_star, _val, sp, sf, ss, sg, sc} ->
      save_suspended(gen_ref, sp, sf, ss, sg, sc)
  end

  defp save_suspended(ref, pc, frame, stack, gas, ctx) do
    Heap.put_obj(ref, %{state: :suspended, pc: pc, frame: frame, stack: stack, gas: gas, ctx: ctx})
  end

  defp complete(ref), do: Heap.put_obj(ref, %{state: :completed})

  defp yield_result(val), do: Heap.wrap(%{"value" => val, "done" => false})
  defp done_result(val), do: Heap.wrap(%{"value" => val, "done" => true})

  defp build_iterator(gen_ref, next_impl, return_impl) do
    next_fn =
      {:builtin, "next",
       fn
         [arg | _], _this -> next_impl.(gen_ref, arg)
         [], _this -> next_impl.(gen_ref, :undefined)
       end}

    return_fn =
      {:builtin, "return",
       fn
         [val | _], _this -> return_impl.(gen_ref, val)
         [], _this -> return_impl.(gen_ref, :undefined)
       end}

    object do
      prop("next", next_fn)
      prop("return", return_fn)
    end
  end
end
