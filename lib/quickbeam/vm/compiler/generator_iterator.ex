defmodule QuickBEAM.VM.Compiler.GeneratorIterator do
  @moduledoc """
  Iterator protocol for compiled generator functions.

  Compiled generators throw `{:generator_yield, value, continuation}` to
  suspend. The continuation is a `fun(arg)` that resumes the generator
  body from the yield point with `arg` as the yield return value.
  """

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.PromiseState, as: Promise

  def build(gen_ref) do
    next_fn =
      {:builtin, "next",
       fn
         [arg | _], _this -> do_next(gen_ref, arg)
         [], _this -> do_next(gen_ref, :undefined)
       end}

    return_fn =
      {:builtin, "return",
       fn
         [val | _], _this -> do_return(gen_ref, val)
         [], _this -> do_return(gen_ref, :undefined)
       end}

    Heap.wrap(%{"next" => next_fn, "return" => return_fn})
  end

  def build_async(gen_ref) do
    next_fn =
      {:builtin, "next",
       fn
         [arg | _], _this -> Promise.resolved(do_next(gen_ref, arg))
         [], _this -> Promise.resolved(do_next(gen_ref, :undefined))
       end}

    return_fn =
      {:builtin, "return",
       fn
         [val | _], _this -> Promise.resolved(do_return(gen_ref, val))
         [], _this -> Promise.resolved(do_return(gen_ref, :undefined))
       end}

    Heap.wrap(%{"next" => next_fn, "return" => return_fn})
  end

  defp do_next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, continuation: cont} when is_function(cont, 1) ->
        resume(gen_ref, cont, arg)

      _ ->
        done(:undefined)
    end
  end

  defp do_return(gen_ref, val) do
    Heap.put_obj(gen_ref, %{state: :completed})
    done(val)
  end

  defp resume(gen_ref, cont, arg) do
    result = cont.(arg)
    Heap.put_obj(gen_ref, %{state: :completed})
    done(result)
  catch
    {:generator_yield, val, next_cont} ->
      Heap.put_obj(gen_ref, %{state: :suspended, continuation: next_cont})
      yield(val)

    {:generator_yield_star, val, next_cont} ->
      Heap.put_obj(gen_ref, %{state: :suspended, continuation: next_cont})
      val

    {:generator_return, val} ->
      Heap.put_obj(gen_ref, %{state: :completed})
      done(val)

    {:js_throw, _} = thrown ->
      Heap.put_obj(gen_ref, %{state: :completed})
      throw(thrown)
  end

  defp yield(val), do: Heap.wrap(%{"value" => val, "done" => false})
  defp done(val), do: Heap.wrap(%{"value" => val, "done" => true})
end
