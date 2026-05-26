defmodule QuickBEAM.VM.Runtime.ArrayBuffer do
  @moduledoc "JS `ArrayBuffer` and `SharedArrayBuffer` built-in: constructor, transfer, resize, and slice operations."

  import QuickBEAM.VM.Heap.Keys
  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Definition
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Builtin.Installer
  alias QuickBEAM.VM.Runtime.InstallerHelpers

  def builtin_definitions do
    for name <- ["ArrayBuffer", "SharedArrayBuffer"] do
      %Definition{
        name: name,
        constructor: &__MODULE__.constructor/2,
        length: 1,
        phase: :fundamental,
        module: __MODULE__,
        after_install: &__MODULE__.install_builtin/1
      }
    end
  end

  def install_builtin(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      specs =
        Enum.map(proto_property_names(), fn name ->
          QuickBEAM.VM.Builtin.property_spec(name, proto_property_spec(name))
        end)

      Installer.install_property_specs({:object, proto_ref}, __MODULE__, specs, :prototype)
    end)

    Heap.put_ctor_static(
      ctor,
      {:symbol, "Symbol.species"},
      {:accessor, {:builtin, "get [Symbol.species]", fn _, _ -> ctor end}, nil}
    )
  end

  @doc "Returns prototype method names installed on ArrayBuffer.prototype."
  def proto_property_names, do: ~w(transfer resize slice sliceToImmutable transferToImmutable)

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor(args, _this \\ nil) do
    {byte_length, max_byte_length} =
      case args do
        [n, opts | _] when is_integer(n) -> {n, max_byte_length_option(opts)}
        [n | _] when is_integer(n) -> {n, nil}
        _ -> {0, nil}
      end

    map = %{
      buffer() => :binary.copy(<<0>>, byte_length),
      "byteLength" => byte_length,
      "resizable" => max_byte_length != nil
    }

    map = if max_byte_length, do: Map.put(map, "maxByteLength", max_byte_length), else: map
    Heap.wrap(map)
  end

  proto "transfer" do
    case this do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})

        if is_map(map) do
          new_buf = Map.get(map, buffer(), <<>>)

          Heap.put_obj(
            ref,
            Map.merge(map, %{buffer() => <<>>, "byteLength" => 0, "__detached__" => true})
          )

          Heap.wrap(%{buffer() => new_buf, "byteLength" => byte_size(new_buf)})
        else
          :undefined
        end

      _ ->
        :undefined
    end
  end

  proto "resize" do
    case this do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})

        new_size =
          case args do
            [n | _] when is_number(n) -> trunc(n)
            _ -> 0
          end

        if is_map(map) do
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
        end

        :undefined

      _ ->
        :undefined
    end
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

  proto "slice" do
    do_slice(this, args)
  end

  proto "transferToImmutable" do
    immutable = do_slice_to_immutable(this, args)

    case this do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})

        Heap.put_obj(
          ref,
          Map.merge(map, %{buffer() => <<>>, "byteLength" => 0, "__detached__" => true})
        )

      _ ->
        :ok
    end

    immutable
  end

  proto "sliceToImmutable" do
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

  defp do_slice(this, args) do
    case this do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})

        if is_map(map) and Map.get(map, "__detached__") do
          JSThrow.type_error!("ArrayBuffer is detached")
        end

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

        read_array_buffer_species()

        # After species getter, re-check the buffer (it may have been resized/detached)
        map2 = Heap.get_obj(ref, %{})
        buf2 = Map.get(map2, buffer(), <<>>)

        if byte_size(buf2) < s + new_len do
          JSThrow.type_error!("ArrayBuffer is detached")
        end

        new_buf = if new_len > 0, do: binary_part(buf2, s, new_len), else: <<>>
        Heap.wrap(%{buffer() => new_buf, "byteLength" => new_len})

      _ ->
        :undefined
    end
  end

  defp normalize_idx(n, len) when n < 0, do: max(0, len + n)
  defp normalize_idx(n, len), do: min(n, len)

  defp max_byte_length_option({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> Map.get(map, "maxByteLength")
      _ -> nil
    end
  end

  defp max_byte_length_option(_), do: nil

  defp read_array_buffer_species do
    case Runtime.global_constructor("ArrayBuffer") do
      nil ->
        nil

      ctor ->
        case Map.get(Heap.get_ctor_statics(ctor), {:symbol, "Symbol.species"}) do
          {:accessor, getter, _} when getter != nil -> Runtime.call_callback(getter, [])
          _ -> nil
        end
    end
  end
end
