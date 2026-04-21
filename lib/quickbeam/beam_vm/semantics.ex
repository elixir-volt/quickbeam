defmodule QuickBEAM.BeamVM.Semantics do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys, only: [map_data: 0, proto: 0, set_data: 0]

  alias QuickBEAM.BeamVM.{Bytecode, Heap, Runtime}
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.Runtime.Property

  def get_super(func) do
    case func do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) -> Map.get(map, proto(), :undefined)
          _ -> :undefined
        end

      {:closure, _, %Bytecode.Function{} = fun} ->
        Heap.get_parent_ctor(fun) || :undefined

      %Bytecode.Function{} = fun ->
        Heap.get_parent_ctor(fun) || :undefined

      {:builtin, _, _} = builtin ->
        Map.get(Heap.get_ctor_statics(builtin), "__proto__", :undefined)

      _ ->
        :undefined
    end
  end

  def function_name(name_val) do
    case name_val do
      s when is_binary(s) -> s
      n when is_number(n) -> Values.stringify(n)
      {:symbol, desc, _} -> "[" <> desc <> "]"
      {:symbol, desc} -> "[" <> desc <> "]"
      _ -> ""
    end
  end

  def normalize_property_key(idx) do
    case idx do
      i when is_integer(i) -> Integer.to_string(i)
      {:symbol, _} = sym -> sym
      {:symbol, _, _} = sym -> sym
      s when is_binary(s) -> s
      other -> Kernel.to_string(other)
    end
  end

  def coalesce_this_result(result, this_obj) do
    case result do
      {:obj, _} = obj -> obj
      %Bytecode.Function{} = fun -> fun
      {:closure, _, %Bytecode.Function{}} = closure -> closure
      _ -> this_obj
    end
  end

  def raw_function(ctor_closure) do
    case ctor_closure do
      {:closure, _, %Bytecode.Function{} = fun} -> fun
      %Bytecode.Function{} = fun -> fun
      other -> other
    end
  end

  def define_class(ctor_closure, parent_ctor) do
    raw = raw_function(ctor_closure)
    proto_ref = make_ref()
    proto_map = %{"constructor" => ctor_closure}
    parent_proto = Heap.get_class_proto(parent_ctor)
    proto_map = if parent_proto, do: Map.put(proto_map, proto(), parent_proto), else: proto_map

    Heap.put_obj(proto_ref, proto_map)
    proto = {:obj, proto_ref}
    Heap.put_class_proto(raw, proto)
    Heap.put_ctor_static(ctor_closure, "prototype", proto)

    if parent_ctor != :undefined do
      Heap.put_parent_ctor(raw, parent_ctor)
    end

    {proto, ctor_closure}
  end

  def length_of(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} -> :array.size(arr)
          list when is_list(list) -> length(list)
          map when is_map(map) -> Map.get(map, "length", map_size(map))
          _ -> 0
        end

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      s when is_binary(s) ->
        Property.string_length(s)

      %Bytecode.Function{} = fun ->
        fun.defined_arg_count

      {:closure, _, %Bytecode.Function{} = fun} ->
        fun.defined_arg_count

      {:bound, len, _, _, _} ->
        len

      _ ->
        :undefined
    end
  end

  def define_array_el(obj, idx, val) do
    obj2 =
      case obj do
        list when is_list(list) ->
          i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
          QuickBEAM.BeamVM.Interpreter.Objects.set_list_at(list, i, val)

        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])

          cond do
            match?({:qb_arr, _}, stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.array_set(ref, i, val)

            is_list(stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.put_obj(ref, QuickBEAM.BeamVM.Interpreter.Objects.set_list_at(stored, i, val))

            is_map(stored) ->
              Heap.put_obj_key(ref, normalize_property_key(idx), val)

            true ->
              :ok
          end

          {:obj, ref}

        _ ->
          obj
      end

    {idx, obj2}
  end

  def copy_data_properties(target, source) do
    src_props =
      case source do
        {:obj, _} = source_obj -> enumerable_string_props(source_obj)
        map when is_map(map) -> map
        _ -> %{}
      end

    case target do
      {:obj, ref} ->
        existing = Heap.get_obj(ref, %{})
        existing = if is_map(existing), do: existing, else: %{}
        Heap.put_obj(ref, Map.merge(existing, src_props))

      _ ->
        :ok
    end

    :ok
  end

  def enumerable_string_props({:obj, ref} = source_obj) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, _} ->
        Enum.reduce(0..max(Heap.array_size(ref) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Property.get(source_obj, Integer.to_string(i)))
        end)

      list when is_list(list) ->
        Enum.reduce(0..max(length(list) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Property.get(source_obj, Integer.to_string(i)))
        end)

      map when is_map(map) ->
        map
        |> Map.keys()
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(fn k -> String.starts_with?(k, "__") and String.ends_with?(k, "__") end)
        |> Enum.reduce(%{}, fn k, acc -> Map.put(acc, k, Property.get(source_obj, k)) end)

      _ ->
        %{}
    end
  end

  def enumerable_string_props(map) when is_map(map), do: map
  def enumerable_string_props(_), do: %{}

  def spread_source_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def spread_source_to_list(list) when is_list(list), do: list

  def spread_source_to_list({:obj, ref}) do
    case Heap.get_obj(ref) do
      {:qb_arr, arr} ->
        :array.to_list(arr)

      list when is_list(list) ->
        list

      map when is_map(map) ->
        cond do
          Map.has_key?(map, {:symbol, "Symbol.iterator"}) ->
            iter_fn = Map.get(map, {:symbol, "Symbol.iterator"})
            iter_obj = Runtime.call_callback(iter_fn, [])
            collect_iterator_values(iter_obj, [])

          Map.has_key?(map, set_data()) ->
            Map.get(map, set_data(), [])

          Map.has_key?(map, map_data()) ->
            Map.get(map, map_data(), [])

          true ->
            []
        end

      _ ->
        []
    end
  end

  def spread_source_to_list(_), do: []

  def spread_target_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def spread_target_to_list(list) when is_list(list), do: list
  def spread_target_to_list({:obj, _ref} = obj), do: Heap.to_list(obj)
  def spread_target_to_list(_), do: []

  defp collect_iterator_values(iter_obj, acc) do
    next_fn = Property.get(iter_obj, "next")
    result = Runtime.call_callback(next_fn, [])

    if Property.get(result, "done") do
      Enum.reverse(acc)
    else
      collect_iterator_values(iter_obj, [Property.get(result, "value") | acc])
    end
  end
end
