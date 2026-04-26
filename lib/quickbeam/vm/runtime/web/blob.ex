defmodule QuickBEAM.VM.Runtime.Web.Blob do
  @moduledoc "Blob and File constructor builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, object: 1]

  alias QuickBEAM.VM.{Heap, PromiseState, Runtime}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Web.BinaryData
  alias QuickBEAM.VM.Runtime.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{
      "Blob" => WebAPIs.register("Blob", &build_blob/2),
      "File" => WebAPIs.register("File", &build_file/2)
    }
  end

  def build_blob(args, _this) do
    [parts_val, opts_val] = argv(args, [nil, nil])

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

  @doc "Builds file data for blob and file constructor builtins for beam mode."
  def build_file(args, _this) do
    [parts_val, name_val, opts_val] = argv(args, [nil, "", nil])

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
    file_proto = Runtime.global_class_proto("File")

    {:obj, ref} = blob_base

    Heap.update_obj(ref, %{}, fn m ->
      base =
        m
        |> Map.put("name", file_name)
        |> Map.put("lastModified", last_modified)
        |> Map.put("constructor", file_ctor)

      if file_proto, do: Map.put(base, "__proto__", file_proto), else: base
    end)

    blob_base
  end

  defp get_file_ctor, do: Runtime.global_constructor("File")

  @doc "Builds blob object data for blob and file constructor builtins for beam mode."
  def build_blob_object(content, mime_type) do
    content_ref = make_ref()
    Heap.put_obj(content_ref, content)

    blob_ctor = get_blob_ctor()
    blob_proto = Runtime.global_class_proto("Blob")

    object do
      prop("size", byte_size(content))
      prop("type", mime_type)
      prop("constructor", blob_ctor)
      prop("__proto__", blob_proto)

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

        start_idx = args |> arg(0, 0) |> normalize_slice_idx(total)
        end_idx = args |> arg(1, total) |> normalize_slice_idx(total)
        new_mime = args |> arg(2, mime_type) |> to_string()

        slice_len = max(0, end_idx - start_idx)
        sliced = binary_part(raw, min(start_idx, total), min(slice_len, total - start_idx))
        build_blob_object(sliced, new_mime)
      end

      method "stream" do
        :undefined
      end
    end
  end

  defp get_blob_ctor, do: Runtime.global_constructor("Blob")

  defp normalize_slice_idx(idx, total) when is_integer(idx) do
    cond do
      idx < 0 -> max(0, total + idx)
      idx > total -> total
      true -> idx
    end
  end

  defp normalize_slice_idx(idx, total) when is_float(idx),
    do: normalize_slice_idx(trunc(idx), total)

  defp normalize_slice_idx(:undefined, total), do: total
  defp normalize_slice_idx(nil, total), do: total
  defp normalize_slice_idx(_, _), do: 0

  defp extract_content(nil), do: ""
  defp extract_content(:undefined), do: ""

  defp extract_content({:obj, _} = arr) do
    arr
    |> Heap.to_list()
    |> parts_to_binary()
  end

  defp extract_content(list) when is_list(list), do: parts_to_binary(list)

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
        bytes_from_list(list)

      _ ->
        Values.stringify(obj)
    end
  end

  defp part_to_binary(v), do: Values.stringify(v)

  defp parts_to_binary(parts) do
    for part <- parts, into: <<>>, do: part_to_binary(part)
  end

  defp bytes_from_list(list) do
    for value <- list, into: <<>> do
      case value do
        n when is_integer(n) -> <<n>>
        _ -> <<0>>
      end
    end
  end

  defp make_array_buffer(data) when is_binary(data), do: BinaryData.array_buffer(data)

  defp make_uint8_from_binary(data) when is_binary(data), do: BinaryData.uint8_array(data)
end
