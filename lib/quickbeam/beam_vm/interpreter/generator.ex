defmodule QuickBEAM.BeamVM.Interpreter.Generator do
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter.Promise

  def invoke_generator(frame, gas, ctx) do
    gen_ref = make_ref()

    try do
      QuickBEAM.BeamVM.Interpreter.run_frame(frame, [], gas, ctx)
    catch
      {:generator_yield_star, _val, suspended_frame, suspended_stack, suspended_gas,
       suspended_ctx} ->
        state = %{
          state: :suspended,
          frame: suspended_frame,
          stack: suspended_stack,
          gas: suspended_gas,
          ctx: suspended_ctx
        }

        Heap.put_obj(gen_ref, state)

      {:generator_yield, _val, suspended_frame, suspended_stack, suspended_gas, suspended_ctx} ->
        state = %{
          state: :suspended,
          frame: suspended_frame,
          stack: suspended_stack,
          gas: suspended_gas,
          ctx: suspended_ctx
        }

        Heap.put_obj(gen_ref, state)
    end

    next_fn =
      {:builtin, "next",
       fn
         [arg | _], _this -> generator_next(gen_ref, arg)
         [], _this -> generator_next(gen_ref, :undefined)
       end}

    return_fn =
      {:builtin, "return",
       fn
         [val | _], _this -> generator_return(gen_ref, val)
         [], _this -> generator_return(gen_ref, :undefined)
       end}

    obj_ref = make_ref()

    Heap.put_obj(obj_ref, %{
      "next" => next_fn,
      "return" => return_fn
    })

    {:obj, obj_ref}
  end

  def invoke_async_generator(frame, gas, ctx) do
    gen_ref = make_ref()

    try do
      QuickBEAM.BeamVM.Interpreter.run_frame(frame, [], gas, ctx)
    catch
      {:generator_yield, _val, sf, ss, sg, sc} ->
        Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
    end

    next_fn =
      {:builtin, "next",
       fn
         [arg | _], _this -> async_generator_next(gen_ref, arg)
         [], _this -> async_generator_next(gen_ref, :undefined)
       end}

    return_fn =
      {:builtin, "return",
       fn
         [val | _], _this -> Promise.make_resolved_promise(done_result(val))
         [], _this -> Promise.make_resolved_promise(done_result(:undefined))
       end}

    obj_ref = make_ref()
    Heap.put_obj(obj_ref, %{"next" => next_fn, "return" => return_fn})
    {:obj, obj_ref}
  end

  defp async_generator_next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, frame: frame, stack: stack, gas: gas, ctx: ctx} ->
        prev_ctx = Heap.get_ctx()
        Heap.put_ctx(ctx)

        try do
          result = QuickBEAM.BeamVM.Interpreter.run_frame(frame, [false, arg | stack], gas, ctx)
          Heap.put_obj(gen_ref, %{state: :completed})
          Promise.make_resolved_promise(done_result(result))
        catch
          {:generator_yield, val, sf, ss, sg, sc} ->
            Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
            Promise.make_resolved_promise(yield_result(val))

          {:generator_return, val} ->
            Heap.put_obj(gen_ref, %{state: :completed})
            Promise.make_resolved_promise(done_result(val))

          {:js_throw, _} = thrown ->
            Heap.put_obj(gen_ref, %{state: :completed})
            throw(thrown)
        after
          if prev_ctx, do: Heap.put_ctx(prev_ctx)
        end

      _ ->
        Promise.make_resolved_promise(done_result(:undefined))
    end
  end

  def invoke_async(frame, gas, ctx) do
    try do
      result = QuickBEAM.BeamVM.Interpreter.run_frame(frame, [], gas, ctx)
      Promise.make_resolved_promise(result)
    catch
      {:generator_return, val} -> Promise.make_resolved_promise(val)
      {:js_throw, val} -> Promise.make_rejected_promise(val)
    end
  end

  def generator_next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, frame: frame, stack: stack, gas: gas, ctx: ctx} ->
        Heap.put_ctx(ctx)

        try do
          # QuickJS yield protocol: [is_return_or_throw, value | saved_stack]
          result = QuickBEAM.BeamVM.Interpreter.run_frame(frame, [false, arg | stack], gas, ctx)
          Heap.put_obj(gen_ref, %{state: :completed})
          done_result(result)
        catch
          {:generator_yield, val, sf, ss, sg, sc} ->
            Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
            yield_result(val)

          {:generator_yield_star, val, sf, ss, sg, sc} ->
            Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
            val

          {:generator_return, val} ->
            Heap.put_obj(gen_ref, %{state: :completed})
            done_result(val)

          {:js_throw, _} = thrown ->
            Heap.put_obj(gen_ref, %{state: :completed})
            throw(thrown)
        end

      _ ->
        done_result(:undefined)
    end
  end

  def generator_return(gen_ref, val) do
    Heap.put_obj(gen_ref, %{state: :completed})
    done_result(val)
  end

  def yield_result(val) do
    Heap.wrap(%{"value" => val, "done" => false})
  end

  def done_result(val) do
    Heap.wrap(%{"value" => val, "done" => true})
  end
end
