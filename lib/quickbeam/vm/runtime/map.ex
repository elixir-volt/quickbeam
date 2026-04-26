defmodule QuickBEAM.VM.Runtime.Map do
  @moduledoc "JS `Map` and `WeakMap` built-ins: constructor, `get`/`set`/`has`/`delete`, and iteration."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime

  def constructor do
    fn args, _this ->
      ref = make_ref()

      entries =
        case args do
          [list] when is_list(list) ->
            Map.new(list, &entry_to_kv/1)

          [{:obj, r}] ->
            stored = Heap.get_obj(r, [])

            if is_list(stored) or match?({:qb_arr, _}, stored) do
              Heap.to_list({:obj, r}) |> Map.new(&entry_to_kv/1)
            else
              %{}
            end

          _ ->
            %{}
        end

      Heap.put_obj(ref, %{
        map_data() => entries,
        "size" => map_size(entries)
      })

      {:obj, ref}
    end
  end

  def weak_constructor do
    fn args, _this ->
      ref = make_ref()

      init =
        case args do
          [{:obj, _} = entries | _] ->
            Heap.to_list(entries)
            |> Enum.reduce(%{}, fn
              {:obj, eref}, acc ->
                case Heap.get_obj(eref, []) do
                  [k, v | _] ->
                    validate_weak_key!(k, "WeakMap")
                    Map.put(acc, k, v)

                  _ ->
                    acc
                end

              _, acc ->
                acc
            end)

          _ ->
            %{}
        end

      Heap.put_obj(ref, %{map_data() => init, "size" => map_size(init), :weak => true})
      {:obj, ref}
    end
  end

  def proto_property("get"), do: {:builtin, "get", &get/2}
  def proto_property("set"), do: {:builtin, "set", &set/2}
  def proto_property("has"), do: {:builtin, "has", &has/2}
  def proto_property("delete"), do: {:builtin, "delete", &delete/2}
  def proto_property("clear"), do: {:builtin, "clear", &clear/2}
  def proto_property("keys"), do: {:builtin, "keys", &keys/2}
  def proto_property("values"), do: {:builtin, "values", &values/2}
  def proto_property("entries"), do: {:builtin, "entries", &entries/2}
  def proto_property("forEach"), do: {:builtin, "forEach", &for_each/2}

  def proto_property("size") do
    {:builtin, "size",
     fn _, {:obj, ref} ->
       Heap.get_obj(ref, %{})
       |> Map.get(map_data(), %{})
       |> map_size()
     end}
  end

  def proto_property(_), do: :undefined

  defp validate_weak_key!({:obj, _}, _), do: :ok
  defp validate_weak_key!({:symbol, _, _}, _), do: :ok

  defp validate_weak_key!(_, kind) do
    JSThrow.type_error!("invalid value used as #{kind} key")
  end

  defp normalize_key(k) when is_float(k) and k == trunc(k), do: trunc(k)
  defp normalize_key(k), do: k

  defp get([key | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.get(data, normalize_key(key), :undefined)
  end

  defp set([key, val | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: validate_weak_key!(key, "WeakMap")
    key = normalize_key(key)
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), [])
    order = if Map.has_key?(data, key), do: order, else: [key | order]
    new_data = Map.put(data, key, val)

    Heap.put_obj(
      ref,
      Map.merge(obj, %{
        map_data() => new_data,
        "size" => map_size(new_data),
        key_order() => order
      })
    )

    {:obj, ref}
  end

  defp has([key | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.has_key?(data, normalize_key(key))
  end

  defp delete([key | _], {:obj, ref}) do
    key = normalize_key(key)
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    new_data = Map.delete(data, key)
    order = Map.get(obj, key_order(), []) |> List.delete(key)

    Heap.put_obj(
      ref,
      Map.merge(obj, %{
        map_data() => new_data,
        "size" => map_size(new_data),
        key_order() => order
      })
    )

    true
  end

  defp clear(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | map_data() => %{}, "size" => 0})
    :undefined
  end

  defp keys(_, {:obj, ref}) do
    order = Heap.get_obj(ref, %{}) |> Map.get(key_order(), []) |> Enum.reverse()
    Heap.wrap(order)
  end

  defp values(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), []) |> Enum.reverse()
    Heap.wrap(Enum.map(order, &Map.get(data, &1)))
  end

  defp entries(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), []) |> Enum.reverse()
    items = Enum.map(order, fn key -> Heap.wrap([key, Map.get(data, key)]) end)
    Heap.wrap(items)
  end

  defp entry_to_kv([k, v | _]), do: {k, v}
  defp entry_to_kv([k]), do: {k, :undefined}

  defp entry_to_kv({:obj, eref}) do
    case Heap.get_obj(eref, []) do
      [k, v | _] ->
        {k, v}

      [k] ->
        {k, :undefined}

      {:qb_arr, arr} ->
        list = :array.to_list(arr)

        case list do
          [k, v | _] -> {k, v}
          [k] -> {k, :undefined}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp entry_to_kv({:qb_arr, arr}) do
    list = :array.to_list(arr)

    case list do
      [k, v | _] -> {k, v}
      [k] -> {k, :undefined}
      _ -> {nil, nil}
    end
  end

  defp entry_to_kv(_), do: {nil, nil}

  defp for_each([cb | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), []) |> Enum.reverse()

    Enum.each(order, fn key ->
      case Map.fetch(data, key) do
        {:ok, value} -> Runtime.call_callback(cb, [value, key, {:obj, ref}])
        :error -> :ok
      end
    end)

    :undefined
  end
end
