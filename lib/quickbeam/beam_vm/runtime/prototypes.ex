defmodule QuickBEAM.BeamVM.Runtime.Prototypes do
  @moduledoc false

  import QuickBEAM.BeamVM.InternalKeys

  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.{Bytecode, Runtime}

  # ── Key normalization: JS doesn't distinguish -0.0/0 or float/int for Map keys
  defp normalize_map_key(k) when is_float(k) and k == trunc(k), do: trunc(k)
  defp normalize_map_key(k), do: k

  # ── Map prototype ──

  def map_proto("get"),
    do:
      {:builtin, "get",
       fn [key | _], {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
         Map.get(data, normalize_map_key(key), :undefined)
       end}

  def map_proto("set"),
    do:
      {:builtin, "set",
       fn [key, val | _], {:obj, ref} ->
         key = normalize_map_key(key)
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, map_data(), %{})
         new_data = Map.put(data, key, val)

         Heap.put_obj(ref, %{
           obj
           | map_data() => new_data,
             "size" => map_size(new_data)
         })

         {:obj, ref}
       end}

  def map_proto("has"),
    do:
      {:builtin, "has",
       fn [key | _], {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
         Map.has_key?(data, normalize_map_key(key))
       end}

  def map_proto("delete"),
    do:
      {:builtin, "delete",
       fn [key | _], {:obj, ref} ->
         key = normalize_map_key(key)
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, map_data(), %{})
         new_data = Map.delete(data, key)

         Heap.put_obj(ref, %{
           obj
           | map_data() => new_data,
             "size" => map_size(new_data)
         })

         true
       end}

  def map_proto("clear"),
    do:
      {:builtin, "clear",
       fn _, {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         Heap.put_obj(ref, %{obj | map_data() => %{}, "size" => 0})
         :undefined
       end}

  def map_proto("keys"),
    do:
      {:builtin, "keys",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
         keys = Map.keys(data)
         Heap.wrap(keys)
       end}

  def map_proto("values"),
    do:
      {:builtin, "values",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
         vals = Map.values(data)
         Heap.wrap(vals)
       end}

  def map_proto("entries"),
    do:
      {:builtin, "entries",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

         entries =
           Enum.map(data, fn {k, v} ->
             Heap.wrap([k, v])
           end)

         Heap.wrap(entries)
       end}

  def map_proto("forEach"),
    do:
      {:builtin, "forEach",
       fn [cb | _], {:obj, ref}, interp ->
         data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

         Enum.each(data, fn {k, v} ->
           Runtime.call_builtin_callback(cb, [v, k, {:obj, ref}], interp)
         end)

         :undefined
       end}

  def map_proto(_), do: :undefined

  # ── Set prototype ──

  def set_proto("has"),
    do:
      {:builtin, "has",
       fn [val | _], {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
         val in data
       end}

  def set_proto("add"),
    do:
      {:builtin, "add",
       fn [val | _], {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, set_data(), [])

         unless val in data do
           new_data = data ++ [val]

           Heap.put_obj(ref, %{
             obj
             | set_data() => new_data,
               "size" => length(new_data)
           })
         end

         {:obj, ref}
       end}

  def set_proto("delete"),
    do:
      {:builtin, "delete",
       fn [val | _], {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, set_data(), [])
         new_data = List.delete(data, val)

         Heap.put_obj(ref, %{
           obj
           | set_data() => new_data,
             "size" => length(new_data)
         })

         true
       end}

  def set_proto("clear"),
    do:
      {:builtin, "clear",
       fn _, {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         Heap.put_obj(ref, %{obj | set_data() => [], "size" => 0})
         :undefined
       end}

  def set_proto("values"),
    do:
      {:builtin, "values",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
         Heap.wrap(data)
       end}

  def set_proto("keys"), do: set_proto("values")

  def set_proto("entries"),
    do:
      {:builtin, "entries",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])

         entries =
           Enum.map(data, fn v ->
             Heap.wrap([v, v])
           end)

         Heap.wrap(entries)
       end}

  def set_proto("forEach"),
    do:
      {:builtin, "forEach",
       fn [cb | _], {:obj, ref}, interp ->
         data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])

         Enum.each(data, fn v ->
           Runtime.call_builtin_callback(cb, [v, v, {:obj, ref}], interp)
         end)

         :undefined
       end}

  def set_proto(_), do: :undefined

  # ── Function prototype ──

  def function_proto_property(fun, "call") do
    {:builtin, "call",
     fn [this_arg | args], _this ->
       invoke_fun(fun, args, this_arg)
     end}
  end

  def function_proto_property(fun, "apply") do
    {:builtin, "apply",
     fn [this_arg | rest], _this ->
       args_array = List.first(rest)

       args =
         case args_array do
           {:obj, ref} ->
             case Heap.get_obj(ref, []) do
               list when is_list(list) -> list
               _ -> []
             end

           list when is_list(list) ->
             list

           _ ->
             []
         end

       invoke_fun(fun, args, this_arg)
     end}
  end

  def function_proto_property(fun, "bind") do
    orig_len =
      case fun do
        %Bytecode.Function{defined_arg_count: n} -> n
        {:closure, _, %Bytecode.Function{defined_arg_count: n}} -> n
        _ -> 0
      end

    {:builtin, "bind",
     fn [this_arg | bound_args], _this ->
       bound_len = max(0, orig_len - length(bound_args))
       bound_fn = fn args, _this2 -> invoke_fun(fun, bound_args ++ args, this_arg) end
       {:bound, bound_len, {:builtin, "bound", bound_fn}}
     end}
  end

  def function_proto_property(%Bytecode.Function{} = f, "name"), do: f.name || ""
  def function_proto_property(%Bytecode.Function{} = f, "length"), do: f.defined_arg_count

  def function_proto_property({:closure, _, %Bytecode.Function{} = f}, "name"),
    do: f.name || ""

  def function_proto_property({:closure, _, %Bytecode.Function{} = f}, "length"),
    do: f.defined_arg_count

  def function_proto_property({:bound, _, inner}, key) when key not in ["length", "name"],
    do: function_proto_property(inner, key)

  def function_proto_property({:bound, len, _}, "length"), do: len
  def function_proto_property(_fun, "length"), do: 0
  def function_proto_property({:bound, _, _}, "name"), do: "bound "
  def function_proto_property(_fun, "name"), do: ""
  def function_proto_property(_fun, _), do: :undefined

  defp invoke_fun(fun, args, this_arg) do
    case fun do
      %QuickBEAM.BeamVM.Bytecode.Function{} ->
        QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(fun, args, 10_000_000, this_arg)

      {:closure, _, %QuickBEAM.BeamVM.Bytecode.Function{}} ->
        QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(fun, args, 10_000_000, this_arg)

      other ->
        QuickBEAM.BeamVM.Interpreter.Dispatch.call_builtin(other, args, this_arg)
    end
  end
end
