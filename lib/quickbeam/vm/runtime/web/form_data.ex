defmodule QuickBEAM.VM.Runtime.Web.FormData do
  @moduledoc "FormData constructor builtin for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{"FormData" => WebAPIs.register("FormData", &build_form_data/2)}
  end

  defp build_form_data(_args, _this) do
    entries_ref = make_ref()
    Heap.put_obj(entries_ref, %{list: []})

    sym_iter = {:symbol, "Symbol.iterator"}

    entries_fn =
      {:builtin, "entries",
       fn _args, _this ->
         entries = load_fd_entries(entries_ref)
         items = Enum.map(entries, fn {k, v} -> Heap.wrap([k, v]) end)
         iter = Heap.wrap_iterator(items)
         make_iterable_iterator(iter)
       end}

    keys_fn =
      {:builtin, "keys",
       fn _args, _this ->
         entries = load_fd_entries(entries_ref)
         keys = Enum.map(entries, fn {k, _} -> k end)
         iter = Heap.wrap_iterator(keys)
         make_iterable_iterator(iter)
       end}

    values_fn =
      {:builtin, "values",
       fn _args, _this ->
         entries = load_fd_entries(entries_ref)
         vals = Enum.map(entries, fn {_, v} -> v end)
         iter = Heap.wrap_iterator(vals)
         make_iterable_iterator(iter)
       end}

    iter_fn =
      {:builtin, "[Symbol.iterator]",
       fn _args, _this ->
         entries = load_fd_entries(entries_ref)
         items = Enum.map(entries, fn {k, v} -> Heap.wrap([k, v]) end)
         iter = Heap.wrap_iterator(items)
         make_iterable_iterator(iter)
       end}

    base_methods =
      build_methods do
        method "append" do
          [name, value | rest] = args ++ [nil, nil, nil]
          n = to_string(name)
          filename_override = List.first(rest)
          entry_val = coerce_entry_value(value, filename_override)
          entries = load_fd_entries(entries_ref)
          save_fd_entries(entries_ref, entries ++ [{n, entry_val}])
          :undefined
        end

        method "get" do
          [name | _] = args
          n = to_string(name)
          entries = load_fd_entries(entries_ref)

          case Enum.find(entries, fn {k, _} -> k == n end) do
            {_, v} -> v
            nil -> nil
          end
        end

        method "getAll" do
          [name | _] = args
          n = to_string(name)

          entries_ref
          |> load_fd_entries()
          |> Enum.filter(fn {k, _} -> k == n end)
          |> Enum.map(fn {_, v} -> v end)
          |> Heap.wrap()
        end

        method "set" do
          [name, value | rest] = args ++ [nil, nil, nil]
          n = to_string(name)
          filename_override = List.first(rest)
          entry_val = coerce_entry_value(value, filename_override)
          filtered = entries_ref |> load_fd_entries() |> Enum.reject(fn {k, _} -> k == n end)
          save_fd_entries(entries_ref, filtered ++ [{n, entry_val}])
          :undefined
        end

        method "delete" do
          [name | _] = args
          n = to_string(name)
          updated = entries_ref |> load_fd_entries() |> Enum.reject(fn {k, _} -> k == n end)
          save_fd_entries(entries_ref, updated)
          :undefined
        end

        method "has" do
          [name | _] = args
          n = to_string(name)
          Enum.any?(load_fd_entries(entries_ref), fn {k, _} -> k == n end)
        end

        method "forEach" do
          [callback | _] = args ++ [nil]
          entries = load_fd_entries(entries_ref)

          Enum.each(entries, fn {k, v} ->
            try do
              Invocation.invoke_with_receiver(callback, [v, k, this], :undefined)
            rescue
              _ -> :ok
            catch
              _, _ -> :ok
            end
          end)

          :undefined
        end
      end

    Map.merge(base_methods, %{
      "entries" => entries_fn,
      "keys" => keys_fn,
      "values" => values_fn,
      sym_iter => iter_fn,
      "__fd_ref__" => entries_ref
    })
    |> Heap.wrap()
  end

  defp make_iterable_iterator({:obj, ref} = iter) do
    sym_iter = {:symbol, "Symbol.iterator"}

    Heap.update_obj(ref, %{}, fn m ->
      Map.put(m, sym_iter, {:builtin, "[Symbol.iterator]", fn _, this -> this end})
    end)

    iter
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
              _ -> ""
            end

          v when is_binary(v) -> v
          _ -> ""
        end

      _ ->
        ""
    end
  end

  def encode_multipart(entries_ref) do
    boundary = "----FormBoundary" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    entries = load_fd_entries(entries_ref)

    body =
      entries
      |> Enum.map_join("", fn {name, value} ->
        "--#{boundary}\r\n#{encode_part(name, value)}\r\n"
      end)
      |> Kernel.<>("--#{boundary}--\r\n")

    {body, "multipart/form-data; boundary=#{boundary}"}
  end

  defp encode_part(name, {:obj, _} = obj) do
    filename = Get.get(obj, "name") || "blob"
    mime = Get.get(obj, "type") || "application/octet-stream"
    content = get_blob_content(obj)
    "Content-Disposition: form-data; name=#{quote_param(name)}; filename=#{quote_param(filename)}\r\nContent-Type: #{mime}\r\n\r\n#{content}"
  end

  defp encode_part(name, value) when is_binary(value) do
    "Content-Disposition: form-data; name=#{quote_param(name)}\r\n\r\n#{value}"
  end

  defp encode_part(name, value) do
    "Content-Disposition: form-data; name=#{quote_param(name)}\r\n\r\n#{QuickBEAM.VM.Interpreter.Values.stringify(value)}"
  end

  defp quote_param(s), do: "\"#{s}\""

  defp load_fd_entries(ref) do
    case Heap.get_obj(ref, %{}) do
      %{list: list} when is_list(list) -> list
      _ -> []
    end
  end

  defp save_fd_entries(ref, entries) do
    Heap.put_obj(ref, %{list: entries})
  end
end
