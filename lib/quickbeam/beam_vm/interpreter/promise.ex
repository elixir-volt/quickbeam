defmodule QuickBEAM.BeamVM.Interpreter.Promise do
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  def make_resolved_promise(val) do
    promise_ref = make_ref()

    Heap.put_obj(promise_ref, %{
      "__promise_state__" => :resolved,
      "__promise_value__" => val,
      "then" => make_then_fn(promise_ref),
      "catch" => make_catch_fn(promise_ref)
    })

    {:obj, promise_ref}
  end

  @doc false
  def make_rejected_promise(val) do
    promise_ref = make_ref()

    Heap.put_obj(promise_ref, %{
      "__promise_state__" => :rejected,
      "__promise_value__" => val,
      "then" => make_then_fn(promise_ref),
      "catch" => make_catch_fn(promise_ref)
    })

    {:obj, promise_ref}
  end

  def make_then_fn(promise_ref) do
    {:builtin, "then",
     fn args, _this ->
       on_fulfilled = Enum.at(args, 0)
       on_rejected = Enum.at(args, 1)

       case Heap.get_obj(promise_ref, %{}) do
         %{"__promise_state__" => :resolved, "__promise_value__" => val} ->
           if on_fulfilled && on_fulfilled != :undefined do
             child_ref = make_ref()

             Heap.put_obj(child_ref, %{
               "__promise_state__" => :pending,
               "then" => make_then_fn(child_ref),
               "catch" => make_catch_fn(child_ref)
             })

             Heap.enqueue_microtask({:resolve, child_ref, on_fulfilled, val})
             {:obj, child_ref}
           else
             make_resolved_promise(val)
           end

         %{"__promise_state__" => :rejected, "__promise_value__" => val} ->
           if on_rejected && on_rejected != :undefined do
             child_ref = make_ref()

             Heap.put_obj(child_ref, %{
               "__promise_state__" => :pending,
               "then" => make_then_fn(child_ref),
               "catch" => make_catch_fn(child_ref)
             })

             Heap.enqueue_microtask({:resolve, child_ref, on_rejected, val})
             {:obj, child_ref}
           else
             make_rejected_promise(val)
           end

         %{"__promise_state__" => :pending} ->
           child_ref = make_ref()

           Heap.put_obj(child_ref, %{
             "__promise_state__" => :pending,
             "then" => make_then_fn(child_ref),
             "catch" => make_catch_fn(child_ref)
           })

           # Queue for when parent resolves
           waiters = Heap.get_promise_waiters(promise_ref)

           Heap.put_promise_waiters(promise_ref, [
             {on_fulfilled, on_rejected, child_ref} | waiters
           ])

           {:obj, child_ref}

         _ ->
           make_resolved_promise(:undefined)
       end
     end}
  end

  def make_catch_fn(promise_ref) do
    {:builtin, "catch",
     fn args, this ->
       handler = List.first(args)
       then_fn = make_then_fn(promise_ref)

       case then_fn do
         {:builtin, _, cb} -> cb.([nil, handler], this)
       end
     end}
  end

  @doc false
  def drain_microtask_queue do
    case Heap.dequeue_microtask() do
      nil ->
        :ok

      {:resolve, child_ref, callback, val} ->
        result =
          try do
            QuickBEAM.BeamVM.Interpreter.invoke_callback(callback, [val])
          catch
            {:js_throw, err} -> {:rejected, err}
          end

        case result do
          {:rejected, err} ->
            resolve_promise(child_ref, :rejected, err)

          result_val ->
            # If result is a promise, chain it
            case result_val do
              {:obj, r} ->
                case Heap.get_obj(r, %{}) do
                  %{"__promise_state__" => :resolved, "__promise_value__" => v} ->
                    resolve_promise(child_ref, :resolved, v)

                  %{"__promise_state__" => :rejected, "__promise_value__" => v} ->
                    resolve_promise(child_ref, :rejected, v)

                  %{"__promise_state__" => :pending} ->
                    waiters = Heap.get_promise_waiters(r)

                    Heap.put_promise_waiters(r, [
                      {fn v -> resolve_promise(child_ref, :resolved, v) end, nil, child_ref}
                      | waiters
                    ])

                  _ ->
                    resolve_promise(child_ref, :resolved, result_val)
                end

              _ ->
                resolve_promise(child_ref, :resolved, result_val)
            end
        end

        drain_microtask_queue()
    end
  end

  def resolve_promise(ref, state, val) do
    Heap.put_obj(ref, %{
      "__promise_state__" => state,
      "__promise_value__" => val,
      "then" => make_then_fn(ref),
      "catch" => make_catch_fn(ref)
    })

    # Notify waiters
    waiters = Heap.get_promise_waiters(ref)
    Heap.delete_promise_waiters(ref)

    for {on_fulfilled, on_rejected, child_ref} <- waiters do
      case state do
        :resolved when on_fulfilled != nil and on_fulfilled != :undefined ->
          Heap.enqueue_microtask({:resolve, child_ref, on_fulfilled, val})

        :rejected when on_rejected != nil and on_rejected != :undefined ->
          Heap.enqueue_microtask({:resolve, child_ref, on_rejected, val})

        :resolved ->
          Heap.enqueue_microtask({:resolve, child_ref, fn v -> v end, val})

        :rejected ->
          Heap.enqueue_microtask({:resolve, child_ref, fn v -> v end, val})
      end
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
