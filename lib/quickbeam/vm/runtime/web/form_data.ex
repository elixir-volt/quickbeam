defmodule QuickBEAM.VM.Runtime.Web.FormData do
  @moduledoc "FormData constructor builtin for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, iterator_from: 1, object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Web.Callback
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{"FormData" => WebAPIs.register("FormData", &build_form_data/2)}
  end

  defp build_form_data(_args, _this) do
    entries_ref = make_ref()
    Heap.put_obj(entries_ref, %{list: []})

    object do
      method "append" do
        [name, value, filename] = argv(args, [nil, nil, nil])
        entry = {to_string(name), coerce_entry_value(value, filename)}
        save_fd_entries(entries_ref, load_fd_entries(entries_ref) ++ [entry])
        :undefined
      end

      method "get" do
        name = args |> arg(0, nil) |> to_string()

        case Enum.find(load_fd_entries(entries_ref), fn {key, _value} -> key == name end) do
          {_key, value} -> value
          nil -> nil
        end
      end

      method "getAll" do
        name = args |> arg(0, nil) |> to_string()

        entries_ref
        |> load_fd_entries()
        |> Enum.filter(fn {key, _value} -> key == name end)
        |> Enum.map(fn {_key, value} -> value end)
        |> Heap.wrap()
      end

      method "set" do
        [name, value, filename] = argv(args, [nil, nil, nil])
        name = to_string(name)
        entry = {name, coerce_entry_value(value, filename)}

        entries =
          entries_ref
          |> load_fd_entries()
          |> Enum.reject(fn {key, _value} -> key == name end)

        save_fd_entries(entries_ref, entries ++ [entry])
        :undefined
      end

      method "delete" do
        name = args |> arg(0, nil) |> to_string()

        entries =
          entries_ref
          |> load_fd_entries()
          |> Enum.reject(fn {key, _value} -> key == name end)

        save_fd_entries(entries_ref, entries)
        :undefined
      end

      method "has" do
        name = args |> arg(0, nil) |> to_string()
        Enum.any?(load_fd_entries(entries_ref), fn {key, _value} -> key == name end)
      end

      method "forEach" do
        callback = arg(args, 0, nil)

        Enum.each(load_fd_entries(entries_ref), fn {key, value} ->
          Callback.safe_invoke(callback, [value, key, this])
        end)

        :undefined
      end

      method "entries" do
        entries_ref
        |> load_fd_entries()
        |> entry_pairs()
        |> iterator_from()
      end

      method "keys" do
        entries_ref
        |> load_fd_entries()
        |> Enum.map(&elem(&1, 0))
        |> iterator_from()
      end

      method "values" do
        entries_ref
        |> load_fd_entries()
        |> Enum.map(&elem(&1, 1))
        |> iterator_from()
      end

      symbol_method "Symbol.iterator" do
        entries_ref
        |> load_fd_entries()
        |> entry_pairs()
        |> iterator_from()
      end

      prop("__fd_ref__", entries_ref)
    end
  end

  defp entry_pairs(entries) do
    Enum.map(entries, fn {key, value} -> Heap.wrap([key, value]) end)
  end

  defp coerce_entry_value(value, filename_override) do
    case value do
      {:obj, _} = obj ->
        if blob_or_file?(obj) do
          name =
            case filename_override do
              nil -> get_file_name(obj)
              :undefined -> get_file_name(obj)
              n -> to_string(n)
            end

          wrap_as_file(obj, name)
        else
          to_string(value)
        end

      _ ->
        to_string(value)
    end
  end

  defp blob_or_file?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      m when is_map(m) -> Map.has_key?(m, "size") and Map.has_key?(m, "type")
      _ -> false
    end
  end

  defp get_file_name({:obj, _} = obj) do
    case Get.get(obj, "name") do
      n when is_binary(n) -> n
      _ -> "blob"
    end
  end

  defp wrap_as_file(blob_or_file, name) do
    content = get_blob_content(blob_or_file)
    mime_type = Get.get(blob_or_file, "type") |> to_string()
    parts = Heap.wrap([content])
    opts = Heap.wrap(%{"type" => mime_type})
    QuickBEAM.VM.Runtime.Web.Blob.build_file([parts, name, opts], nil)
  end

  defp get_blob_content({:obj, _} = blob) do
    case Get.get(blob, "text") do
      {:builtin, "text", cb} ->
        promise = cb.([], blob)

        case promise do
          {:obj, pref} ->
            case Heap.get_obj(pref, %{}) do
              %{} = m ->
                case {Map.get(m, "__promise_state__"), Map.get(m, "__promise_value__")} do
                  {:resolved, v} when is_binary(v) -> v
                  _ -> ""
                end

              _ ->
                ""
            end

          v when is_binary(v) ->
            v

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  def encode_multipart(entries_ref) do
    fields =
      entries_ref
      |> load_fd_entries()
      |> Enum.map(fn {name, value} ->
        case value do
          {:obj, _} = obj ->
            filename = Get.get(obj, "name") || "blob"
            mime = Get.get(obj, "type") || "application/octet-stream"
            {name, {get_blob_content(obj), filename: filename, content_type: mime}}

          str when is_binary(str) ->
            {name, str}

          other ->
            {name, QuickBEAM.VM.Interpreter.Values.stringify(other)}
        end
      end)

    %{body: body, content_type: content_type} = Req.Utils.encode_form_multipart(fields)
    # Capitalize headers to match browser FormData behavior
    binary = body |> IO.iodata_to_binary() |> capitalize_multipart_headers()
    {binary, content_type}
  end

  defp load_fd_entries(ref) do
    case Heap.get_obj(ref, %{}) do
      %{list: list} when is_list(list) -> list
      _ -> []
    end
  end

  defp save_fd_entries(ref, entries) do
    Heap.put_obj(ref, %{list: entries})
  end

  defp capitalize_multipart_headers(body) do
    body
    |> String.replace("content-disposition:", "Content-Disposition:")
    |> String.replace("content-type:", "Content-Type:")
  end
end
