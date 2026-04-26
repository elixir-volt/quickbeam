defmodule QuickBEAM.VM.Runtime.Function do
  @moduledoc "JS `Function` prototype: `call`, `apply`, `bind`, and property access for name/length/fileName."
  alias QuickBEAM.VM.{Builtin, Bytecode, Heap, Invocation}

  @doc "Builds the JavaScript prototype object for this runtime builtin."
  def prototype do
    Heap.wrap(%{
      "call" => {:builtin, "call", fn args, this -> fn_call(this, args, this) end},
      "apply" => {:builtin, "apply", fn args, this -> fn_apply(this, args, this) end},
      "bind" => {:builtin, "bind", fn args, this -> fn_bind(this, args, this) end}
    })
  end

  # ── Function prototype ──

  @doc "Returns a prototype property value for the given JavaScript property key."
  def proto_property(fun, "call") do
    {:builtin, "call", fn args, this -> fn_call(fun, args, this) end}
  end

  def proto_property(fun, "apply") do
    {:builtin, "apply", fn args, this -> fn_apply(fun, args, this) end}
  end

  def proto_property(fun, "bind") do
    {:builtin, "bind", fn args, this -> fn_bind(fun, args, this) end}
  end

  def proto_property(%Bytecode.Function{} = f, "name"), do: f.name || ""
  def proto_property(%Bytecode.Function{} = f, "length"), do: f.defined_arg_count
  def proto_property(%Bytecode.Function{} = f, "fileName"), do: f.filename || ""
  def proto_property(%Bytecode.Function{} = f, "lineNumber"), do: f.line_num
  def proto_property(%Bytecode.Function{} = f, "columnNumber"), do: f.col_num

  def proto_property({:closure, _, %Bytecode.Function{} = f}, "name"),
    do: f.name || ""

  def proto_property({:closure, _, %Bytecode.Function{} = f}, "length"),
    do: f.defined_arg_count

  def proto_property({:closure, _, %Bytecode.Function{} = f}, "fileName"), do: f.filename || ""
  def proto_property({:closure, _, %Bytecode.Function{} = f}, "lineNumber"), do: f.line_num
  def proto_property({:closure, _, %Bytecode.Function{} = f}, "columnNumber"), do: f.col_num

  def proto_property({:bound, _, inner, _, _}, key) when key not in ["length", "name"],
    do: proto_property(inner, key)

  def proto_property({:bound, len, _, _, _}, "length"), do: len
  def proto_property(_fun, "length"), do: 0
  def proto_property({:bound, _, {:builtin, name, _}, _, _}, "name"), do: name
  def proto_property(_fun, "name"), do: ""

  def proto_property(fun, "toString") do
    {:builtin, "toString",
     fn _, _ ->
       case fun do
         {:closure, _, %Bytecode.Function{source: src}} when is_binary(src) and src != "" -> src
         %Bytecode.Function{source: src} when is_binary(src) and src != "" -> src
         {:builtin, name, _} -> "function #{name}() { [native code] }"
         {:bound, _, _, _, _} -> "function () { [native code] }"
         _ -> "function () { [native code] }"
       end
     end}
  end

  def proto_property(_fun, "constructor") do
    case Heap.get_ctx() do
      %{globals: globals} -> Map.get(globals, "Function", :undefined)
      _ -> :undefined
    end
  end

  def proto_property(_fun, _), do: :undefined

  defp fn_call(fun, [this_arg | args], _this) do
    invoke_fun(fun, args, this_arg)
  end

  defp fn_apply(fun, [this_arg | rest], _this) do
    args_array = List.first(rest)

    args =
      case args_array do
        {:obj, ref} ->
          case Heap.get_obj(ref, []) do
            {:qb_arr, arr} -> :array.to_list(arr)
            list when is_list(list) -> list
            _ -> []
          end

        {:qb_arr, arr} ->
          :array.to_list(arr)

        list when is_list(list) ->
          list

        _ ->
          []
      end

    invoke_fun(fun, args, this_arg)
  end

  defp fn_bind(fun, [this_arg | bound_args], _this) do
    orig_len =
      case fun do
        %Bytecode.Function{defined_arg_count: n} -> n
        {:closure, _, %Bytecode.Function{defined_arg_count: n}} -> n
        _ -> 0
      end

    orig_name =
      case fun do
        %Bytecode.Function{name: n} when is_binary(n) -> n
        {:closure, _, %Bytecode.Function{name: n}} when is_binary(n) -> n
        {:builtin, n, _} -> n
        _ -> ""
      end

    bound_len = max(0, orig_len - length(bound_args))
    bound_fn = fn args, _this2 -> invoke_fun(fun, bound_args ++ args, this_arg) end
    {:bound, bound_len, {:builtin, "bound " <> orig_name, bound_fn}, fun, bound_args}
  end

  defp invoke_fun(fun, args, this_arg) do
    case fun do
      %Bytecode.Function{} ->
        Invocation.invoke_with_receiver(fun, args, this_arg)

      {:closure, _, %Bytecode.Function{}} ->
        Invocation.invoke_with_receiver(fun, args, this_arg)

      other ->
        Builtin.call(other, args, this_arg)
    end
  end
end
