defmodule QuickBEAM.VM.Heap.Shapes do
  @moduledoc """
  Hidden-class shape tracking for plain JS objects.

  When objects are created with a consistent set of property names,
  they share a "shape" that maps each property name to a fixed tuple
  offset.  Property access becomes O(1) tuple indexing instead of
  O(log n) map lookup.

  Shape-backed objects are stored as
      {:shape, shape_id, offsets_map, values_tuple, proto_ref}
  in the process dictionary under the object's integer ID key.

  Objects that gain accessors, internal keys, or otherwise become
  non-plain deopt back to regular maps.
  """

  @empty_shape 0

  # ── Shape registry (per-process) ──

  defp shape_table do
    case Process.get(:qb_shape_table) do
      nil ->
        empty = %{
          keys: [],
          offsets: %{},
          parent_id: nil,
          transitions: %{}
        }

        table = {empty}
        Process.put(:qb_shape_table, table)
        table

      table ->
        table
    end
  end

  defp next_shape_id do
    tuple_size(shape_table())
  end

  def get_shape(id) do
    elem(shape_table(), id)
  end

  defp put_shape(id, shape) do
    table = shape_table()

    new_table =
      if id == tuple_size(table) do
        :erlang.append_element(table, shape)
      else
        put_elem(table, id, shape)
      end

    Process.put(:qb_shape_table, new_table)
  end

  # ── Public API ──

  def empty_shape_id, do: @empty_shape

  @doc "Return the offset for `key` in `shape_id`, or `:error`."
  def lookup(shape_id, key) do
    shape = get_shape(shape_id)
    Map.fetch(shape.offsets, key)
  end

  @doc "Return the ordered list of keys for `shape_id`."
  def keys(shape_id) do
    get_shape(shape_id).keys
  end

  @doc """
  Transition `shape_id` by adding `key`.
  Returns `{new_shape_id, offset}`.
  """
  def transition(shape_id, key) do
    shape = get_shape(shape_id)
    offset = map_size(shape.offsets)

    case Map.get(shape.transitions, key) do
      nil ->
        new_id = next_shape_id()
        new_offsets = Map.put(shape.offsets, key, offset)

        new_shape = %{
          keys: shape.keys ++ [key],
          offsets: new_offsets,
          parent_id: shape_id,
          transitions: %{}
        }

        put_shape(new_id, new_shape)

        put_shape(shape_id, %{
          shape
          | transitions: Map.put(shape.transitions, key, {new_id, new_offsets})
        })

        {new_id, new_offsets, offset}

      {child_id, child_offsets} ->
        {child_id, child_offsets, offset}
    end
  end

  @doc """
  Convert a plain map (without `__proto__`) into a shape and values tuple.
  Returns `{:ok, shape_id, values_tuple}` or `:ineligible`.
  """
  def from_map(map) when is_map(map) and map_size(map) == 0 do
    {:ok, @empty_shape, %{}, {}}
  end

  def from_map(map) when is_map(map) do
    case resolve_shape_for_map(map) do
      {shape_id, offsets} ->
        vals =
          offsets
          |> Enum.sort_by(fn {_k, offset} -> offset end)
          |> Enum.map(fn {k, _offset} -> Map.get(map, k) end)
          |> :erlang.list_to_tuple()

        {:ok, shape_id, offsets, vals}

      :ineligible ->
        :ineligible
    end
  end

  def from_map(_), do: :ineligible

  defp resolve_shape_for_map(map) do
    size = map_size(map)
    cache_key = {:qb_shape_cache, size, :erlang.phash2(:maps.keys(map))}

    case Process.get(cache_key) do
      nil ->
        case build_shape(map) do
          :ineligible ->
            :ineligible

          shape_id ->
            offsets = get_shape(shape_id).offsets
            Process.put(cache_key, {shape_id, offsets})
            {shape_id, offsets}
        end

      result ->
        result
    end
  end

  defp build_shape(map) do
    keys = :maps.keys(map)

    if Enum.all?(keys, &(is_binary(&1) and not internal_key?(&1))) and
         Enum.all?(:maps.values(map), &simple_value?/1) do
      # For flatmaps, keys are already sorted
      {shape_id, _, _} =
        Enum.reduce(keys, {@empty_shape, %{}, 0}, fn key, {sid, _, _} ->
          transition(sid, key)
        end)

      shape_id
    else
      :ineligible
    end
  end

  @doc "Reconstruct a plain map from a shape-backed representation."
  def to_map(shape_id, vals, proto) do
    keys = keys(shape_id)
    map = keys_vals_to_map(keys, vals, 0, %{})
    if proto, do: Map.put(map, "__proto__", proto), else: map
  end

  defp keys_vals_to_map([], _vals, _idx, acc), do: acc

  defp keys_vals_to_map([k | ks], vals, idx, acc),
    do: keys_vals_to_map(ks, vals, idx + 1, Map.put(acc, k, elem(vals, idx)))

  @doc "Check whether a stored heap value is shape-backed."
  def shape?({:shape, _, _, _, _}), do: true
  def shape?(_), do: false

  @doc "Grow or update a values tuple at `offset`."
  def put_val(vals, offset, val) when offset < tuple_size(vals) do
    put_elem(vals, offset, val)
  end

  def put_val(vals, offset, val) when offset == tuple_size(vals) do
    :erlang.append_element(vals, val)
  end

  def put_val(vals, offset, val) do
    padding = offset - tuple_size(vals)

    padded =
      Enum.reduce(1..padding, vals, fn _, acc -> :erlang.append_element(acc, :undefined) end)

    :erlang.append_element(padded, val)
  end

  # ── Eligibility ──

  defp internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__") and byte_size(key) > 2

  defp internal_key?(_), do: false

  defp simple_value?({:accessor, _, _}), do: false
  defp simple_value?({:symbol, _, _}), do: false
  defp simple_value?({:symbol, _}), do: false
  defp simple_value?(_), do: true
end
