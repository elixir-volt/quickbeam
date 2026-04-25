defmodule QuickBEAM.VM.Runtime.Web.Blob do
  @moduledoc "Blob and File constructor builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, PromiseState}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{
      "Blob" => WebAPIs.register("Blob", &build_blob/2),
      "File" => WebAPIs.register("File", &build_file/2)
    }
  end

  def build_blob(args, _this) do
    {parts_val, opts_val} =
      case args do
        [p, o | _] -> {p, o}
        [p | _] -> {p, nil}
        _ -> {nil, nil}
      end

    content = extract_content(parts_val)

    mime_type =
      case opts_val do
        {:obj, _} = obj ->
          case obj |> Get.get("type") |> Values.stringify() do
            "undefined" -> ""
            "null" -> ""
            s -> s
          end

        _ ->
          ""
      end

    build_blob_object(content, mime_type)
  end

  def build_file(args, _this) do
    {parts_val, name_val, opts_val} =
      case args do
        [p, n, o | _] -> {p, n, o}
        [p, n | _] -> {p, n, nil}
        [p | _] -> {p, "", nil}
        _ -> {nil, "", nil}
      end

    content = extract_content(parts_val)
    file_name = to_string(name_val)

    {mime_type, last_modified} =
      case opts_val do
        {:obj, _} = obj ->
          mt =
            case obj |> Get.get("type") |> Values.stringify() do
              "undefined" -> ""
              "null" -> ""
              s -> s
            end

          lm =
            case Get.get(obj, "lastModified") do
              :undefined -> System.os_time(:millisecond)
              nil -> System.os_time(:millisecond)
              n when is_number(n) -> trunc(n)
              _ -> System.os_time(:millisecond)
            end

          {mt, lm}

        _ ->
          {"", System.os_time(:millisecond)}
      end

    blob_base = build_blob_object(content, mime_type)
    file_ctor = get_file_ctor()
    file_proto = if file_ctor, do: Heap.get_class_proto(file_ctor), else: nil

    case blob_base do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, fn m ->
          base = m
          |> Map.put("name", file_name)
          |> Map.put("lastModified", last_modified)
          |> Map.put("constructor", file_ctor)

          if file_proto, do: Map.put(base, "__proto__", file_proto), else: base
        end)

        blob_base

      _ ->
        blob_base
    end
  end

  defp get_file_ctor do
    case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "File")
    end
  end

  def build_blob_object(content, mime_type) do
    content_ref = make_ref()
    Heap.put_obj(content_ref, content)

    blob_ctor = get_blob_ctor()
    blob_proto = if blob_ctor, do: Heap.get_class_proto(blob_ctor), else: nil

    Heap.wrap(
      build_methods do
        val("size", byte_size(content))
        val("type", mime_type)
        val("constructor", blob_ctor)
        val("__proto__", blob_proto)

        method "text" do
          raw = Heap.get_obj(content_ref, "")
          PromiseState.resolved(raw)
        end

        method "arrayBuffer" do
          raw = Heap.get_obj(content_ref, "")
          buf = make_array_buffer(raw)
          PromiseState.resolved(buf)
        end

        method "bytes" do
          raw = Heap.get_obj(content_ref, "")
          make_uint8_from_binary(raw)
        end

        method "slice" do
          raw = Heap.get_obj(content_ref, "")
          total = byte_size(raw)

          start_idx = normalize_slice_idx(List.first(args, 0), total)
          end_idx = normalize_slice_idx(Enum.at(args, 1, total), total)
          new_mime = Enum.at(args, 2, mime_type) |> to_string()

          slice_len = max(0, end_idx - start_idx)
          sliced = binary_part(raw, min(start_idx, total), min(slice_len, total - start_idx))
          build_blob_object(sliced, new_mime)
        end

        method "stream" do
          :undefined
        end
      end
    )
  end

  defp get_blob_ctor do
    case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "Blob")
    end
  end

  defp normalize_slice_idx(idx, total) when is_integer(idx) do
    cond do
      idx < 0 -> max(0, total + idx)
      idx > total -> total
      true -> idx
    end
  end

  defp normalize_slice_idx(idx, total) when is_float(idx), do: normalize_slice_idx(trunc(idx), total)
  defp normalize_slice_idx(:undefined, total), do: total
  defp normalize_slice_idx(nil, total), do: total
  defp normalize_slice_idx(_, _), do: 0

  defp extract_content(nil), do: ""
  defp extract_content(:undefined), do: ""

  defp extract_content({:obj, _} = arr) do
    items = Heap.to_list(arr)
    Enum.map_join(items, "", &part_to_binary/1)
  end

  defp extract_content(list) when is_list(list) do
    Enum.map_join(list, "", &part_to_binary/1)
  end

  defp extract_content(_), do: ""

  defp part_to_binary({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        cond do
          Map.has_key?(map, "__buffer__") and Map.has_key?(map, "__typed_array__") ->
            buf_raw = Map.get(map, "__buffer__", "")

            if is_binary(buf_raw) do
              offset = Map.get(map, "byteOffset", 0)
              len = Map.get(map, "byteLength", 0)

              if byte_size(buf_raw) >= offset + len do
                binary_part(buf_raw, offset, len)
              else
                ""
              end
            else
              ""
            end

          Map.has_key?(map, "__buffer__") ->
            Map.get(map, "__buffer__", "")

          Map.has_key?(map, "size") and Map.has_key?(map, "type") ->
            case Get.get(obj, "text") do
              {:builtin, _, _} -> Values.stringify(obj)
              _ -> Values.stringify(obj)
            end

          true ->
            Values.stringify(obj)
        end

      list when is_list(list) ->
        :erlang.list_to_binary(Enum.map(list, fn
          n when is_integer(n) -> n
          _ -> 0
        end))

      _ ->
        Values.stringify(obj)
    end
  end

  defp part_to_binary(v), do: Values.stringify(v)

  defp make_array_buffer(data) when is_binary(data) do
    byte_len = byte_size(data)

    case Heap.get_global_cache() do
      nil ->
        Heap.wrap(%{"__buffer__" => data, "byteLength" => byte_len})

      globals ->
        case Map.get(globals, "ArrayBuffer") do
          {:builtin, _, cb} = ctor ->
            result = cb.([byte_len], nil)
            proto = Heap.get_class_proto(ctor)

            case result do
              {:obj, ref} ->
                Heap.update_obj(ref, %{}, fn m ->
                  base = Map.put(m, "__buffer__", data)
                  if proto != nil and not Map.has_key?(base, "__proto__"),
                    do: Map.put(base, "__proto__", proto),
                    else: base
                end)

                result

              _ ->
                result
            end

          _ ->
            Heap.wrap(%{"__buffer__" => data, "byteLength" => byte_len})
        end
    end
  end

  defp make_uint8_from_binary(data) when is_binary(data) do
    bytes = :binary.bin_to_list(data)
    Heap.wrap(bytes)
  end
end
