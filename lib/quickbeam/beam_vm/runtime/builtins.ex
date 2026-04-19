defmodule QuickBEAM.BeamVM.Runtime.Builtins do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Heap, Runtime}

  def object_constructor, do: fn _args, _this -> Runtime.new_object() end

  def array_constructor do
    fn args, _this ->
      list =
        case args do
          [n] when is_integer(n) and n >= 0 -> List.duplicate(:undefined, n)
          _ -> args
        end

      Heap.wrap(list)
    end
  end

  def string_constructor, do: fn args, _this -> Runtime.stringify(List.first(args, "")) end
  def number_constructor, do: fn args, _this -> Runtime.to_number(List.first(args, 0)) end

  def function_constructor do
    fn _args, _this ->
      throw(
        {:js_throw,
         %{"message" => "Function constructor not supported in BEAM mode", "name" => "Error"}}
      )
    end
  end

  def bigint_constructor do
    fn
      [n | _], _this when is_integer(n) ->
        {:bigint, n}

      [s | _], _this when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} ->
            {:bigint, n}

          _ ->
            throw(
              {:js_throw, %{"message" => "Cannot convert to BigInt", "name" => "SyntaxError"}}
            )
        end

      [{:bigint, n} | _], _this ->
        {:bigint, n}

      _, _this ->
        throw({:js_throw, %{"message" => "Cannot convert to BigInt", "name" => "TypeError"}})
    end
  end

  def error_constructor do
    fn args, _this ->
      msg = List.first(args, "")
      Heap.wrap(%{"message" => Runtime.stringify(msg), "stack" => ""})
    end
  end

  def regexp_constructor do
    fn [pattern | rest], _this ->
      flags =
        case rest do
          [f | _] when is_binary(f) -> f
          _ -> ""
        end

      pat =
        case pattern do
          {:regexp, p, _} -> p
          s when is_binary(s) -> s
          _ -> ""
        end

      {:regexp, pat, flags}
    end
  end
end
