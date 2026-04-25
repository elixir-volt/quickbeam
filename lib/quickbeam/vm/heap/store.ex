defmodule QuickBEAM.VM.Heap.Store do
  @moduledoc "Low-level process-dictionary storage for JS heap objects: objects, arrays, cells, atoms, and GC roots."

  import QuickBEAM.VM.Heap.Keys
  alias QuickBEAM.VM.Heap.Shapes

  # ── Raw storage (bypasses shape→map reconstruction) ──

  def get_obj_raw(ref), do: Process.get(ref)
  def put_obj_raw(ref, val), do: Process.put(ref, val)

  # ── Object access (map-compatible, reconstructs shapes) ──

  def get_obj(ref) do
    case Process.get(ref) do
      {:shape, shape_id, _offsets, vals, proto} -> Shapes.to_map(shape_id, vals, proto)
      other -> other
    end
  end

  def get_obj(ref, default) do
    case Process.get(ref, default) do
      {:shape, shape_id, _offsets, vals, proto} -> Shapes.to_map(shape_id, vals, proto)
      other -> other
    end
  end

  def put_obj(ref, list) when is_list(list) do
    Process.put(ref, {:qb_arr, :array.from_list(list, :undefined)})
    track_alloc()
  end

  def put_obj(ref, val) do
    Process.put(ref, val)
    track_alloc()
  end

  def put_obj_key(ref, key, val), do: put_obj_key(ref, get_obj_raw(ref), key, val)

  def put_obj_key(ref, {:shape, shape_id, offsets, vals, proto}, key, val) do
    case Map.fetch(offsets, key) do
      {:ok, offset} ->
        new_vals = Shapes.put_val(vals, offset, val)
        Process.put(ref, {:shape, shape_id, offsets, new_vals, proto})

      :error ->
        {new_shape_id, new_offsets, offset} = Shapes.transition(shape_id, key)
        new_vals = Shapes.put_val(vals, offset, val)
        Process.put(ref, {:shape, new_shape_id, new_offsets, new_vals, proto})
    end
  end

  def put_obj_key(ref, map, key, val) when is_map(map) do
    new_map =
      if not Map.has_key?(map, key) and (is_binary(key) or is_integer(key)) do
        order = Map.get(map, key_order(), [])
        Map.put(Map.put(map, key, val), key_order(), [key | order])
      else
        Map.put(map, key, val)
      end

    Process.put(ref, new_map)
  end

  def put_obj_key(ref, _other, key, val) do
    Process.put(ref, %{key => val})
  end

  def update_obj(ref, default, fun) do
    current = Process.get(ref, default)

    current_map =
      case current do
        {:shape, shape_id, _offsets, vals, proto} -> Shapes.to_map(shape_id, vals, proto)
        other -> other
      end

    result = fun.(current_map)
    Process.put(ref, result)
  end

  # ── Array helpers ──

  def obj_is_array?(ref) do
    case Process.get(ref) do
      {:qb_arr, _} -> true
      _ -> false
    end
  end

  def obj_to_list(ref) do
    case Process.get(ref) do
      {:qb_arr, arr} -> :array.to_list(arr)
      list when is_list(list) -> list
      _ -> []
    end
  end

  def array_get(ref, idx) do
    case Process.get(ref) do
      {:qb_arr, arr} when idx >= 0 ->
        if idx < :array.size(arr), do: :array.get(idx, arr), else: :undefined

      _ ->
        :undefined
    end
  end

  def array_size(ref) do
    case Process.get(ref) do
      {:qb_arr, arr} -> :array.size(arr)
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  def array_push(ref, values) do
    case Process.get(ref) do
      {:qb_arr, arr} ->
        new_arr =
          Enum.reduce(values, {:array.size(arr), arr}, fn value, {idx, array} ->
            {idx + 1, :array.set(idx, value, array)}
          end)
          |> elem(1)

        Process.put(ref, {:qb_arr, new_arr})
        :array.size(new_arr)

      _ ->
        0
    end
  end

  def array_set(ref, idx, val) do
    case Process.get(ref) do
      {:qb_arr, arr} -> Process.put(ref, {:qb_arr, :array.set(idx, val, arr)})
      _ -> :ok
    end
  end

  # ── Closure cells ──

  def get_cell(ref), do: Process.get({:qb_cell, ref}, :undefined)
  def put_cell(ref, val), do: Process.put({:qb_cell, ref}, val)

  # ── Class metadata ──

  def get_class_proto({:closure, _, raw} = ctor),
    do: Process.get({:qb_class_proto, ctor}) || Process.get({:qb_class_proto, raw})

  def get_class_proto(ctor), do: Process.get({:qb_class_proto, ctor})
  def put_class_proto(ctor, proto), do: Process.put({:qb_class_proto, ctor}, proto)

  def get_parent_ctor({:closure, _, raw} = ctor),
    do: Process.get({:qb_parent_ctor, ctor}) || Process.get({:qb_parent_ctor, raw})

  def get_parent_ctor(ctor), do: Process.get({:qb_parent_ctor, ctor})
  def put_parent_ctor(ctor, parent), do: Process.put({:qb_parent_ctor, ctor}, parent)
  def delete_parent_ctor(ctor), do: Process.delete({:qb_parent_ctor, ctor})

  def get_ctor_statics(ctor), do: Process.get({:qb_ctor_statics, ctor}, %{})
  def put_ctor_statics(ctor, statics), do: Process.put({:qb_ctor_statics, ctor}, statics)

  def put_ctor_static({:closure, _, _} = ctor, "prototype", {:obj, _} = val) do
    statics = get_ctor_statics(ctor)
    put_ctor_statics(ctor, Map.put(statics, "prototype", val))
    Process.put({:qb_class_proto, ctor}, val)
  end

  def put_ctor_static(
        %{__struct__: QuickBEAM.VM.Bytecode.Function} = ctor,
        "prototype",
        {:obj, _} = val
      ) do
    statics = get_ctor_statics(ctor)
    put_ctor_statics(ctor, Map.put(statics, "prototype", val))
    Process.put({:qb_class_proto, ctor}, val)
  end

  def put_ctor_static(ctor, key, val) do
    statics = get_ctor_statics(ctor)
    put_ctor_statics(ctor, Map.put(statics, key, val))
  end

  def get_var(name), do: Process.get({:qb_var, name})
  def put_var(name, val), do: Process.put({:qb_var, name}, val)
  def delete_var(name), do: Process.delete({:qb_var, name})

  def frozen?(ref) do
    Process.get(:qb_has_frozen, false) and Process.get({:qb_frozen, ref}, false)
  end

  def freeze(ref) do
    Process.put(:qb_has_frozen, true)
    Process.put({:qb_frozen, ref}, true)
  end

  def get_prop_desc(ref, key), do: Process.get({:qb_prop_desc, ref, key})
  def put_prop_desc(ref, key, desc), do: Process.put({:qb_prop_desc, ref, key}, desc)

  # ── Object ID allocation ──

  def next_id, do: :erlang.unique_integer([:positive, :monotonic])

  defp track_alloc do
    count = Process.get(:qb_alloc_count, 0) + 1
    Process.put(:qb_alloc_count, count)

    if count >= Process.get(:qb_gc_threshold, QuickBEAM.VM.Heap.gc_initial_threshold()) do
      Process.put(:qb_gc_needed, true)
    end
  end
end
