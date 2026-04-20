defmodule QuickBEAM.BeamVM.Runtime.ArrayBuffer do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime

  def constructor(args, _this \\ nil) do
    {byte_length, max_byte_length} =
      case args do
        [n, opts | _] when is_integer(n) ->
          max =
            case opts do
              {:obj, ref} ->
                case Heap.get_obj(ref, %{}) do
                  map when is_map(map) -> Map.get(map, "maxByteLength")
                  _ -> nil
                end

              _ ->
                nil
            end

          {n, max}

        [n | _] when is_integer(n) ->
          {n, nil}

        _ ->
          {0, nil}
      end

    map = %{buffer() => :binary.copy(<<0>>, byte_length), "byteLength" => byte_length}
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

          Heap.put_obj(ref, Map.merge(map, %{buffer() => new_buf, "byteLength" => new_size}))
        end

        :undefined

      _ ->
        :undefined
    end
  end

  proto "slice" do
    do_slice(this, args)
  end

  proto "sliceToImmutable" do
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
          throw({:js_throw, Heap.make_error("ArrayBuffer is detached", "TypeError")})
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

        # Check Symbol.species on the constructor
        ab_ctor = Runtime.global_bindings()["ArrayBuffer"]

        _species =
          case ab_ctor do
            {:builtin, _, _} = b ->
              case Map.get(Heap.get_ctor_statics(b), {:symbol, "Symbol.species"}) do
                {:accessor, getter, _} when getter != nil -> Runtime.call_callback(getter, [])
                _ -> nil
              end

            _ ->
              nil
          end

        # After species getter, re-check the buffer (it may have been resized/detached)
        map2 = Heap.get_obj(ref, %{})
        buf2 = Map.get(map2, buffer(), <<>>)

        if byte_size(buf2) < s + new_len do
          throw({:js_throw, Heap.make_error("ArrayBuffer is detached", "TypeError")})
        end

        new_buf = if new_len > 0, do: binary_part(buf2, s, new_len), else: <<>>
        Heap.wrap(%{buffer() => new_buf, "byteLength" => new_len})

      _ ->
        :undefined
    end
  end

  defp normalize_idx(n, len) when n < 0, do: max(0, len + n)
  defp normalize_idx(n, len), do: min(n, len)
end
