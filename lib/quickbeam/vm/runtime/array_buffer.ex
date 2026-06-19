defmodule QuickBEAM.VM.Runtime.ArrayBuffer do
  @moduledoc "JS `ArrayBuffer` and `SharedArrayBuffer` built-in: constructor, transfer, resize, and slice operations."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_nullish: 1]
  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.{Get, OwnProperty}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.TypedArrayCoercion
  alias QuickBEAM.VM.Value

  @max_array_buffer_length 4_294_967_295

  defintrinsics do
    intrinsic "ArrayBuffer" do
      constructor(&__MODULE__.constructor/2, length: 1, phase: :fundamental)

      prototype extends: :object do
        properties()
        to_string_tag("ArrayBuffer")
      end
    end
  end

  @ecma "25.1.5.1"
  static "isView", length: 1 do
    is_view(arg(args, 0, :undefined))
  end

  static_methods do
    @ecma "25.1.5.3"
    symbol :species do
      get do
        this
      end
    end
  end

  @doc "Returns prototype method names installed on ArrayBuffer.prototype."
  def proto_property_names,
    do:
      ~w(byteLength detached maxByteLength resizable transfer resize slice sliceToImmutable transferToFixedLength transferToImmutable)

  @ecma "25.1.6.1"
  proto_getter "byteLength" do
    map = array_buffer_map!(this)
    if Map.get(map, "__detached__"), do: 0, else: Map.get(map, "byteLength", 0)
  end

  @ecma "25.1.6.3"
  proto_getter "detached" do
    map = array_buffer_map!(this)
    !!Map.get(map, "__detached__")
  end

  @ecma "25.1.6.4"
  proto_getter "maxByteLength" do
    map = array_buffer_map!(this)

    if Map.get(map, "resizable"),
      do: Map.get(map, "maxByteLength", 0),
      else: Map.get(map, "byteLength", 0)
  end

  @ecma "25.1.6.5"
  proto_getter "resizable" do
    map = array_buffer_map!(this)
    !!Map.get(map, "resizable")
  end

  def prevalidate_construct_args!(args) do
    byte_length = args |> arg(0, :undefined) |> TypedArrayCoercion.index()
    max_byte_length = args |> arg(1, :undefined) |> max_byte_length_option()

    if max_byte_length != nil and max_byte_length < byte_length do
      JSThrow.range_error!("maxByteLength is smaller than byteLength")
    end

    :ok
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor(args, this \\ nil) do
    unless match?({:obj, _}, this) do
      JSThrow.type_error!("ArrayBuffer constructor requires 'new'")
    end

    byte_length = args |> arg(0, :undefined) |> array_buffer_index!()
    max_byte_length = args |> arg(1, :undefined) |> max_byte_length_option()

    if byte_length > @max_array_buffer_length do
      JSThrow.range_error!("Invalid ArrayBuffer length")
    end

    if max_byte_length != nil and max_byte_length < byte_length do
      JSThrow.range_error!("maxByteLength is smaller than byteLength")
    end

    map = %{
      buffer() => :binary.copy(<<0>>, byte_length),
      "byteLength" => byte_length,
      "resizable" => max_byte_length != nil,
      "__array_buffer_kind__" => array_buffer_kind(this)
    }

    map = if max_byte_length, do: Map.put(map, "maxByteLength", max_byte_length), else: map
    {:obj, ref} = this
    Heap.put_obj(ref, Map.merge(Heap.get_obj(ref, %{}), map))
    this
  end

  @ecma "25.1.6.8"
  proto "transfer", length: 0 do
    transfer_buffer(this, args, :preserve_resizable)
  end

  @ecma "25.1.6.6"
  proto "resize", length: 1 do
    map = array_buffer_map!(this)
    {:obj, ref} = this

    cond do
      Map.get(map, "__immutable__") ->
        JSThrow.type_error!("ArrayBuffer is immutable")

      Map.get(map, "resizable") != true ->
        JSThrow.type_error!("ArrayBuffer is not resizable")

      true ->
        :ok
    end

    new_size = args |> arg(0, :undefined) |> array_buffer_index!()

    if new_size > Map.get(map, "maxByteLength", Map.get(map, "byteLength", 0)) do
      JSThrow.range_error!("new length exceeds maxByteLength")
    end

    old_buf = Map.get(map, buffer(), <<>>)

    new_buf =
      if new_size <= byte_size(old_buf) do
        binary_part(old_buf, 0, new_size)
      else
        old_buf <> :binary.copy(<<0>>, new_size - byte_size(old_buf))
      end

    resized = Map.merge(map, %{buffer() => new_buf, "byteLength" => new_size})
    Heap.put_obj(ref, resized)
    update_typed_array_views(resized, new_size)
    :undefined
  end

  defp update_typed_array_views(%{"__views__" => views}, new_size) when is_list(views) do
    for view_ref <- views do
      case Heap.get_obj(view_ref, %{}) do
        %{typed_array() => true} = view ->
          offset = Map.get(view, "byteOffset", 0)
          elem_size = Map.get(view, "BYTES_PER_ELEMENT", 1)
          available = max(new_size - offset, 0)

          {length, byte_length} =
            if Map.get(view, "__length_tracking__") do
              {div(available, elem_size), available}
            else
              fixed_byte_length =
                Map.get(view, "__fixed_byte_length__", Map.get(view, "byteLength", 0))

              if available < fixed_byte_length do
                {0, 0}
              else
                {Map.get(view, "__fixed_length__", Map.get(view, "length", 0)), fixed_byte_length}
              end
            end

          Heap.put_obj(view_ref, %{view | "length" => length, "byteLength" => byte_length})

        _ ->
          :ok
      end
    end
  end

  defp update_typed_array_views(_, _), do: :ok

  defp array_buffer_map!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, buffer()) and not is_map_key(map, typed_array()) ->
        if Map.get(map, "__array_buffer_kind__", :array_buffer) == :array_buffer do
          map
        else
          JSThrow.type_error!("receiver is not an ArrayBuffer")
        end

      _ ->
        JSThrow.type_error!("receiver is not an ArrayBuffer")
    end
  end

  defp array_buffer_map!(_), do: JSThrow.type_error!("receiver is not an ArrayBuffer")

  defp array_buffer_kind({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        object_proto = Map.get(map, :__internal_proto__, Map.get(map, proto()))

        if object_proto == Runtime.global_class_proto("SharedArrayBuffer") do
          :shared_array_buffer
        else
          :array_buffer
        end

      _ ->
        :array_buffer
    end
  end

  defp array_buffer_kind(_), do: :array_buffer

  defp is_view({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} -> true
      %{"__data_view__" => true} -> true
      _ -> false
    end
  end

  defp is_view(_), do: false

  @ecma "25.1.6.7"
  proto "slice", length: 2 do
    do_slice(this, args)
  end

  @ecma "25.1.6.9"
  proto "transferToFixedLength", length: 0 do
    transfer_buffer(this, args, :fixed)
  end

  @ecma "25.1.6.9"
  proto "transferToImmutable", length: 0 do
    transfer_buffer(this, args, :immutable)
  end

  defp transfer_buffer({:obj, ref} = this, args, mode) do
    map = array_buffer_map!(this)

    if Map.get(map, "__detached__") do
      JSThrow.type_error!("ArrayBuffer is detached")
    end

    old_buf = Map.get(map, buffer(), <<>>)
    old_len = byte_size(old_buf)

    new_len =
      case arg(args, 0, :undefined) do
        :undefined -> old_len
        value -> array_buffer_index!(value)
      end

    if Map.get(map, "__immutable__") do
      JSThrow.type_error!("ArrayBuffer is immutable")
    end

    new_buf = resized_buffer(old_buf, new_len)

    result = %{
      buffer() => new_buf,
      "byteLength" => new_len,
      "resizable" => false,
      "__array_buffer_kind__" => :array_buffer
    }

    result =
      cond do
        mode == :preserve_resizable and Map.get(map, "resizable") ->
          result
          |> Map.put("resizable", true)
          |> Map.put("maxByteLength", max(Map.get(map, "maxByteLength", old_len), new_len))

        mode == :immutable ->
          Map.put(result, "__immutable__", true)

        true ->
          result
      end

    Heap.put_obj(
      ref,
      Map.merge(map, %{buffer() => <<>>, "byteLength" => 0, "__detached__" => true})
    )

    Heap.wrap(result)
  end

  defp transfer_buffer(_this, _args, _mode),
    do: JSThrow.type_error!("receiver is not an ArrayBuffer")

  defp resized_buffer(buf, new_len) do
    old_len = byte_size(buf)

    cond do
      new_len == old_len -> buf
      new_len < old_len -> binary_part(buf, 0, new_len)
      true -> buf <> :binary.copy(<<0>>, new_len - old_len)
    end
  end

  proto "sliceToImmutable", length: 2 do
    do_slice_to_immutable(this, args)
  end

  defp do_slice_to_immutable(this, args) do
    case this do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})
        buf = Map.get(map, buffer(), <<>>)
        len = byte_size(buf)

        s =
          case args do
            [n | _] when is_number(n) -> normalize_idx(trunc(n), len)
            _ -> 0
          end

        e =
          case args do
            [_, n | _] when is_number(n) -> normalize_idx(trunc(n), len)
            _ -> len
          end

        new_len = max(0, e - s)
        new_buf = if new_len > 0, do: binary_part(buf, s, new_len), else: <<>>
        Heap.wrap(%{buffer() => new_buf, "byteLength" => new_len, "__immutable__" => true})

      _ ->
        :undefined
    end
  end

  defp do_slice({:obj, ref} = this, args) do
    map = array_buffer_map!(this)

    if Map.get(map, "__detached__") do
      JSThrow.type_error!("ArrayBuffer is detached")
    end

    buf = Map.get(map, buffer(), <<>>)
    len = byte_size(buf)

    s =
      case args do
        [n | _] -> normalize_idx(TypedArrayCoercion.integer_or_infinity(n), len)
        _ -> 0
      end

    e =
      case args do
        [_, :undefined | _] -> len
        [_, n | _] -> normalize_idx(TypedArrayCoercion.integer_or_infinity(n), len)
        _ -> len
      end

    new_len = max(0, e - s)
    result = array_buffer_species_create(this, new_len)

    map2 = Heap.get_obj(ref, %{})
    buf2 = Map.get(map2, buffer(), <<>>)

    if byte_size(buf2) < s + new_len do
      JSThrow.type_error!("ArrayBuffer is detached")
    end

    copy = if new_len > 0, do: binary_part(buf2, s, new_len), else: <<>>
    write_array_buffer_slice_result!(result, copy, new_len)
    result
  end

  defp do_slice(_this, _args), do: JSThrow.type_error!("receiver is not an ArrayBuffer")

  defp normalize_idx(:infinity, len), do: len
  defp normalize_idx(:neg_infinity, _len), do: 0
  defp normalize_idx(n, len) when n < 0, do: max(0, len + n)
  defp normalize_idx(n, len), do: min(n, len)

  defp max_byte_length_option(:undefined), do: nil

  defp max_byte_length_option({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, "maxByteLength", :undefined) do
          :undefined -> nil
          value -> array_buffer_index!(value)
        end

      _ ->
        nil
    end
  end

  defp max_byte_length_option(_), do: nil

  defp array_buffer_index!(value) do
    index = TypedArrayCoercion.index(value)

    if index > @max_array_buffer_length do
      JSThrow.range_error!("Invalid ArrayBuffer length")
    end

    index
  end

  defp array_buffer_species_create(obj, new_len) do
    case array_buffer_species_constructor(obj) do
      nil ->
        Heap.wrap(%{
          buffer() => :binary.copy(<<0>>, new_len),
          "byteLength" => new_len,
          "__array_buffer_kind__" => :array_buffer,
          proto() => Runtime.global_class_proto("ArrayBuffer")
        })

      ctor ->
        unless QuickBEAM.VM.Builtin.callable?(ctor) do
          JSThrow.type_error!("ArrayBuffer species constructor is not a constructor")
        end

        result = Invocation.construct_runtime(ctor, ctor, [new_len])
        result_map = array_buffer_map!(result)

        cond do
          result == obj ->
            JSThrow.type_error!("ArrayBuffer species returned same buffer")

          Map.get(result_map, "__immutable__") ->
            JSThrow.type_error!("ArrayBuffer species returned immutable buffer")

          Map.get(result_map, "byteLength", 0) < new_len ->
            JSThrow.type_error!("ArrayBuffer species result is too small")

          true ->
            result
        end
    end
  end

  defp array_buffer_species_constructor(obj) do
    case Get.get(obj, "constructor") do
      :undefined ->
        if explicit_null_constructor?(obj),
          do: JSThrow.type_error!("ArrayBuffer constructor is not an object"),
          else: nil

      :null ->
        JSThrow.type_error!("ArrayBuffer constructor is not an object")

      ctor when is_nullish(ctor) ->
        JSThrow.type_error!("ArrayBuffer constructor is not an object")

      ctor ->
        unless Value.object_like?(ctor) do
          JSThrow.type_error!("ArrayBuffer constructor is not an object")
        end

        case Get.get(ctor, {:symbol, "Symbol.species"}) do
          species when is_nullish(species) -> nil
          species -> species
        end
    end
  end

  defp explicit_null_constructor?(obj) do
    case OwnProperty.descriptor(obj, "constructor") do
      {:obj, desc_ref} ->
        match?(%{"value" => nil}, Heap.get_obj(desc_ref, %{}))

      _ ->
        false
    end
  end

  defp write_array_buffer_slice_result!({:obj, ref}, copy, new_len) do
    map = Heap.get_obj(ref, %{})
    buf = Map.get(map, buffer(), <<>>)
    suffix_len = max(byte_size(buf) - new_len, 0)
    suffix = if suffix_len > 0, do: binary_part(buf, new_len, suffix_len), else: <<>>
    Heap.put_obj(ref, Map.put(map, buffer(), copy <> suffix))
  end
end
