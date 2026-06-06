defmodule QuickBEAM.VM.Heap.Store do
  @moduledoc "Low-level process-dictionary storage for JS heap objects: objects, arrays, cells, atoms, and GC roots."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap.{Arrays, Shapes}
  alias QuickBEAM.VM.Value

  # ── Raw storage (bypasses shape→map reconstruction) ──

  @doc "Returns raw heap storage for an object reference without shape reconstruction."
  def get_obj_raw(ref), do: Process.get(ref)
  def put_obj_raw(ref, val), do: Process.put(ref, val)

  def shape?({:shape, _shape_id, _offsets, _vals, _proto}), do: true
  def shape?(_), do: false

  def shape_offsets({:shape, _shape_id, offsets, _vals, _proto}), do: offsets
  def shape_offsets(_), do: %{}

  def shape_proto({:shape, _shape_id, _offsets, _vals, proto}), do: proto
  def shape_proto(_), do: nil

  def shape_keys({:shape, shape_id, _offsets, _vals, _proto}), do: Shapes.keys(shape_id)
  def shape_keys(_), do: []

  def shape_to_map({:shape, shape_id, _offsets, vals, proto}),
    do: Shapes.to_map(shape_id, vals, proto)

  def shape_to_map(other), do: other

  def raw_fetch({:shape, _shape_id, offsets, vals, _proto}, key) do
    case Map.fetch(offsets, key) do
      {:ok, offset} -> {:ok, elem(vals, offset)}
      :error -> :error
    end
  end

  def raw_fetch(map, key) when is_map(map), do: Map.fetch(map, key)
  def raw_fetch(_raw, _key), do: :error

  def raw_has_key?(raw, key), do: match?({:ok, _}, raw_fetch(raw, key))

  def raw_proto(raw) when is_tuple(raw), do: shape_proto(raw)

  def raw_proto(map) when is_map(map) do
    if Map.has_key?(map, :__internal_proto__),
      do: Map.get(map, :__internal_proto__),
      else: Map.get(map, proto())
  end

  def raw_proto(_raw), do: nil

  def raw_accessor_setter(raw, key) do
    case raw_fetch(raw, key) do
      {:ok, {:accessor, _getter, setter}} when setter != nil -> {:ok, setter}
      _ -> :error
    end
  end

  def raw_getter_only?(raw, key) do
    case raw_fetch(raw, key) do
      {:ok, {:accessor, getter, nil}} when getter != nil -> true
      _ -> false
    end
  end

  def raw_accessor?(raw, key) do
    case raw_fetch(raw, key) do
      {:ok, {:accessor, _, _}} -> true
      _ -> false
    end
  end

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

  @doc "Helper for low-level process-dictionary storage for js heap objects: objects, arrays, cells, atoms, and gc roots."
  def put_obj(ref, list) when is_list(list) do
    Process.put(ref, {:qb_arr, :array.from_list(list, :undefined)})
    track_alloc()
  end

  def put_obj(ref, val) do
    Process.put(ref, val)
    track_alloc()
  end

  @doc "Writes one key into object storage while preserving shape metadata when possible."
  def put_obj_key(ref, key, val), do: put_obj_key(ref, get_obj_raw(ref), key, val)

  @doc "Updates the prototype slot of a shape-backed object."
  def put_shape_proto(ref, proto) do
    case get_obj_raw(ref) do
      {:shape, shape_id, offsets, vals, _old_proto} ->
        Process.put(ref, {:shape, shape_id, offsets, vals, proto})
        :ok

      _ ->
        :error
    end
  end

  def put_obj_key(ref, {:shape, shape_id, offsets, vals, proto} = raw, key, val) do
    if is_binary(key) do
      case Map.fetch(offsets, key) do
        {:ok, offset} ->
          new_vals = Shapes.put_val(vals, offset, val)
          Process.put(ref, {:shape, shape_id, offsets, new_vals, proto})

        :error ->
          {new_shape_id, new_offsets, offset} = Shapes.transition(shape_id, key)
          new_vals = Shapes.put_val(vals, offset, val)
          Process.put(ref, {:shape, new_shape_id, new_offsets, new_vals, proto})
      end
    else
      Process.put(ref, put_property_preserving_order(shape_to_map(raw), key, val))
    end
  end

  def put_obj_key(ref, map, key, val) when is_map(map) do
    Process.put(ref, put_property_preserving_order(map, key, val))
  end

  def put_obj_key(ref, _other, key, val) do
    Process.put(ref, %{key => val})
  end

  def put_property_preserving_order(map, key, val) do
    if not Map.has_key?(map, key) and
         (is_binary(key) or is_integer(key) or Value.symbol?(key)) do
      order = Map.get(map, key_order(), [])
      Map.put(Map.put(map, key, val), key_order(), [key | order])
    else
      Map.put(map, key, val)
    end
  end

  @doc "Updates heap object data with a function after reconstructing shaped objects as maps."
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

  @doc "Returns whether a heap object reference stores array data."
  def obj_is_array?(ref) do
    case Process.get(ref) do
      {:qb_arr, _} -> true
      _ -> false
    end
  end

  def obj_to_list(ref) do
    case Process.get(ref) do
      {:qb_arr, _} = arr -> Arrays.to_list(arr)
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Reads an element from heap array storage by object reference."
  def array_get(ref, idx) do
    case Process.get(ref) do
      {:qb_arr, _} = arr when idx >= 0 -> Arrays.get(arr, idx)
      _ -> :undefined
    end
  end

  def array_size(ref) do
    case Process.get(ref) do
      {:qb_arr, arr} -> :array.size(arr)
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  @doc "Appends values to heap array storage and returns the new length."
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

  @doc "Writes an element in heap array storage by object reference."
  def array_set(ref, idx, val) do
    case Process.get(ref) do
      {:qb_arr, arr} -> Process.put(ref, {:qb_arr, :array.set(idx, val, arr)})
      _ -> :ok
    end
  end

  # ── Closure cells ──

  @doc "Reads a closure/capture cell value."
  def get_cell(ref), do: Process.get({:qb_cell, ref}, :undefined)
  def put_cell(ref, val), do: Process.put({:qb_cell, ref}, val)

  # ── Class metadata ──

  def get_class_proto(ctor), do: Process.get({:qb_class_proto, ctor_key(ctor)})
  @doc "Stores the prototype object associated with a constructor."
  def put_class_proto(ctor, proto), do: Process.put({:qb_class_proto, ctor_key(ctor)}, proto)

  def get_parent_ctor(ctor), do: Process.get({:qb_parent_ctor, ctor_key(ctor)})
  def put_parent_ctor(ctor, parent), do: Process.put({:qb_parent_ctor, ctor_key(ctor)}, parent)
  def delete_parent_ctor(ctor), do: Process.delete({:qb_parent_ctor, ctor_key(ctor)})

  @doc "Returns static properties associated with a constructor value."
  def get_ctor_statics(ctor), do: Process.get({:qb_ctor_statics, ctor_key(ctor)}, %{})

  def put_ctor_statics(ctor, statics),
    do: Process.put({:qb_ctor_statics, ctor_key(ctor)}, statics)

  def put_ctor_static({:closure, _, _} = ctor, "prototype", {:obj, _} = val) do
    statics = get_ctor_statics(ctor)
    put_ctor_statics(ctor, Map.put(statics, "prototype", val))
    Process.put({:qb_class_proto, ctor_key(ctor)}, val)
  end

  def put_ctor_static(
        %{__struct__: QuickBEAM.VM.Function} = ctor,
        "prototype",
        {:obj, _} = val
      ) do
    statics = get_ctor_statics(ctor)
    put_ctor_statics(ctor, Map.put(statics, "prototype", val))
    Process.put({:qb_class_proto, ctor_key(ctor)}, val)
  end

  def put_ctor_static(ctor, key, val) do
    statics = get_ctor_statics(ctor)
    put_ctor_statics(ctor, Map.put(statics, key, val))
  end

  def delete_ctor_static(ctor, key) do
    statics = get_ctor_statics(ctor)
    put_ctor_statics(ctor, Map.delete(statics, key))
  end

  defp ctor_key({:closure, _captured, %QuickBEAM.VM.Function{} = fun}), do: ctor_key(fun)

  defp ctor_key(%QuickBEAM.VM.Function{id: id}) when is_integer(id), do: {:function, id}

  defp ctor_key(%QuickBEAM.VM.Function{} = fun), do: {:function, :erlang.phash2(fun)}
  defp ctor_key(ctor), do: ctor

  @doc "Reads a process-local VM variable slot."
  def get_var(name), do: Process.get({:qb_var, name})
  def put_var(name, val), do: Process.put({:qb_var, name}, val)
  def delete_var(name), do: Process.delete({:qb_var, name})

  def frozen?(ref) do
    Process.get(:qb_has_frozen, false) and Process.get({:qb_frozen, ref}, false)
  end

  @doc "Marks a heap object as frozen."
  def freeze(ref) do
    Process.put(:qb_has_frozen, true)
    Process.put({:qb_frozen, ref}, true)
    prevent_extensions(ref)
  end

  def extensible?(ref) do
    not (Process.get(:qb_has_non_extensible, false) and
           Process.get({:qb_non_extensible, ref}, false))
  end

  def prevent_extensions(ref) do
    Process.put(:qb_has_non_extensible, true)
    Process.put({:qb_non_extensible, ref}, true)
  end

  def get_prop_desc(ref, key), do: Process.get({:qb_prop_desc, ref, key})

  def put_prop_desc(ref, key, desc) do
    Process.put({:qb_prop_desc, ref, key}, desc)
    Process.put({:qb_prop_desc_index, ref}, Map.put(prop_desc_index(ref), key, desc))
  end

  def delete_prop_desc(ref, key) do
    Process.delete({:qb_prop_desc, ref, key})
    Process.put({:qb_prop_desc_index, ref}, Map.delete(prop_desc_index(ref), key))
  end

  def prop_desc_values(ref), do: Map.values(prop_desc_index(ref))

  defp prop_desc_index(ref), do: Process.get({:qb_prop_desc_index, ref}, %{})

  def get_ctor_prop_desc(ctor, key), do: Process.get({:qb_ctor_prop_desc, ctor_key(ctor), key})

  def get_ctor_prop_descs(ctor), do: ctor_prop_desc_index(ctor_key(ctor))

  def put_ctor_prop_desc(ctor, key, desc) do
    owner = ctor_key(ctor)
    Process.put({:qb_ctor_prop_desc, owner, key}, desc)

    Process.put(
      {:qb_ctor_prop_desc_index, owner},
      Map.put(ctor_prop_desc_index(owner), key, desc)
    )
  end

  def delete_ctor_prop_desc(ctor, key) do
    owner = ctor_key(ctor)
    Process.delete({:qb_ctor_prop_desc, owner, key})

    Process.put(
      {:qb_ctor_prop_desc_index, owner},
      Map.delete(ctor_prop_desc_index(owner), key)
    )
  end

  def ctor_prop_desc_values(owner), do: Map.values(ctor_prop_desc_index(owner))

  defp ctor_prop_desc_index(owner), do: Process.get({:qb_ctor_prop_desc_index, owner}, %{})

  def get_array_props(ref), do: Process.get({:qb_array_props, ref}, %{})

  def get_array_prop(ref, key), do: Map.get(get_array_props(ref), key, :undefined)

  def put_array_prop(ref, key, val) do
    Process.put(
      {:qb_array_props, ref},
      put_property_preserving_order(get_array_props(ref), key, val)
    )
  end

  def delete_array_prop(ref, key) do
    Process.put({:qb_array_props, ref}, Map.delete(get_array_props(ref), key))
  end

  # ── Object ID allocation ──

  @doc "Allocates a new monotonically increasing heap object id."
  def next_id, do: :erlang.unique_integer([:positive, :monotonic])

  defp track_alloc do
    count = Process.get(:qb_alloc_count, 0) + 1
    Process.put(:qb_alloc_count, count)

    if count >= Process.get(:qb_gc_threshold, QuickBEAM.VM.Heap.gc_initial_threshold()) do
      Process.put(:qb_gc_needed, true)
    end
  end
end
