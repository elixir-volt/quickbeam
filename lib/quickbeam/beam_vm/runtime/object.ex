defmodule QuickBEAM.BeamVM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.BeamVM.Builtin

  import QuickBEAM.BeamVM.Heap.Keys
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Bytecode

  def build_prototype do
    ref = make_ref()

    Heap.put_obj(ref, %{
      "toString" => {:builtin, "toString", fn _, _ -> "[object Object]" end},
      "valueOf" => {:builtin, "valueOf", fn _, this -> this end},
      "hasOwnProperty" => {:builtin, "hasOwnProperty", &has_own_property/2},
      "isPrototypeOf" => {:builtin, "isPrototypeOf", fn _, _ -> false end},
      "propertyIsEnumerable" => {:builtin, "propertyIsEnumerable", &property_enumerable?/2}
    })

    proto = {:obj, ref}

    for key <- [
          "toString",
          "valueOf",
          "hasOwnProperty",
          "isPrototypeOf",
          "propertyIsEnumerable",
          "constructor"
        ] do
      Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true, writable: true})
    end

    Heap.put_object_prototype(proto)
    proto
  end

  defp has_own_property([key | _], {:obj, r}) do
    data = Heap.get_obj(r, %{})
    is_map(data) and Map.has_key?(data, key)
  end

  defp has_own_property(_, _), do: false

  defp property_enumerable?([key | _], {:obj, r}) do
    not match?(%{enumerable: false}, Heap.get_prop_desc(r, key))
  end

  defp property_enumerable?(_, _), do: false

  static "keys" do
    keys(args)
  end

  static "values" do
    values(args)
  end

  static "entries" do
    entries(args)
  end

  static "assign" do
    assign(args)
  end

  static "freeze" do
    case hd(args) do
      {:obj, ref} = obj ->
        Heap.freeze(ref)
        obj

      obj ->
        obj
    end
  end

  static "is" do
    [a, b | _] = args

    cond do
      is_number(a) and is_number(b) and a == 0 and b == 0 ->
        Values.neg_zero?(a) == Values.neg_zero?(b)

      is_number(a) and is_number(b) ->
        a === b

      a == :nan and b == :nan ->
        true

      true ->
        a === b
    end
  end

  static "create" do
    case args do
      [nil | _] -> Heap.wrap(%{})
      [proto | _] -> Heap.wrap(%{proto() => proto})
      _ -> Runtime.new_object()
    end
  end

  static "getPrototypeOf" do
    case args do
      [{:obj, ref} | _] ->
        Map.get(Heap.get_obj(ref, %{}), proto(), nil)

      [val | _] when is_list(val) ->
        Heap.get_class_proto(Runtime.global_bindings()["Array"])

      [{:builtin, _, _} | _] -> func_proto()
      [{:closure, _, _} | _] -> func_proto()
      [%Bytecode.Function{} | _] -> func_proto()
      [val | _] when is_function(val) -> func_proto()

      _ ->
        nil
    end
  end

  defp func_proto do
    case Process.get(:qb_func_proto) do
      nil ->
        ref = make_ref()
        call_fn = {:builtin, "call", fn [this | args], _ ->
          Runtime.call_callback(this, args)
        end}
        apply_fn = {:builtin, "apply", fn [this, arg_array], _ ->
          args = case arg_array do
            {:obj, r} -> case Heap.get_obj(r, []) do l when is_list(l) -> l; _ -> [] end
            _ -> []
          end
          Runtime.call_callback(this, args)
        end}
        bind_fn = {:builtin, "bind", fn [this | bound_args], func ->
          {:bound, "bound", func, this, bound_args}
        end}
        proto = Heap.wrap(%{"call" => call_fn, "apply" => apply_fn, "bind" => bind_fn, "constructor" => :undefined})
        Process.put(:qb_func_proto, proto)
        proto
      existing -> existing
    end
  end

  static "defineProperty" do
    define_property(args)
  end

  static "getOwnPropertyNames" do
    get_own_property_names(args)
  end

  static "getOwnPropertyDescriptor" do
    get_own_property_descriptor(args)
  end

  static "fromEntries" do
    from_entries(args)
  end

  static "getOwnPropertySymbols" do
    case args do
      [{:obj, ref} | _] ->
        data = Heap.get_obj(ref, %{})

        syms =
          if is_map(data), do: Enum.filter(Map.keys(data), &match?({:symbol, _, _}, &1)), else: []

        Heap.wrap(syms)

      _ ->
        Heap.wrap([])
    end
  end

  static "hasOwn" do
    case args do
      [{:obj, ref}, key | _] ->
        prop_name = if is_binary(key), do: key, else: to_string(key)
        map = Heap.get_obj(ref, %{})
        is_map(map) and Map.has_key?(map, prop_name)

      _ ->
        false
    end
  end

  static "setPrototypeOf" do
    case args do
      [{:obj, ref} = obj, proto | _] ->
        map = Heap.get_obj(ref, %{})
        if is_map(map), do: Heap.put_obj(ref, Map.put(map, proto(), proto))
        obj

      [obj | _] ->
        obj

      _ ->
        :undefined
    end
  end

  defp from_entries([{:obj, ref} | _]) do
    entries =
      case Heap.get_obj(ref, []) do
        list when is_list(list) -> list
        _ -> []
      end

    result_ref = make_ref()

    map =
      Enum.reduce(entries, %{}, fn
        {:obj, eref}, acc ->
          case Heap.get_obj(eref, []) do
            [k, v | _] -> Map.put(acc, Runtime.stringify(k), v)
            _ -> acc
          end

        [k, v | _], acc ->
          Map.put(acc, Runtime.stringify(k), v)

        _, acc ->
          acc
      end)

    Heap.put_obj(result_ref, map)
    {:obj, result_ref}
  end

  defp from_entries(_), do: Runtime.new_object()

  defp keys([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    if is_list(data) do
      Heap.wrap(array_indices(data))
    else
      keys_from_map(ref, data)
    end
  end

  defp keys(_) do
    Heap.wrap([])
  end

  defp keys_from_map(_ref, list) when is_list(list) do
    Heap.wrap(array_indices(list))
  end

  defp keys_from_map(ref, map) when is_map(map) do
    Heap.wrap(enumerable_keys(ref))
  end

  defp get_own_property_names([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    names =
      case data do
        list when is_list(list) ->
          array_indices(list) ++ ["length"]

        map when is_map(map) ->
          Map.keys(map)
          |> Enum.filter(&is_binary/1)
          |> Enum.reject(fn k -> String.starts_with?(k, "__") and String.ends_with?(k, "__") end)

        _ ->
          []
      end

    Heap.wrap(names)
  end

  defp get_own_property_names(_) do
    Heap.wrap([])
  end

  defp enumerable_keys(ref) do
    data = Heap.get_obj(ref, %{})

    case data do
      list when is_list(list) ->
        array_indices(list)

      map when is_map(map) ->
        raw =
          case Map.get(map, key_order()) do
            order when is_list(order) -> Enum.reverse(order)
            _ -> Map.keys(map)
          end

        Runtime.sort_numeric_keys(raw)
        |> Enum.filter(fn k ->
          not String.starts_with?(k, "__") and
            Map.has_key?(map, k) and
            not match?(%{enumerable: false}, Heap.get_prop_desc(ref, k))
        end)

      _ ->
        []
    end
  end

  defp values([{:obj, ref} | _]) do
    map = Heap.get_obj(ref, %{})
    Heap.wrap(Enum.map(enumerable_keys(ref), fn k -> Map.get(map, k) end))
  end

  defp values([map | _]) when is_map(map), do: Map.values(map)
  defp values(_), do: []

  defp entries([{:obj, ref} | _]) do
    map = Heap.get_obj(ref, %{})
    pairs = Enum.map(enumerable_keys(ref), fn k -> Heap.wrap([k, Map.get(map, k)]) end)
    Heap.wrap(pairs)
  end

  defp entries([map | _]) when is_map(map) do
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end

  defp entries(_), do: []

  defp assign([target | sources]) do
    Enum.reduce(sources, target, fn
      {:obj, ref}, {:obj, tref} ->
        src_map = Heap.get_obj(ref, %{})
        tgt_map = Heap.get_obj(tref, %{})
        Heap.put_obj(tref, Map.merge(tgt_map, src_map))
        {:obj, tref}

      map, {:obj, tref} when is_map(map) ->
        tgt_map = Heap.get_obj(tref, %{})
        Heap.put_obj(tref, Map.merge(tgt_map, map))
        {:obj, tref}

      _, acc ->
        acc
    end)
  end

  defp define_property([{:obj, ref} = obj, key, {:obj, desc_ref} | _]) do
    desc = Heap.get_obj(desc_ref, %{})
    prop_name = if is_binary(key), do: key, else: to_string(key)
    existing = Heap.get_obj(ref, %{})

    getter = Map.get(desc, "get")
    setter = Map.get(desc, "set")

    if getter != nil or setter != nil do
      existing_desc = Map.get(existing, prop_name)

      {old_get, old_set} =
        case existing_desc do
          {:accessor, g, s} -> {g, s}
          _ -> {nil, nil}
        end

      new_get = if getter != nil, do: getter, else: old_get
      new_set = if setter != nil, do: setter, else: old_set
      Heap.put_obj(ref, Map.put(existing, prop_name, {:accessor, new_get, new_set}))
    else
      val = Map.get(desc, "value", Map.get(existing, prop_name, :undefined))
      Heap.put_obj(ref, Map.put(existing, prop_name, val))
    end

    writable = Map.get(desc, "writable", true)
    enumerable = Map.get(desc, "enumerable", true)
    configurable = Map.get(desc, "configurable", true)

    Heap.put_prop_desc(ref, prop_name, %{
      writable: writable,
      enumerable: enumerable,
      configurable: configurable
    })

    obj
  end

  defp define_property([obj | _]), do: obj

  defp get_own_property_descriptor([{:obj, ref}, key | _]) do
    prop_name = if is_binary(key), do: key, else: to_string(key)
    map = Heap.get_obj(ref, %{})

    case Map.get(map, prop_name) do
      nil ->
        :undefined

      {:accessor, getter, setter} ->
        desc = Heap.get_prop_desc(ref, prop_name) || %{enumerable: true, configurable: true}
        desc_ref = make_ref()

        Heap.put_obj(desc_ref, %{
          "get" => getter || :undefined,
          "set" => setter || :undefined,
          "enumerable" => desc.enumerable,
          "configurable" => desc.configurable
        })

        {:obj, desc_ref}

      val ->
        desc =
          Heap.get_prop_desc(ref, prop_name) ||
            %{writable: true, enumerable: true, configurable: true}

        desc_ref = make_ref()

        Heap.put_obj(desc_ref, %{
          "value" => val,
          "writable" => desc.writable,
          "enumerable" => desc.enumerable,
          "configurable" => desc.configurable
        })

        {:obj, desc_ref}
    end
  end

  defp get_own_property_descriptor(_), do: :undefined

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
  end
end
