defmodule QuickBEAM.BeamVM.Runtime.Prototypes do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.{Bytecode, Runtime}
  alias QuickBEAM.BeamVM.{Builtin, Interpreter}

  defp normalize_map_key(k) when is_float(k) and k == trunc(k), do: trunc(k)
  defp normalize_map_key(k), do: k

  # ── Map prototype ──

  def map_proto("get"), do: {:builtin, "get", &map_get/2}
  def map_proto("set"), do: {:builtin, "set", &map_set/2}
  def map_proto("has"), do: {:builtin, "has", &map_has/2}
  def map_proto("delete"), do: {:builtin, "delete", &map_delete/2}
  def map_proto("clear"), do: {:builtin, "clear", &map_clear/2}
  def map_proto("keys"), do: {:builtin, "keys", &map_keys/2}
  def map_proto("values"), do: {:builtin, "values", &map_values/2}
  def map_proto("entries"), do: {:builtin, "entries", &map_entries/2}
  def map_proto("forEach"), do: {:builtin, "forEach", &map_for_each/2}
  def map_proto(_), do: :undefined

  defp map_get([key | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.get(data, normalize_map_key(key), :undefined)
  end

  defp map_set([key, val | _], {:obj, ref}) do
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
  end

  defp map_has([key | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.has_key?(data, normalize_map_key(key))
  end

  defp map_delete([key | _], {:obj, ref}) do
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
  end

  defp map_clear(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | map_data() => %{}, "size" => 0})
    :undefined
  end

  defp map_keys(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Heap.wrap(Map.keys(data))
  end

  defp map_values(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Heap.wrap(Map.values(data))
  end

  defp map_entries(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    entries = Enum.map(data, fn {k, v} -> Heap.wrap([k, v]) end)
    Heap.wrap(entries)
  end

  defp map_for_each([cb | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

    Enum.each(data, fn {k, v} ->
      Runtime.call_callback(cb, [v, k, {:obj, ref}], :no_interp)
    end)

    :undefined
  end

  # ── Set prototype ──

  def set_proto("has"), do: {:builtin, "has", &set_has/2}
  def set_proto("add"), do: {:builtin, "add", &set_add/2}
  def set_proto("delete"), do: {:builtin, "delete", &set_delete/2}
  def set_proto("clear"), do: {:builtin, "clear", &set_clear/2}
  def set_proto("values"), do: {:builtin, "values", &set_values/2}
  def set_proto("keys"), do: set_proto("values")
  def set_proto("entries"), do: {:builtin, "entries", &set_entries/2}
  def set_proto("forEach"), do: {:builtin, "forEach", &set_for_each/2}
  def set_proto(_), do: :undefined

  defp set_has([val | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    val in data
  end

  defp set_add([val | _], {:obj, ref}) do
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
  end

  defp set_delete([val | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, set_data(), [])
    new_data = List.delete(data, val)

    Heap.put_obj(ref, %{
      obj
      | set_data() => new_data,
        "size" => length(new_data)
    })

    true
  end

  defp set_clear(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | set_data() => [], "size" => 0})
    :undefined
  end

  defp set_values(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    Heap.wrap(data)
  end

  defp set_entries(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    entries = Enum.map(data, fn v -> Heap.wrap([v, v]) end)
    Heap.wrap(entries)
  end

  defp set_for_each([cb | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])

    Enum.each(data, fn v ->
      Runtime.call_callback(cb, [v, v, {:obj, ref}], :no_interp)
    end)

    :undefined
  end

  # ── Function prototype ──

  def function_proto_property(fun, "call") do
    {:builtin, "call", fn args, this -> fn_call(fun, args, this) end}
  end

  def function_proto_property(fun, "apply") do
    {:builtin, "apply", fn args, this -> fn_apply(fun, args, this) end}
  end

  def function_proto_property(fun, "bind") do
    {:builtin, "bind", fn args, this -> fn_bind(fun, args, this) end}
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

  defp fn_call(fun, [this_arg | args], _this) do
    invoke_fun(fun, args, this_arg)
  end

  defp fn_apply(fun, [this_arg | rest], _this) do
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
  end

  defp fn_bind(fun, [this_arg | bound_args], _this) do
    orig_len =
      case fun do
        %Bytecode.Function{defined_arg_count: n} -> n
        {:closure, _, %Bytecode.Function{defined_arg_count: n}} -> n
        _ -> 0
      end

    bound_len = max(0, orig_len - length(bound_args))
    bound_fn = fn args, _this2 -> invoke_fun(fun, bound_args ++ args, this_arg) end
    {:bound, bound_len, {:builtin, "bound", bound_fn}}
  end

  defp invoke_fun(fun, args, this_arg) do
    case fun do
      %Bytecode.Function{} ->
        Interpreter.invoke_with_receiver(fun, args, 10_000_000, this_arg)

      {:closure, _, %Bytecode.Function{}} ->
        Interpreter.invoke_with_receiver(fun, args, 10_000_000, this_arg)

      other ->
        Builtin.call(other, args, this_arg)
    end
  end
end
