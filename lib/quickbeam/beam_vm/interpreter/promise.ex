defmodule QuickBEAM.BeamVM.Interpreter.Promise do
  import QuickBEAM.BeamVM.Heap.Keys
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  def resolved(val) do
    promise_ref = make_ref()

    Heap.put_obj(promise_ref, %{
      promise_state() => :resolved,
      promise_value() => val,
      "then" => then_fn(promise_ref),
      "catch" => catch_fn(promise_ref)
    })

    {:obj, promise_ref}
  end

  @doc false
  def rejected(val) do
    promise_ref = make_ref()

    Heap.put_obj(promise_ref, %{
      promise_state() => :rejected,
      promise_value() => val,
      "then" => then_fn(promise_ref),
      "catch" => catch_fn(promise_ref)
    })

    {:obj, promise_ref}
  end

  def then_fn(promise_ref) do
    {:builtin, "then",
     fn args, _this ->
       on_fulfilled = Enum.at(args, 0)
       on_rejected = Enum.at(args, 1)

       case Heap.get_obj(promise_ref, %{}) do
         %{
           promise_state() => :resolved,
           promise_value() => val
         } ->
           if on_fulfilled && on_fulfilled != :undefined do
             child_ref = make_ref()

             Heap.put_obj(child_ref, %{
               promise_state() => :pending,
               "then" => then_fn(child_ref),
               "catch" => catch_fn(child_ref)
             })

             Heap.enqueue_microtask({:resolve, child_ref, on_fulfilled, val})
             {:obj, child_ref}
           else
             resolved(val)
           end

         %{
           promise_state() => :rejected,
           promise_value() => val
         } ->
           if on_rejected && on_rejected != :undefined do
             child_ref = make_ref()

             Heap.put_obj(child_ref, %{
               promise_state() => :pending,
               "then" => then_fn(child_ref),
               "catch" => catch_fn(child_ref)
             })

             Heap.enqueue_microtask({:resolve, child_ref, on_rejected, val})
             {:obj, child_ref}
           else
             rejected(val)
           end

         %{promise_state() => :pending} ->
           child_ref = make_ref()

           Heap.put_obj(child_ref, %{
             promise_state() => :pending,
             "then" => then_fn(child_ref),
             "catch" => catch_fn(child_ref)
           })

           # Queue for when parent resolves
           waiters = Heap.get_promise_waiters(promise_ref)

           Heap.put_promise_waiters(promise_ref, [
             {on_fulfilled, on_rejected, child_ref} | waiters
           ])

           {:obj, child_ref}

         _ ->
           resolved(:undefined)
       end
     end}
  end

  def catch_fn(promise_ref) do
    {:builtin, "catch",
     fn args, this ->
       handler = List.first(args)
       then_fn = then_fn(promise_ref)

       case then_fn do
         {:builtin, _, cb} -> cb.([nil, handler], this)
       end
     end}
  end

  @doc false
  def drain_microtasks do
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
            resolve(child_ref, :rejected, err)

          result_val ->
            # If result is a promise, chain it
            case result_val do
              {:obj, r} ->
                case Heap.get_obj(r, %{}) do
                  %{
                    promise_state() => :resolved,
                    promise_value() => v
                  } ->
                    resolve(child_ref, :resolved, v)

                  %{
                    promise_state() => :rejected,
                    promise_value() => v
                  } ->
                    resolve(child_ref, :rejected, v)

                  %{promise_state() => :pending} ->
                    waiters = Heap.get_promise_waiters(r)

                    Heap.put_promise_waiters(r, [
                      {fn v -> resolve(child_ref, :resolved, v) end, nil, child_ref}
                      | waiters
                    ])

                  _ ->
                    resolve(child_ref, :resolved, result_val)
                end

              _ ->
                resolve(child_ref, :resolved, result_val)
            end
        end

        drain_microtasks()
    end
  end

  def resolve(ref, state, val) do
    Heap.put_obj(ref, %{
      promise_state() => state,
      promise_value() => val,
      "then" => then_fn(ref),
      "catch" => catch_fn(ref)
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
end
