defmodule QuickBEAM.VM.Host.Web.FormData do
  @moduledoc "FormData constructor builtin for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, iterator_from: 1, object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Host.Callback
  alias QuickBEAM.VM.Host.Web.FormData.State
  alias QuickBEAM.VM.Host.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    WebAPIs.register_constructors([{"FormData", &build_form_data/2}])
  end

  defp build_form_data(_args, _this) do
    entries_ref = State.new()

    object do
      method "append" do
        [name, value, filename] = argv(args, [nil, nil, nil])
        entry = {to_string(name), coerce_entry_value(value, filename)}
        State.append(entries_ref, entry)
        :undefined
      end

      method "get" do
        name = args |> arg(0, nil) |> to_string()

        case Enum.find(State.entries(entries_ref), fn {key, _value} -> key == name end) do
          {_key, value} -> value
          nil -> nil
        end
      end

      method "getAll" do
        name = args |> arg(0, nil) |> to_string()

        entries_ref
        |> State.entries()
        |> Enum.filter(fn {key, _value} -> key == name end)
        |> Enum.map(fn {_key, value} -> value end)
        |> Heap.wrap()
      end

      method "set" do
        [name, value, filename] = argv(args, [nil, nil, nil])
        name = to_string(name)
        entry = {name, coerce_entry_value(value, filename)}

        State.replace(entries_ref, name, entry)
        :undefined
      end

      method "delete" do
        name = args |> arg(0, nil) |> to_string()

        State.delete(entries_ref, name)
        :undefined
      end

      method "has" do
        name = args |> arg(0, nil) |> to_string()
        Enum.any?(State.entries(entries_ref), fn {key, _value} -> key == name end)
      end

      method "forEach" do
        callback = arg(args, 0, nil)

        Enum.each(State.entries(entries_ref), fn {key, value} ->
          Callback.safe_invoke(callback, [value, key, this])
        end)

        :undefined
      end

      method "entries" do
        entries_ref
        |> State.entries()
        |> entry_pairs()
        |> iterator_from()
      end

      method "keys" do
        entries_ref
        |> State.entries()
        |> Enum.map(&elem(&1, 0))
        |> iterator_from()
      end

      method "values" do
        entries_ref
        |> State.entries()
        |> Enum.map(&elem(&1, 1))
        |> iterator_from()
      end

      symbol :iterator do
        method do
          entries_ref
          |> State.entries()
          |> entry_pairs()
          |> iterator_from()
        end
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
    QuickBEAM.VM.Host.Web.Blob.build_file([parts, name, opts], nil)
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

  @doc "Encodes FormData parts as a multipart/form-data payload."
  def encode_multipart(entries_ref) do
    fields =
      entries_ref
      |> State.entries()
      |> Enum.map(fn {name, value} ->
        case value do
          {:obj, _} = obj ->
            filename = Get.get(obj, "name") || "blob"
            mime = Get.get(obj, "type") || "application/octet-stream"
            {name, {get_blob_content(obj), filename: filename, content_type: mime}}

          str when is_binary(str) ->
            {name, str}

          other ->
            {name, QuickBEAM.VM.Semantics.Values.stringify(other)}
        end
      end)

    %{body: body, content_type: content_type} = Req.Utils.encode_form_multipart(fields)
    # Capitalize headers to match browser FormData behavior
    binary = body |> IO.iodata_to_binary() |> capitalize_multipart_headers()
    {binary, content_type}
  end

  defp capitalize_multipart_headers(body) do
    body
    |> String.replace("content-disposition:", "Content-Disposition:")
    |> String.replace("content-type:", "Content-Type:")
  end
end
