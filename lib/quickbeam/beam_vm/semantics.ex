defmodule QuickBEAM.BeamVM.Semantics do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys, only: [map_data: 0, proto: 0, set_data: 0]

  alias QuickBEAM.BeamVM.{Builtin, Bytecode, Heap, Runtime}
  alias QuickBEAM.BeamVM.Interpreter
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

  def rename_function({:closure, captured, %Bytecode.Function{} = fun}, name),
    do: {:closure, captured, %{fun | name: name}}

  def rename_function(%Bytecode.Function{} = fun, name), do: %{fun | name: name}
  def rename_function({:builtin, _, cb}, name), do: {:builtin, name, cb}
  def rename_function(other, _name), do: other

  def raw_function(ctor_closure) do
    case ctor_closure do
      {:closure, _, %Bytecode.Function{} = fun} -> fun
      %Bytecode.Function{} = fun -> fun
      other -> other
    end
  end

  def define_class(ctor_closure, parent_ctor, class_name \\ nil) do
    ctor_closure =
      if is_binary(class_name) and class_name != "" do
        rename_function(ctor_closure, class_name)
      else
        ctor_closure
      end

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

        %Bytecode.Function{} = ctor ->
          Heap.put_ctor_static(ctor, normalize_property_key(idx), val)
          ctor

        {:closure, _, %Bytecode.Function{}} = ctor ->
          Heap.put_ctor_static(ctor, normalize_property_key(idx), val)
          ctor

        {:builtin, _, _} = ctor ->
          Heap.put_ctor_static(ctor, normalize_property_key(idx), val)
          ctor

        _ ->
          obj
      end

    {idx, obj2}
  end

  def check_ctor_return(val) do
    cond do
      val == :undefined ->
        {true, val}

      object_like?(val) ->
        {false, val}

      true ->
        :error
    end
  end

  def get_super_value(proto_obj, this_obj, key) do
    case find_super_property(proto_obj, key) do
      {:accessor, getter, _} when getter != nil -> invoke_with_receiver(getter, [], this_obj)
      :undefined -> :undefined
      val -> val
    end
  end

  def put_super_value(proto_obj, this_obj, key, val) do
    case find_super_setter(proto_obj, key) do
      nil ->
        QuickBEAM.BeamVM.Interpreter.Objects.put(this_obj, key, val)

      setter ->
        invoke_with_receiver(setter, [val], this_obj)
    end

    :ok
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

  defp object_like?({:obj, _}), do: true
  defp object_like?(%Bytecode.Function{}), do: true
  defp object_like?({:closure, _, %Bytecode.Function{}}), do: true
  defp object_like?({:builtin, _, _}), do: true
  defp object_like?({:bound, _, _, _, _}), do: true
  defp object_like?(_), do: false

  defp invoke_with_receiver(%Bytecode.Function{} = fun, args, this_obj),
    do: Interpreter.invoke_with_receiver(fun, args, Runtime.gas_budget(), this_obj)

  defp invoke_with_receiver({:closure, _, %Bytecode.Function{}} = fun, args, this_obj),
    do: Interpreter.invoke_with_receiver(fun, args, Runtime.gas_budget(), this_obj)

  defp invoke_with_receiver(fun, args, this_obj), do: Builtin.call(fun, args, this_obj)

  defp find_super_setter(proto_obj, key) do
    case find_super_property(proto_obj, key) do
      {:accessor, _, setter} when setter != nil -> setter
      _ -> nil
    end
  end

  defp find_super_property({:obj, ref}, key) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, val} -> val
          :error -> find_super_property(Map.get(map, proto(), :undefined), key)
        end

      _ ->
        Property.get({:obj, ref}, key)
    end
  end

  defp find_super_property({:closure, _, %Bytecode.Function{} = fun} = ctor, key) do
    statics = Heap.get_ctor_statics(ctor)

    case Map.fetch(statics, key) do
      {:ok, val} ->
        val

      :error ->
        find_super_property(
          Heap.get_parent_ctor(fun) || Map.get(statics, "__proto__", :undefined),
          key
        )
    end
  end

  defp find_super_property(%Bytecode.Function{} = fun, key) do
    statics = Heap.get_ctor_statics(fun)

    case Map.fetch(statics, key) do
      {:ok, val} ->
        val

      :error ->
        find_super_property(
          Heap.get_parent_ctor(fun) || Map.get(statics, "__proto__", :undefined),
          key
        )
    end
  end

  defp find_super_property({:builtin, _, _} = ctor, key) do
    statics = Heap.get_ctor_statics(ctor)

    case Map.fetch(statics, key) do
      {:ok, val} -> val
      :error -> find_super_property(Map.get(statics, "__proto__", :undefined), key)
    end
  end

  defp find_super_property(value, key), do: Property.get(value, key)
end
