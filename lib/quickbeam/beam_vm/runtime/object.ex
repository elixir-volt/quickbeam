defmodule QuickBEAM.BeamVM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.BeamVM.Builtin

  import QuickBEAM.BeamVM.Heap.Keys
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Interpreter.Values

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
        a === b or (a != a and b != b)

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
      _ -> Runtime.obj_new()
    end
  end

  static "getPrototypeOf" do
    case args do
      [{:obj, ref} | _] -> Map.get(Heap.get_obj(ref, %{}), proto(), nil)
      _ -> nil
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
            [k, v | _] -> Map.put(acc, Runtime.js_to_string(k), v)
            _ -> acc
          end

        [k, v | _], acc ->
          Map.put(acc, Runtime.js_to_string(k), v)

        _, acc ->
          acc
      end)

    Heap.put_obj(result_ref, map)
    {:obj, result_ref}
  end

  defp from_entries(_), do: Runtime.obj_new()

  defp keys([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    if is_list(data) do
      keys = Enum.with_index(data) |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
      Heap.wrap(keys)
    else
      keys_from_map(ref, data)
    end
  end

  defp keys(_) do
    Heap.wrap([])
  end

  defp keys_from_map(_ref, list) when is_list(list) do
    keys = Enum.with_index(list) |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
    Heap.wrap(keys)
  end

  defp keys_from_map(ref, map) when is_map(map) do
    raw_keys =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> Map.keys(map)
      end

    {numeric, strings} =
      Enum.split_with(raw_keys, fn
        k when is_integer(k) -> true
        k when is_binary(k) -> match?({_, ""}, Integer.parse(k))
        _ -> false
      end)

    sorted_numeric =
      Enum.sort_by(numeric, fn
        k when is_integer(k) -> k
        k when is_binary(k) -> elem(Integer.parse(k), 0)
      end)
      |> Enum.map(fn
        k when is_integer(k) -> Integer.to_string(k)
        k -> k
      end)

    all = sorted_numeric ++ Enum.filter(strings, &is_binary/1)

    filtered =
      Enum.filter(all, fn k ->
        not String.starts_with?(k, "__") and
          Map.has_key?(map, k) and
          not match?(%{enumerable: false}, Heap.get_prop_desc(ref, k))
      end)

    Heap.wrap(filtered)
  end

  defp get_own_property_names([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    names =
      case data do
        list when is_list(list) ->
          Enum.with_index(list) |> Enum.map(fn {_, i} -> Integer.to_string(i) end)

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

  defp raw_keys({:obj, ref}) do
    case Heap.get_obj(ref, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp values([{:obj, ref} | _]) do
    ks = raw_keys(keys([{:obj, ref}]))
    map = Heap.get_obj(ref, %{})
    vals = Enum.map(ks, fn k -> Map.get(map, k) end)
    Heap.wrap(vals)
  end

  defp values([map | _]) when is_map(map), do: Map.values(map)
  defp values(_), do: []

  defp entries([{:obj, ref} | _]) do
    ks = raw_keys(keys([{:obj, ref}]))
    map = Heap.get_obj(ref, %{})

    pairs =
      Enum.map(ks, fn k ->
        Heap.wrap([k, Map.get(map, k)])
      end)

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
end
