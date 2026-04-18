defmodule QuickBEAM.BeamVM.Runtime.TypedArray do
  @moduledoc false
  alias QuickBEAM.BeamVM.Heap

  def array_buffer_constructor(args) do
    byte_length =
      case args do
        [n | _] when is_integer(n) -> n
        _ -> 0
      end

    ref = make_ref()

    Heap.put_obj(ref, %{
      "__buffer__" => :binary.copy(<<0>>, byte_length),
      "byteLength" => byte_length
    })

    {:obj, ref}
  end

  def typed_array_constructor(type) do
    fn args ->
      {buffer, offset, length_val, orig_buf} =
        case args do
          [{:obj, buf_ref} = buf_obj | rest] ->
            buf = Heap.get_obj(buf_ref, %{})

            cond do
              is_list(buf) ->
                len = length(buf)
                {list_to_buffer(buf, type), 0, len, nil}

              is_map(buf) and Map.has_key?(buf, "__buffer__") ->
                bin = Map.get(buf, "__buffer__")
                offset = Enum.at(rest, 0) || 0
                len = Enum.at(rest, 1) || div(byte_size(bin) - offset, elem_size(type))
                {bin, offset, len, buf_obj}

              true ->
                {:binary.copy(<<0>>, 0), 0, 0, nil}
            end

          [n | _] when is_integer(n) ->
            {:binary.copy(<<0>>, n * elem_size(type)), 0, n, nil}

          [list | _] when is_list(list) ->
            len = length(list)
            buf = list_to_buffer(list, type)
            {buf, 0, len, nil}

          [] ->
            {:binary.copy(<<0>>, 0), 0, 0, nil}

          _ ->
            {:binary.copy(<<0>>, 0), 0, 0, nil}
        end

      ref = make_ref()

      ta_ref = ref

      set_fn =
        {:builtin, "set",
         fn [source | _], _this ->
           ta = Heap.get_obj(ta_ref, %{})

           src_list =
             case source do
               {:obj, sref} ->
                 case Heap.get_obj(sref) do
                   list when is_list(list) ->
                     list

                   map when is_map(map) ->
                     len = Map.get(map, "length", 0)
                     for i <- 0..(len - 1), do: Map.get(map, Integer.to_string(i), 0)

                   _ ->
                     []
                 end

               _ ->
                 []
             end

           buf = Map.get(ta, "__buffer__", <<>>)
           t = Map.get(ta, "__type__", :uint8)

           new_buf =
             src_list
             |> Enum.with_index()
             |> Enum.reduce(buf, fn {val, i}, acc ->
               write_element(acc, i, val, t)
             end)

           Heap.put_obj(ta_ref, Map.put(ta, "__buffer__", new_buf))
           :undefined
         end}

      Heap.put_obj(ref, %{
        "__typed_array__" => true,
        "__type__" => type,
        "__buffer__" => buffer,
        "__offset__" => offset,
        "length" => length_val,
        "byteLength" => length_val * elem_size(type),
        "byteOffset" => offset,
        "buffer" => orig_buf || make_buffer_ref(buffer),
        "set" => set_fn,
        "subarray" =>
          {:builtin, "subarray",
           fn args, _this ->
             ta = Heap.get_obj(ta_ref, %{})
             buf = Map.get(ta, "__buffer__", <<>>)
             t = Map.get(ta, "__type__", :uint8)
             len = Map.get(ta, "length", 0)
             s = max(0, min(elem_size_idx(Enum.at(args, 0, 0)), len))
             e = min(elem_size_idx(Enum.at(args, 1, len)), len)
             new_len = max(0, e - s)
             es = elem_size(t)
             new_buf = binary_part(buf, s * es, new_len * es)
             new_ref = make_ref()

             Heap.put_obj(new_ref, %{
               "__typed_array__" => true,
               "__type__" => t,
               "__buffer__" => new_buf,
               "__offset__" => 0,
               "length" => new_len,
               "byteLength" => new_len * es,
               "byteOffset" => 0,
               "buffer" => Map.get(ta, "buffer")
             })

             {:obj, new_ref}
           end},
        "join" =>
          {:builtin, "join",
           fn args, _this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             sep =
               case args do
                 [s | _] when is_binary(s) -> s
                 _ -> ","
               end

             Enum.map_join(0..max(0, len - 1), sep, fn i ->
               Integer.to_string(trunc(read_element(buf, i, t)))
             end)
           end},
        "forEach" =>
          {:builtin, "forEach",
           fn [cb | _], this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             for i <- 0..(len - 1) do
               val = read_element(buf, i, t)
               QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [val, i, this], :no_interp)
             end

             :undefined
           end},
        "map" =>
          {:builtin, "map",
           fn [cb | _], this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             new_buf =
               Enum.reduce(0..(len - 1), buf, fn i, acc ->
                 val = read_element(acc, i, t)

                 result =
                   QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [val, i, this], :no_interp)

                 write_element(acc, i, result, t)
               end)

             nr = make_ref()

             Heap.put_obj(nr, %{
               "__typed_array__" => true,
               "__type__" => t,
               "__buffer__" => new_buf,
               "__offset__" => 0,
               "length" => len,
               "byteLength" => byte_size(new_buf),
               "byteOffset" => 0,
               "buffer" => Map.get(ta, "buffer")
             })

             {:obj, nr}
           end},
        "filter" =>
          {:builtin, "filter",
           fn [cb | _], this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             vals =
               for i <- 0..(len - 1),
                   (
                     val = read_element(buf, i, t)

                     QuickBEAM.BeamVM.Runtime.call_builtin_callback(
                       cb,
                       [val, i, this],
                       :no_interp
                     ) not in [false, nil, :undefined, 0, ""]
                   ),
                   do: val

             new_buf =
               vals
               |> Enum.with_index()
               |> Enum.reduce(:binary.copy(<<0>>, length(vals) * elem_size(t)), fn {v, i}, acc ->
                 write_element(acc, i, v, t)
               end)

             nr = make_ref()

             Heap.put_obj(nr, %{
               "__typed_array__" => true,
               "__type__" => t,
               "__buffer__" => new_buf,
               "__offset__" => 0,
               "length" => length(vals),
               "byteLength" => byte_size(new_buf),
               "byteOffset" => 0
             })

             {:obj, nr}
           end},
        "every" =>
          {:builtin, "every",
           fn [cb | _], this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             Enum.all?(0..max(0, len - 1), fn i ->
               val = read_element(buf, i, t)

               QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [val, i, this], :no_interp) not in [
                 false,
                 nil,
                 :undefined,
                 0,
                 ""
               ]
             end)
           end},
        "some" =>
          {:builtin, "some",
           fn [cb | _], this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             Enum.any?(0..max(0, len - 1), fn i ->
               val = read_element(buf, i, t)

               QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [val, i, this], :no_interp) not in [
                 false,
                 nil,
                 :undefined,
                 0,
                 ""
               ]
             end)
           end},
        "reduce" =>
          {:builtin, "reduce",
           fn args, this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)
             cb = List.first(args)
             init = Enum.at(args, 1)
             {start, acc} = if init != nil, do: {0, init}, else: {1, read_element(buf, 0, t)}

             Enum.reduce(start..max(start, len - 1), acc, fn i, a ->
               val = read_element(buf, i, t)
               QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [a, val, i, this], :no_interp)
             end)
           end},
        "indexOf" =>
          {:builtin, "indexOf",
           fn [target | _], _this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             Enum.find_value(0..max(0, len - 1), -1, fn i ->
               if read_element(buf, i, t) == target, do: i
             end)
           end},
        "find" =>
          {:builtin, "find",
           fn [cb | _], this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             Enum.find_value(0..max(0, len - 1), :undefined, fn i ->
               val = read_element(buf, i, t)

               if QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [val, i, this], :no_interp) not in [
                    false,
                    nil,
                    :undefined,
                    0,
                    ""
                  ],
                  do: val
             end)
           end},
        "sort" =>
          {:builtin, "sort",
           fn _args, _this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             vals =
               Enum.map(0..max(0, len - 1), fn i -> read_element(buf, i, t) end) |> Enum.sort()

             new_buf =
               vals
               |> Enum.with_index()
               |> Enum.reduce(buf, fn {v, i}, acc -> write_element(acc, i, v, t) end)

             Heap.put_obj(ta_ref, Map.put(ta, "__buffer__", new_buf))
             {:obj, ta_ref}
           end},
        "reverse" =>
          {:builtin, "reverse",
           fn _args, _this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)

             vals =
               Enum.map(0..max(0, len - 1), fn i -> read_element(buf, i, t) end) |> Enum.reverse()

             new_buf =
               vals
               |> Enum.with_index()
               |> Enum.reduce(buf, fn {v, i}, acc -> write_element(acc, i, v, t) end)

             Heap.put_obj(ta_ref, Map.put(ta, "__buffer__", new_buf))
             {:obj, ta_ref}
           end},
        "slice" =>
          {:builtin, "slice",
           fn args, _this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)
             buf = Map.get(ta, "__buffer__", <<>>)
             s = max(0, elem_size_idx(Enum.at(args, 0, 0)))
             e = min(len, elem_size_idx(Enum.at(args, 1, len)))
             new_len = max(0, e - s)
             es = elem_size(t)
             new_buf = if new_len > 0, do: binary_part(buf, s * es, new_len * es), else: <<>>
             nr = make_ref()

             Heap.put_obj(nr, %{
               "__typed_array__" => true,
               "__type__" => t,
               "__buffer__" => new_buf,
               "__offset__" => 0,
               "length" => new_len,
               "byteLength" => byte_size(new_buf),
               "byteOffset" => 0
             })

             {:obj, nr}
           end},
        "fill" =>
          {:builtin, "fill",
           fn [val | _], _this ->
             ta = Heap.get_obj(ta_ref, %{})
             len = Map.get(ta, "length", 0)
             t = Map.get(ta, "__type__", :uint8)

             new_buf =
               Enum.reduce(0..(len - 1), Map.get(ta, "__buffer__", <<>>), fn i, buf ->
                 write_element(buf, i, val, t)
               end)

             Heap.put_obj(ta_ref, Map.put(ta, "__buffer__", new_buf))
             {:obj, ta_ref}
           end}
      })

      {:obj, ref}
    end
  end

  def get_element({:obj, ref}, idx) when is_integer(idx) do
    map = Heap.get_obj(ref, %{})

    case map do
      %{
        "__typed_array__" => true,
        "__type__" => type,
        "__buffer__" => buf,
        "__offset__" => offset
      } ->
        read_element(buf, offset + idx * elem_size(type), type)

      _ ->
        :undefined
    end
  end

  def get_element(_, _), do: :undefined

  def set_element({:obj, ref}, idx, val) when is_integer(idx) do
    map = Heap.get_obj(ref, %{})

    case map do
      %{
        "__typed_array__" => true,
        "__type__" => type,
        "__buffer__" => buf,
        "__offset__" => offset
      } ->
        new_buf = write_element(buf, offset + idx * elem_size(type), type, val)
        Heap.put_obj(ref, %{map | "__buffer__" => new_buf})

      _ ->
        :ok
    end
  end

  def set_element(_, _, _), do: :ok

  def typed_array?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__typed_array__" => true} -> true
      _ -> false
    end
  end

  def typed_array?(_), do: false

  defp elem_size_idx(n) when is_integer(n), do: n
  defp elem_size_idx(n) when is_float(n), do: trunc(n)
  defp elem_size_idx(_), do: 0

  defp elem_size(:uint8), do: 1
  defp elem_size(:int8), do: 1
  defp elem_size(:uint8_clamped), do: 1
  defp elem_size(:uint16), do: 2
  defp elem_size(:int16), do: 2
  defp elem_size(:uint32), do: 4
  defp elem_size(:int32), do: 4
  defp elem_size(:float32), do: 4
  defp elem_size(:float64), do: 8
  defp elem_size(:bigint64), do: 8
  defp elem_size(:biguint64), do: 8

  defp read_element(buf, pos, :uint8_clamped) when pos < byte_size(buf), do: :binary.at(buf, pos)
  defp read_element(buf, pos, :uint8) when pos < byte_size(buf), do: :binary.at(buf, pos)

  defp read_element(buf, pos, :int8) when pos < byte_size(buf) do
    <<_::binary-size(pos), v::signed-8, _::binary>> = buf
    v
  end

  defp read_element(buf, pos, :uint16) when pos + 1 < byte_size(buf) do
    <<_::binary-size(pos), v::little-unsigned-16, _::binary>> = buf
    v
  end

  defp read_element(buf, pos, :int16) when pos + 1 < byte_size(buf) do
    <<_::binary-size(pos), v::little-signed-16, _::binary>> = buf
    v
  end

  defp read_element(buf, pos, :uint32) when pos + 3 < byte_size(buf) do
    <<_::binary-size(pos), v::little-unsigned-32, _::binary>> = buf
    v
  end

  defp read_element(buf, pos, :int32) when pos + 3 < byte_size(buf) do
    <<_::binary-size(pos), v::little-signed-32, _::binary>> = buf
    v
  end

  defp read_element(buf, pos, :float32) when pos + 3 < byte_size(buf) do
    <<_::binary-size(pos), v::little-float-32, _::binary>> = buf
    v
  end

  defp read_element(buf, pos, :float64) when pos + 7 < byte_size(buf) do
    <<_::binary-size(pos), v::little-float-64, _::binary>> = buf
    v
  end

  defp read_element(_, _, _), do: :undefined

  defp write_element(buf, pos, :uint8_clamped, val) when pos < byte_size(buf) do
    v = trunc(val) |> max(0) |> min(255)
    <<pre::binary-size(pos), _::8, post::binary>> = buf
    <<pre::binary, v::8, post::binary>>
  end

  defp write_element(buf, pos, :uint8, val) when pos < byte_size(buf) do
    v = trunc(val) |> Bitwise.band(0xFF)
    <<pre::binary-size(pos), _::8, post::binary>> = buf
    <<pre::binary, v::8, post::binary>>
  end

  defp write_element(buf, pos, :int8, val) when pos < byte_size(buf) do
    <<pre::binary-size(pos), _::8, post::binary>> = buf
    <<pre::binary, trunc(val)::signed-8, post::binary>>
  end

  defp write_element(buf, pos, :int32, val) when pos + 3 < byte_size(buf) do
    <<pre::binary-size(pos), _::32, post::binary>> = buf
    <<pre::binary, trunc(val)::little-signed-32, post::binary>>
  end

  defp write_element(buf, pos, :float64, val) when pos + 7 < byte_size(buf) do
    v = val * 1.0
    <<pre::binary-size(pos), _::64, post::binary>> = buf
    <<pre::binary, v::little-float-64, post::binary>>
  end

  defp write_element(buf, pos, :float32, val) when pos + 3 < byte_size(buf) do
    v = val * 1.0
    <<pre::binary-size(pos), _::32, post::binary>> = buf
    <<pre::binary, v::little-float-32, post::binary>>
  end

  defp write_element(buf, pos, type, val) do
    size = elem_size(type) * 8

    if pos + div(size, 8) - 1 < byte_size(buf) do
      <<pre::binary-size(pos), _::size(size), post::binary>> = buf
      <<pre::binary, trunc(val)::little-size(size), post::binary>>
    else
      buf
    end
  end

  defp list_to_buffer(list, type) do
    list
    |> Enum.map(fn
      n when is_number(n) -> n
      _ -> 0
    end)
    |> Enum.reduce(<<>>, fn val, acc ->
      acc <> encode_element(val, type)
    end)
  end

  defp encode_element(val, :uint8_clamped), do: <<trunc(val) |> max(0) |> min(255)::8>>
  defp encode_element(val, :uint8), do: <<trunc(val) |> Bitwise.band(0xFF)::8>>
  defp encode_element(val, :int8), do: <<trunc(val)::signed-8>>
  defp encode_element(val, :int32), do: <<trunc(val)::little-signed-32>>
  defp encode_element(val, :float32), do: <<val * 1.0::little-float-32>>
  defp encode_element(val, :float64), do: <<val * 1.0::little-float-64>>

  defp encode_element(val, type) do
    size = elem_size(type) * 8
    <<trunc(val)::little-size(size)>>
  end

  defp make_buffer_ref(buffer) do
    ref = make_ref()
    Heap.put_obj(ref, %{"__buffer__" => buffer, "byteLength" => byte_size(buffer)})
    {:obj, ref}
  end
end
