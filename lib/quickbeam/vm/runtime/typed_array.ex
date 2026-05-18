defmodule QuickBEAM.VM.Runtime.TypedArray do
  @moduledoc "JS TypedArray built-ins: constructors and prototype methods for all numeric array types (Uint8Array through Float64Array)."

  import QuickBEAM.VM.Heap.Keys

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Array
  alias QuickBEAM.VM.Semantics.Iterators

  @types %{
    "Uint8Array" => :uint8,
    "Int8Array" => :int8,
    "Uint8ClampedArray" => :uint8_clamped,
    "Uint16Array" => :uint16,
    "Int16Array" => :int16,
    "Uint32Array" => :uint32,
    "Int32Array" => :int32,
    "Float32Array" => :float32,
    "Float64Array" => :float64,
    "Float16Array" => :float16,
    "BigInt64Array" => :bigint64,
    "BigUint64Array" => :biguint64
  }

  @doc "Returns typed-array type descriptors supported by the runtime."
  def types, do: @types

  @doc "Returns the byte width for a typed-array element type."
  def elem_size(:uint8), do: 1
  def elem_size(:int8), do: 1
  def elem_size(:uint8_clamped), do: 1
  def elem_size(:uint16), do: 2
  def elem_size(:int16), do: 2
  def elem_size(:uint32), do: 4
  def elem_size(:int32), do: 4
  def elem_size(:float16), do: 2
  def elem_size(:float32), do: 4
  def elem_size(:float64), do: 8
  def elem_size(:bigint64), do: 8
  def elem_size(:biguint64), do: 8

  @doc "Returns generic properties for typed-array constructor prototype objects."
  def prototype_properties do
    %{
      "at" => prototype_method("at", 1, fn args, this -> at(this, args) end),
      "copyWithin" => prototype_ref_method("copyWithin", 2, &copy_within/3),
      "entries" =>
        prototype_method("entries", 0, fn _args, this ->
          this = typed_array_object!(this)
          Array.make_array_iterator(this, :entries)
        end),
      "keys" =>
        prototype_method("keys", 0, fn _args, this ->
          this = typed_array_object!(this)
          Array.make_array_iterator(this, :keys)
        end),
      "values" =>
        prototype_method("values", 0, fn _args, this ->
          this = typed_array_object!(this)
          Array.make_array_iterator(this, :values)
        end),
      {:symbol, "Symbol.iterator"} =>
        prototype_method("values", 0, fn _args, this ->
          this = typed_array_object!(this)
          Array.make_array_iterator(this, :values)
        end),
      "every" => prototype_ref_method("every", 1, &every/3),
      "fill" => prototype_ref_method("fill", 1, fn ref, args, _this -> fill(ref, args) end),
      "filter" => prototype_ref_method("filter", 1, &filter/3),
      "find" => prototype_ref_method("find", 1, &find/3),
      "forEach" => prototype_ref_method("forEach", 1, &for_each/3),
      "includes" => prototype_ref_method("includes", 1, fn ref, args, _this -> includes(ref, args) end),
      "indexOf" => prototype_ref_method("indexOf", 1, fn ref, args, _this -> index_of(ref, args) end),
      "join" => prototype_ref_method("join", 1, fn ref, args, _this -> join(ref, args) end),
      "map" => prototype_ref_method("map", 1, &map/3),
      "reduce" => prototype_ref_method("reduce", 1, &reduce/3),
      "reverse" => prototype_ref_method("reverse", 0, fn ref, _args, _this -> reverse(ref) end),
      "set" => prototype_ref_method("set", 1, fn ref, args, _this -> set(ref, args) end),
      "slice" => prototype_ref_method("slice", 2, fn ref, args, _this -> slice(ref, args) end),
      "some" => prototype_ref_method("some", 1, &some/3),
      "sort" => prototype_ref_method("sort", 1, fn ref, _args, _this -> sort(ref) end),
      "subarray" => prototype_ref_method("subarray", 2, fn ref, args, _this -> subarray(ref, args) end),
      "toString" => prototype_ref_method("toString", 0, fn ref, _args, _this -> join(ref, [","]) end)
    }
  end

  defp prototype_ref_method(name, length, callback) do
    prototype_method(name, length, fn args, this ->
      {:obj, ref} = typed_array_object!(this)
      callback.(ref, args, this)
    end)
  end

  defp prototype_method(name, length, callback) do
    method = {:builtin, name, callback}
    Heap.put_ctor_static(method, "length", length)
    Heap.put_ctor_static(method, "name", name)
    Heap.put_ctor_prop_desc(method, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(method, "name", PropertyDescriptor.hidden_readonly())
    method
  end

  @doc "Returns properties installed on %TypedArray%.prototype."
  def base_prototype_properties do
    Map.merge(prototype_properties(), %{
      "buffer" => {:accessor, accessor_getter("get buffer", &prototype_buffer/1), nil},
      "byteLength" =>
        {:accessor, accessor_getter("get byteLength", &prototype_byte_length/1), nil},
      "byteOffset" =>
        {:accessor, accessor_getter("get byteOffset", &prototype_byte_offset/1), nil},
      {:symbol, "Symbol.toStringTag"} =>
        {:accessor, accessor_getter("get [Symbol.toStringTag]", &prototype_to_string_tag/1), nil}
    })
  end

  defp accessor_getter(name, callback) do
    getter = {:builtin, name, fn _args, this -> callback.(this) end}
    Heap.put_ctor_static(getter, "length", 0)
    Heap.put_ctor_prop_desc(getter, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(getter, "name", PropertyDescriptor.hidden_readonly())
    getter
  end

  defp prototype_buffer(this), do: typed_array_state!(this) |> Map.get("buffer", :undefined)

  defp prototype_byte_length(this) do
    obj = typed_array_object!(this)
    if out_of_bounds?(obj), do: 0, else: current_byte_length(obj)
  end

  defp prototype_byte_offset(this) do
    obj = typed_array_object!(this)
    if out_of_bounds?(obj), do: 0, else: Map.get(typed_array_state!(obj), "byteOffset", 0)
  end

  defp prototype_to_string_tag({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true, type_key() => type} -> typed_array_name(type)
      _ -> :undefined
    end
  end

  defp prototype_to_string_tag(_), do: :undefined

  defp typed_array_object!({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} -> obj
      _ -> JSThrow.type_error!("TypedArray expected")
    end
  end

  defp typed_array_object!(_), do: JSThrow.type_error!("TypedArray expected")

  defp typed_array_state!(obj) do
    {:obj, ref} = typed_array_object!(obj)
    Heap.get_obj(ref, %{})
  end

  def static_from(args, constructor) do
    {source, map_fn, this_arg} = from_args(args)
    values = typed_array_from_values(source, map_fn, this_arg)
    Invocation.construct_runtime(constructor, constructor, [values])
  end

  def static_of(args, constructor) do
    Invocation.construct_runtime(constructor, constructor, [args])
  end

  defp from_args([source, map_fn, this_arg | _]) when map_fn not in [nil, :undefined],
    do: {source, map_fn, this_arg}

  defp from_args([source, map_fn | _]) when map_fn not in [nil, :undefined],
    do: {source, map_fn, :undefined}

  defp from_args([source | _]), do: {source, nil, :undefined}
  defp from_args(_), do: {nil, nil, :undefined}

  defp typed_array_from_values(nil, _map_fn, _this_arg),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp typed_array_from_values(:undefined, _map_fn, _this_arg),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp typed_array_from_values(source, map_fn, this_arg) do
    if map_fn not in [nil, :undefined] and not QuickBEAM.VM.Builtin.callable?(map_fn) do
      JSThrow.type_error!("mapfn is not callable")
    end

    source
    |> typed_array_source_values()
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      if map_fn in [nil, :undefined] do
        value
      else
        Invocation.invoke_with_receiver(map_fn, [value, index], this_arg)
      end
    end)
  end

  defp typed_array_source_values(source) do
    iterator = Get.get(source, {:symbol, "Symbol.iterator"})

    cond do
      QuickBEAM.VM.Builtin.callable?(iterator) ->
        Iterators.iterable_to_list(source)

      iterator not in [nil, :undefined] ->
        JSThrow.type_error!("@@iterator is not callable")

      true ->
        len = max(Runtime.to_int(Get.get(source, "length")), 0)

        if len == 0 do
          []
        else
          for index <- 0..(len - 1), do: Get.get(source, Integer.to_string(index))
        end
    end
  end

  defp typed_array_name(type) do
    @types
    |> Enum.find_value(fn {name, candidate} -> if candidate == type, do: name end)
    |> Kernel.||("TypedArray")
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor(type) do
    fn args, _this ->
      {buf, offset, len, orig_buf, length_tracking?} = parse_args(args, type)
      ref = make_ref()

      methods =
        object heap: false do
          method("set", do: set(ref, args))
          method("subarray", do: subarray(ref, args))
          method("at", do: at({:obj, ref}, args))
          method("copyWithin", do: copy_within(ref, args, this))
          method("join", do: join(ref, args))
          method("forEach", do: for_each(ref, args, this))
          method("map", do: map(ref, args, this))
          method("filter", do: filter(ref, args, this))
          method("every", do: every(ref, args, this))
          method("some", do: some(ref, args, this))
          method("reduce", do: reduce(ref, args, this))
          method("indexOf", do: index_of(ref, args))
          method("includes", do: includes(ref, args))
          method("find", do: find(ref, args, this))
          method("sort", do: sort(ref))
          method("reverse", do: reverse(ref))
          method("slice", do: slice(ref, args))
          method("fill", do: fill(ref, args))
          method("toString", do: join(ref, [","]))
        end

      sym_iter = {:symbol, "Symbol.iterator"}

      obj =
        Map.merge(methods, %{
          typed_array() => true,
          type_key() => type,
          buffer() => buf,
          offset() => offset,
          "length" => len,
          "byteLength" => len * elem_size(type),
          "byteOffset" => offset,
          "BYTES_PER_ELEMENT" => elem_size(type),
          "__length_tracking__" => length_tracking?,
          "__fixed_length__" => len,
          "__fixed_byte_length__" => len * elem_size(type),
          "buffer" => orig_buf || make_buffer_ref(buf),
          "entries" =>
            {:builtin, "entries", fn _, this -> Array.make_array_iterator(this, :entries) end},
          "keys" => {:builtin, "keys", fn _, this -> Array.make_array_iterator(this, :keys) end},
          "values" =>
            {:builtin, "values", fn _, this -> Array.make_array_iterator(this, :values) end},
          sym_iter =>
            {:builtin, "[Symbol.iterator]",
             fn _, this -> Array.make_array_iterator(this, :values) end}
        })

      Heap.put_obj(ref, obj)
      register_buffer_view(orig_buf, ref)
      {:obj, ref}
    end
  end

  defp register_buffer_view({:obj, buf_ref}, view_ref) do
    case Heap.get_obj(buf_ref, %{}) do
      map when is_map(map) ->
        Heap.put_obj(buf_ref, Map.update(map, "__views__", [view_ref], &[view_ref | &1]))

      _ ->
        :ok
    end
  end

  defp register_buffer_view(_, _), do: :ok

  # ── Element access (public, used by ObjectModel.Put) ──

  @doc "Returns whether a typed-array object is backed by immutable data."
  def immutable?({:obj, ref}) do
    is_immutable_buffer?(Heap.get_obj(ref, %{}))
  end

  @doc "Reads an element from a typed-array value."
  def get_element({:obj, ref}, idx) do
    b = buf(ref)
    if b == nil, do: :undefined, else: read_element(b, idx, type(ref))
  end

  @doc "Returns whether a typed-array view is currently out of bounds."
  def out_of_bounds?({:obj, ref}) do
    s = state(ref)

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          %{"__detached__" => true} ->
            true

          m when is_map(m) ->
            byte_len = byte_size(Map.get(m, buffer(), Map.get(s, buffer(), <<>>)))
            offset = Map.get(s, "byteOffset", 0)

            if Map.get(s, "__length_tracking__") do
              byte_len < offset
            else
              fixed = Map.get(s, "__fixed_byte_length__", Map.get(s, "byteLength", 0))
              max(byte_len - offset, 0) < fixed
            end

          _ ->
            false
        end

      _ ->
        false
    end
  end

  def out_of_bounds?(_), do: false

  @doc "Returns the currently addressable element count for a typed-array value."
  def element_count({:obj, ref}) do
    s = state(ref)

    if Map.get(s, "__length_tracking__") do
      div(max(byte_size(buf(ref) || <<>>), 0), elem_size(type(ref)))
    else
      Map.get(s, "length", 0)
    end
  end

  @doc "Returns the currently addressable byte length for a typed-array value."
  def current_byte_length({:obj, ref}) do
    element_count({:obj, ref}) * elem_size(type(ref))
  end

  @doc "Writes an element to a typed-array value."
  def set_element({:obj, ref}, idx, val) do
    ta = Heap.get_obj(ref, %{})

    if Map.get(ta, "__immutable__") || is_immutable_buffer?(ta) do
      :ok
    else
      t = Map.get(ta, type_key(), :uint8)
      new_buf = write_element(buf(ref) || <<>>, idx, val, t)
      update_buffer(ref, new_buf)
      delete_shadowed_views(ref, idx)
    end
  end

  defp delete_shadowed_views(ref, idx) do
    case Heap.get_obj(ref, %{}) do
      %{"buffer" => {:obj, buf_ref}} ->
        case Heap.get_obj(buf_ref, %{}) do
          %{"__views__" => views} when is_list(views) ->
            Enum.each(views, fn view_ref ->
              view = Heap.get_obj(view_ref, %{})
              offset = Map.get(view, "byteOffset", 0)
              elem_size = Map.get(view, "BYTES_PER_ELEMENT", 1)

              if rem(offset, elem_size) == 0 do
                view_idx = idx - div(offset, elem_size)

                if view_idx >= 0 do
                  Heap.delete_array_prop(view_ref, Integer.to_string(view_idx))
                end
              end
            end)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_immutable_buffer?(ta) do
    case Map.get(ta, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          m when is_map(m) -> Map.get(m, "__immutable__", false)
          _ -> false
        end

      _ ->
        false
    end
  end

  # ── State readers ──

  defp state(ref), do: Heap.get_obj(ref, %{})

  defp buf(ref) do
    s = state(ref)

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          m when is_map(m) ->
            if Map.get(m, "__detached__") do
              nil
            else
              ab_buf = Map.get(m, buffer(), Map.get(s, buffer(), <<>>))
              offset = Map.get(s, "byteOffset", 0)
              byte_len = current_view_byte_length(s, ab_buf, offset)

              cond do
                byte_len == 0 ->
                  nil

                offset == 0 and byte_len == byte_size(ab_buf) ->
                  ab_buf

                offset + byte_len <= byte_size(ab_buf) ->
                  binary_part(ab_buf, offset, byte_len)

                offset < byte_size(ab_buf) ->
                  binary_part(ab_buf, offset, byte_size(ab_buf) - offset)

                true ->
                  nil
              end
            end

          _ ->
            Map.get(s, buffer(), <<>>)
        end

      _ ->
        Map.get(s, buffer(), <<>>)
    end
  end

  defp len(ref), do: element_count({:obj, ref})
  defp type(ref), do: Map.get(state(ref), type_key(), :uint8)

  defp current_view_byte_length(s, ab_buf, offset) do
    available = max(byte_size(ab_buf) - offset, 0)

    if Map.get(s, "__length_tracking__") do
      available
    else
      fixed = Map.get(s, "byteLength", available)
      if available < fixed, do: 0, else: fixed
    end
  end

  # ── Method implementations ──

  defp at(nil, _args),
    do: JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")

  defp at(:undefined, _args),
    do: JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")

  defp at({:obj, ref} = obj, args) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        if out_of_bounds?(obj) do
          JSThrow.type_error!("TypedArray is out of bounds")
        end

        len = element_count(obj)
        relative_index = args |> Enum.at(0, :undefined) |> to_integer_or_infinity()

        case relative_index do
          :infinity ->
            :undefined

          :neg_infinity ->
            :undefined

          index ->
            idx = if index < 0, do: len + index, else: index

            if idx < 0 or idx >= len do
              :undefined
            else
              get_element(obj, idx)
            end
        end

      _ ->
        JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")
    end
  end

  defp at(_, _args),
    do: JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")

  defp set(ref, args) do
    {source, offset} =
      case args do
        [s, o | _] when is_number(o) -> {s, trunc(o)}
        [s | _] -> {s, 0}
        _ -> {nil, 0}
      end

    src_list = Heap.to_list(source)
    t = type(ref)

    new_buf =
      src_list
      |> Enum.with_index(offset)
      |> Enum.reduce(buf(ref), fn {v, i}, acc -> write_element(acc, i, v, t) end)

    update_buffer(ref, new_buf)
    :undefined
  end

  defp subarray(ref, args) do
    l = len(ref)
    t = type(ref)
    s = max(0, min(to_idx(arg(args, 0, 0)), l))
    e = min(to_idx(arg(args, 1, l)), l)
    new_len = max(0, e - s)
    es = elem_size(t)

    Heap.wrap(%{
      typed_array() => true,
      type_key() => t,
      buffer() => binary_part(buf(ref), s * es, new_len * es),
      offset() => 0,
      "length" => new_len,
      "byteLength" => new_len * es,
      "byteOffset" => 0,
      "buffer" => Map.get(state(ref), "buffer")
    })
  end

  defp copy_within(ref, args, _this) do
    obj = {:obj, ref}

    if out_of_bounds?(obj) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end

    l = len(ref)
    target = relative_index(arg(args, 0, :undefined), l)
    start = relative_index(arg(args, 1, :undefined), l)

    final =
      case Enum.at(args, 2, :undefined) do
        :undefined -> l
        value -> relative_index(value, l)
      end

    count = min(final - start, l - target)

    if count > 0 do
      t = type(ref)
      b = buf(ref) || <<>>
      values = for i <- 0..(count - 1), do: read_element(b, start + i, t)

      new_buf =
        values
        |> Enum.with_index(target)
        |> Enum.reduce(b, fn {value, index}, acc -> write_element(acc, index, value, t) end)

      update_buffer(ref, new_buf)
    end

    obj
  end

  defp relative_index(value, len) do
    case to_integer_or_infinity(value) do
      :neg_infinity -> 0
      :infinity -> len
      index when index < 0 -> max(len + index, 0)
      index -> min(index, len)
    end
  end

  defp join(ref, args) do
    sep =
      case args do
        [s | _] when is_binary(s) -> s
        _ -> ","
      end

    {b, l, t} = {buf(ref), len(ref), type(ref)}
    Enum.map_join(0..max(0, l - 1), sep, &typed_array_join_value(read_element(b, &1, t)))
  end

  defp typed_array_join_value(:undefined), do: ""
  defp typed_array_join_value(nil), do: ""
  defp typed_array_join_value(value), do: Runtime.stringify(value)

  defp for_each(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    for i <- 0..(l - 1), do: call(cb, [read_element(b, i, t), i, this])
    :undefined
  end

  defp map(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    new_buf =
      Enum.reduce(0..(l - 1), b, fn i, acc ->
        write_element(acc, i, call(cb, [read_element(acc, i, t), i, this]), t)
      end)

    elements = for i <- 0..(l - 1), do: read_element(new_buf, i, t)
    constructor(t).([elements], nil)
  end

  defp filter(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    vals =
      for i <- 0..(l - 1),
          (
            v = read_element(b, i, t)
            Runtime.truthy?(call(cb, [v, i, this]))
          ),
          do: v

    constructor(t).([vals], nil)
  end

  defp every(ref, [cb | rest], this) do
    unless QuickBEAM.VM.Builtin.callable?(cb) do
      JSThrow.type_error!("callbackfn is not callable")
    end

    {b, l, t} = {buf(ref), len(ref), type(ref)}
    this_arg = arg(rest, 0, :undefined)

    l == 0 or
      Enum.all?(0..(l - 1), fn index ->
        cb
        |> Invocation.invoke_with_receiver([read_element(b, index, t), index, this], this_arg)
        |> Runtime.truthy?()
      end)
  end

  defp every(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp some(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    Enum.any?(0..max(0, l - 1), &Runtime.truthy?(call(cb, [read_element(b, &1, t), &1, this])))
  end

  defp reduce(ref, args, this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    cb = arg(args, 0, nil)
    init = arg(args, 1, nil)
    {start, acc} = if init != nil, do: {0, init}, else: {1, read_element(b, 0, t)}

    Enum.reduce(start..max(start, l - 1), acc, fn i, a ->
      call(cb, [a, read_element(b, i, t), i, this])
    end)
  end

  defp index_of(ref, [target | _]) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    Enum.find_value(0..max(0, l - 1), -1, fn i ->
      if read_element(b, i, t) == target, do: i
    end)
  end

  defp includes(ref, [target | _]) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    Enum.any?(0..max(0, l - 1), fn i -> read_element(b, i, t) == target end)
  end

  defp includes(_ref, _args), do: false

  defp find(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    Enum.find_value(0..max(0, l - 1), :undefined, fn i ->
      v = read_element(b, i, t)
      if Runtime.truthy?(call(cb, [v, i, this])), do: v
    end)
  end

  defp sort(ref) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    vals = Enum.map(0..max(0, l - 1), &read_element(b, &1, t)) |> Enum.sort()
    new_buf = rebuild_buffer(vals, b, t)
    update_buffer(ref, new_buf)
    {:obj, ref}
  end

  defp reverse(ref) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    vals = Enum.map(0..max(0, l - 1), &read_element(b, &1, t)) |> Enum.reverse()
    new_buf = rebuild_buffer(vals, b, t)
    update_buffer(ref, new_buf)
    {:obj, ref}
  end

  defp slice(ref, args) do
    l = len(ref)
    t = type(ref)
    s = max(0, to_idx(arg(args, 0, 0)))
    e = min(l, to_idx(arg(args, 1, l)))
    new_len = max(0, e - s)
    es = elem_size(t)
    new_buf = if new_len > 0, do: binary_part(buf(ref), s * es, new_len * es), else: <<>>

    species_ctor = get_species_ctor({:obj, ref})

    if species_ctor do
      result = Runtime.call_callback(species_ctor, [new_len])

      case result do
        {:obj, _result_ref} ->
          for i <- 0..(new_len - 1) do
            val = read_element(new_buf, i, t)
            set_element(result, i, val)
          end

        _ ->
          :ok
      end

      result
    else
      elements = for i <- 0..(new_len - 1), do: read_element(new_buf, i, t)
      constructor(t).([elements], nil)
    end
  end

  defp get_species_ctor({:obj, ref}) do
    map = Heap.get_obj(ref, %{})
    ctor = Map.get(map, "constructor")

    case ctor do
      {:obj, ctor_ref} ->
        ctor_map = Heap.get_obj(ctor_ref, %{})
        species = Map.get(ctor_map, {:symbol, "Symbol.species"})
        if species != nil, do: species, else: nil

      _ ->
        nil
    end
  end

  defp fill(ref, [val | _]) do
    {l, t} = {len(ref), type(ref)}
    new_buf = Enum.reduce(0..(l - 1), buf(ref) || <<>>, &write_element(&2, &1, val, t))
    update_buffer(ref, new_buf)
    {:obj, ref}
  end

  defp update_buffer(ref, new_buf) do
    s = state(ref)
    Heap.put_obj(ref, Map.put(s, buffer(), new_buf))

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        buf_map = Heap.get_obj(buf_ref, %{})

        if is_map(buf_map) do
          offset = Map.get(s, "byteOffset", 0)
          ab_buf = Map.get(buf_map, buffer(), <<>>)

          before =
            if offset > 0, do: binary_part(ab_buf, 0, min(offset, byte_size(ab_buf))), else: <<>>

          after_offset = offset + byte_size(new_buf)

          after_part =
            if after_offset < byte_size(ab_buf),
              do: binary_part(ab_buf, after_offset, byte_size(ab_buf) - after_offset),
              else: <<>>

          merged = before <> new_buf <> after_part
          Heap.put_obj(buf_ref, Map.put(buf_map, buffer(), merged))
        end

      _ ->
        :ok
    end
  end

  # ── Helpers ──

  defp decode_float16(bits) do
    sign = Bitwise.bsr(bits, 15) |> Bitwise.band(1)
    exp = Bitwise.bsr(bits, 10) |> Bitwise.band(0x1F)
    frac = Bitwise.band(bits, 0x3FF)
    s = if sign == 1, do: -1.0, else: 1.0

    cond do
      exp == 0 and frac == 0 -> s * 0.0
      exp == 0 -> s * frac * :math.pow(2, -24)
      exp == 31 and frac == 0 -> if(s == -1.0, do: :neg_infinity, else: :infinity)
      exp == 31 -> :nan
      true -> s * :math.pow(2, exp - 15) * (1 + frac / 1024)
    end
  end

  defp encode_float16(n) when n in [:nan, :NaN], do: 0x7E00
  defp encode_float16(:infinity), do: 0x7C00
  defp encode_float16(:neg_infinity), do: 0xFC00

  defp encode_float16(n) when is_number(n) do
    f = n * 1.0
    sign = if f < 0, do: 1, else: 0
    abs_f = abs(f)

    cond do
      abs_f == 0.0 ->
        Bitwise.bsl(sign, 15)

      abs_f >= 65_520.0 ->
        Bitwise.bsl(sign, 15) |> Bitwise.bor(0x7C00)

      true ->
        exp = trunc(:math.floor(:math.log2(abs_f)))
        exp = max(-14, min(15, exp))
        frac = trunc((abs_f / :math.pow(2, exp) - 1) * 1024 + 0.5) |> Bitwise.band(0x3FF)
        exp_biased = exp + 15

        Bitwise.bsl(sign, 15)
        |> Bitwise.bor(Bitwise.bsl(exp_biased, 10))
        |> Bitwise.bor(frac)
    end
  end

  defp encode_float16(_), do: 0

  defp bankers_round(n) when is_float(n) do
    floor = trunc(n)
    frac = n - floor

    cond do
      frac > 0.5 -> floor + 1
      frac < 0.5 -> floor
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end

  defp bankers_round(n) when is_integer(n), do: n
  defp bankers_round(_), do: 0

  defp call(cb, args), do: Runtime.call_callback(cb, args)
  defp to_idx(n) when is_integer(n), do: n
  defp to_idx(n) when is_float(n), do: trunc(n)
  defp to_idx(_), do: 0

  defp rebuild_buffer(vals, buf, type) do
    vals
    |> Enum.with_index()
    |> Enum.reduce(buf, fn {v, i}, acc -> write_element(acc, i, v, type) end)
  end

  defp parse_args(args, type) do
    case args do
      [{:obj, buf_ref} = buf_obj | rest] ->
        buf = Heap.get_obj(buf_ref, %{})

        cond do
          match?({:qb_arr, _}, buf) ->
            list = :array.to_list(elem(buf, 1))
            {list_to_buffer(list, type), 0, length(list), nil, false}

          is_list(buf) ->
            {list_to_buffer(buf, type), 0, length(buf), nil, false}

          is_map(buf) and Map.has_key?(buf, buffer()) ->
            bin = Map.get(buf, buffer())
            off = to_idx(Enum.at(rest, 0) || 0)
            length_arg = Enum.at(rest, 1)
            length_tracking? = length_arg in [nil, :undefined]

            len =
              if length_tracking?,
                do: div(byte_size(bin) - off, elem_size(type)),
                else: to_idx(length_arg)

            {bin, off, len, buf_obj, length_tracking?}

          true ->
            list = object_source_to_list(buf_obj)
            {list_to_buffer(list, type), 0, length(list), nil, false}
        end

      [n | _] when is_integer(n) ->
        {:binary.copy(<<0>>, n * elem_size(type)), 0, n, nil, false}

      [{:qb_arr, arr} | _] ->
        list = :array.to_list(arr)
        {list_to_buffer(list, type), 0, length(list), nil, false}

      [list | _] when is_list(list) ->
        {list_to_buffer(list, type), 0, length(list), nil, false}

      _ ->
        {<<>>, 0, 0, nil, false}
    end
  end

  defp object_source_to_list(obj) do
    iterator_method = Get.get(obj, {:symbol, "Symbol.iterator"})

    cond do
      QuickBEAM.VM.Builtin.callable?(iterator_method) ->
        iterator = Invocation.invoke_with_receiver(iterator_method, [], obj)
        iterator_to_list(iterator, [])

      iterator_method not in [nil, :undefined] ->
        JSThrow.type_error!("object is not iterable")

      true ->
        array_like_to_list(obj)
    end
  end

  defp iterator_to_list(iterator, acc) do
    next_fn = Get.get(iterator, "next")

    unless QuickBEAM.VM.Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    result = Invocation.invoke_with_receiver(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      JSThrow.type_error!("Iterator result is not an object")
    end

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      iterator_to_list(iterator, [Get.get(result, "value") | acc])
    end
  end

  defp array_like_to_list(obj) do
    len = max(Runtime.to_int(Get.get(obj, "length")), 0)

    if len == 0 do
      []
    else
      for idx <- 0..(len - 1), do: Get.get(obj, Integer.to_string(idx))
    end
  end

  # ── Element read/write ──

  defp read_element(buf, pos, :uint8) when pos < byte_size(buf), do: :binary.at(buf, pos)
  defp read_element(buf, pos, :uint8_clamped) when pos < byte_size(buf), do: :binary.at(buf, pos)

  defp read_element(buf, pos, :int8) when pos < byte_size(buf) do
    v = :binary.at(buf, pos)
    if v >= 128, do: v - 256, else: v
  end

  defp read_element(buf, pos, :uint16) when pos * 2 + 1 < byte_size(buf),
    do: :binary.decode_unsigned(:binary.part(buf, pos * 2, 2), :little)

  defp read_element(buf, pos, :int16) when pos * 2 + 1 < byte_size(buf) do
    v = :binary.decode_unsigned(:binary.part(buf, pos * 2, 2), :little)
    if v >= 0x8000, do: v - 0x10000, else: v
  end

  defp read_element(buf, pos, :uint32) when pos * 4 + 3 < byte_size(buf),
    do: :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)

  defp read_element(buf, pos, :int32) when pos * 4 + 3 < byte_size(buf) do
    v = :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)
    if v >= 0x80000000, do: v - 0x100000000, else: v
  end

  defp read_element(buf, pos, :float16) when pos * 2 + 1 < byte_size(buf) do
    <<_::binary-size(pos * 2), half::16-little, _::binary>> = buf
    decode_float16(half)
  end

  defp read_element(buf, pos, :float32) when pos * 4 + 3 < byte_size(buf) do
    bits = :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)

    case float32_special(bits) do
      nil ->
        <<f::little-float-32>> = :binary.part(buf, pos * 4, 4)
        f

      value ->
        value
    end
  end

  defp read_element(buf, pos, :float64) when pos * 8 + 7 < byte_size(buf) do
    bits = :binary.decode_unsigned(:binary.part(buf, pos * 8, 8), :little)

    case float64_special(bits) do
      nil ->
        <<f::little-float-64>> = :binary.part(buf, pos * 8, 8)
        f

      value ->
        value
    end
  end

  defp read_element(buf, pos, :bigint64) when pos * 8 + 7 < byte_size(buf) do
    <<n::little-signed-64>> = :binary.part(buf, pos * 8, 8)
    {:bigint, n}
  end

  defp read_element(buf, pos, :biguint64) when pos * 8 + 7 < byte_size(buf) do
    <<n::little-unsigned-64>> = :binary.part(buf, pos * 8, 8)
    {:bigint, n}
  end

  defp read_element(_, _, _), do: :undefined

  defp float32_special(0x7F800000), do: :infinity
  defp float32_special(0xFF800000), do: :neg_infinity

  defp float32_special(bits)
       when Bitwise.band(bits, 0x7F800000) == 0x7F800000 and Bitwise.band(bits, 0x007FFFFF) != 0,
       do: :nan

  defp float32_special(_), do: nil

  defp float64_special(0x7FF0000000000000), do: :infinity
  defp float64_special(0xFFF0000000000000), do: :neg_infinity

  defp float64_special(bits)
       when Bitwise.band(bits, 0x7FF0000000000000) == 0x7FF0000000000000 and
              Bitwise.band(bits, 0x000FFFFFFFFFFFFF) != 0,
       do: :nan

  defp float64_special(_), do: nil

  defp write_element(buf, pos, :undefined, type) when type in [:float16, :float32, :float64],
    do: write_element(buf, pos, :nan, type)

  defp write_element(buf, pos, :undefined, type), do: write_element(buf, pos, 0, type)

  defp write_element(buf, pos, val, :uint8_clamped) when pos < byte_size(buf) do
    v = max(0, min(255, bankers_round(val || 0)))
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, v::8, rest::binary>>
  end

  defp write_element(buf, pos, val, :uint8) when pos < byte_size(buf) do
    v = trunc(val || 0) |> Bitwise.band(0xFF)
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, v::8, rest::binary>>
  end

  defp write_element(buf, pos, val, :int8) when pos < byte_size(buf) do
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, trunc(val || 0)::signed-8, rest::binary>>
  end

  defp write_element(buf, pos, val, :int32) when pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, trunc(val || 0)::little-signed-32, rest::binary>>
  end

  defp write_element(buf, pos, val, :float64)
       when val in [:nan, :NaN, :infinity, :neg_infinity] and pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, float64_bits(val)::little-64, rest::binary>>
  end

  defp write_element(buf, pos, val, :float64) when pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, (val || 0.0) * 1.0::little-float-64, rest::binary>>
  end

  defp write_element(buf, pos, val, :float16) when pos * 2 + 1 < byte_size(buf) do
    half = encode_float16(val || 0)
    <<pre::binary-size(pos * 2), _::16, rest::binary>> = buf
    <<pre::binary, half::16-little, rest::binary>>
  end

  defp write_element(buf, pos, val, :float32)
       when val in [:nan, :NaN, :infinity, :neg_infinity] and pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, float32_bits(val)::little-32, rest::binary>>
  end

  defp write_element(buf, pos, val, :float32) when pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, (val || 0.0) * 1.0::little-float-32, rest::binary>>
  end

  defp write_element(buf, pos, val, :bigint64) when pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, bigint_value(val)::little-signed-64, rest::binary>>
  end

  defp write_element(buf, pos, val, :biguint64) when pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, bigint_value(val)::little-unsigned-64, rest::binary>>
  end

  defp write_element(buf, pos, val, type) do
    es = elem_size(type)
    bp = pos * es

    if bp + es <= byte_size(buf) do
      <<pre::binary-size(bp), _::binary-size(es), rest::binary>> = buf
      <<pre::binary, trunc(val || 0)::little-unsigned-size(es * 8), rest::binary>>
    else
      buf
    end
  end

  defp float32_bits(n) when n in [:nan, :NaN], do: 0x7FC00000
  defp float32_bits(:infinity), do: 0x7F800000
  defp float32_bits(:neg_infinity), do: 0xFF800000

  defp float64_bits(n) when n in [:nan, :NaN], do: 0x7FF8000000000000
  defp float64_bits(:infinity), do: 0x7FF0000000000000
  defp float64_bits(:neg_infinity), do: 0xFFF0000000000000

  defp bigint_value({:bigint, n}), do: n
  defp bigint_value(n) when is_integer(n), do: n
  defp bigint_value(_), do: 0

  defp list_to_buffer(list, type) do
    es = elem_size(type)
    buf = :binary.copy(<<0>>, length(list) * es)

    list
    |> Enum.with_index()
    |> Enum.reduce(buf, fn {val, i}, acc -> write_element(acc, i, val, type) end)
  end

  defp to_integer_or_infinity(value) do
    case Runtime.to_number(value) do
      :infinity -> :infinity
      :neg_infinity -> :neg_infinity
      :nan -> 0
      number when is_number(number) -> trunc(number)
      _ -> 0
    end
  end

  defp make_buffer_ref(buffer_data) do
    Heap.wrap(%{buffer() => buffer_data, "byteLength" => byte_size(buffer_data)})
  end
end
