defmodule QuickBEAM.VM.Runtime.Web.URL do
  @moduledoc "URL and URLSearchParams builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin,
    only: [arg: 3, argv: 2, iterator_from: 1, object: 1, object: 2]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Web.Callback
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    url_ctor = build_url_ctor()

    %{
      "URL" => url_ctor,
      "URLSearchParams" => WebAPIs.register("URLSearchParams", &build_url_search_params/2)
    }
  end

  defp build_url_ctor do
    ctor = WebAPIs.register("URL", &build_url/2)

    Heap.put_ctor_static(
      ctor,
      "canParse",
      {:builtin, "canParse",
       fn args, _ ->
         [input | rest] =
           case args do
             [] -> [""]
             a -> a
           end

         input_str = to_string(input)

         base_str =
           case rest do
             [b | _] when is_binary(b) -> b
             _ -> nil
           end

         parse_args = if base_str, do: [input_str, base_str], else: [input_str]

         case QuickBEAM.URL.parse(parse_args) do
           %{"ok" => true} -> true
           _ -> false
         end
       end}
    )

    ctor
  end

  defp build_url(args, _this) do
    [input | rest] =
      case args do
        [] -> [""]
        a -> a
      end

    input_str = to_string(input)

    base_str =
      case rest do
        [b | _] when is_binary(b) -> b
        _ -> nil
      end

    parse_args = if base_str, do: [input_str, base_str], else: [input_str]

    case QuickBEAM.URL.parse(parse_args) do
      %{"ok" => true, "components" => c} ->
        make_url_object(c)

      _ ->
        JSThrow.type_error!("Invalid URL: #{input_str}")
    end
  end

  defp make_url_object(c) do
    url_ref = make_ref()
    Heap.put_obj(url_ref, c)

    search_params_obj = make_search_params_object(c["search"] || "", url_ref)

    object do
      prop("searchParams", search_params_obj)

      accessor "href" do
        get do
          url_component(url_ref, "href")
        end

        set do
          new_value = args |> arg(0, nil) |> to_string()

          case QuickBEAM.URL.parse([new_value]) do
            %{"ok" => true, "components" => components} -> Heap.put_obj(url_ref, components)
            _ -> :ok
          end

          :undefined
        end
      end

      accessor "protocol" do
        get do
          url_component(url_ref, "protocol")
        end

        set do
          update_url_component(url_ref, "protocol", args |> arg(0, nil) |> to_string())
        end
      end

      accessor "username" do
        get do
          url_component(url_ref, "username")
        end

        set do
          update_url_component(url_ref, "username", args |> arg(0, nil) |> to_string())
        end
      end

      accessor "password" do
        get do
          url_component(url_ref, "password")
        end

        set do
          update_url_component(url_ref, "password", args |> arg(0, nil) |> to_string())
        end
      end

      accessor "hostname" do
        get do
          url_component(url_ref, "hostname")
        end

        set do
          update_url_component(url_ref, "hostname", args |> arg(0, nil) |> to_string())
        end
      end

      accessor "port" do
        get do
          url_component(url_ref, "port")
        end

        set do
          update_url_component(url_ref, "port", args |> arg(0, nil) |> to_string())
        end
      end

      accessor "pathname" do
        get do
          url_component(url_ref, "pathname")
        end

        set do
          update_url_component(url_ref, "pathname", args |> arg(0, nil) |> to_string())
        end
      end

      accessor "search" do
        get do
          url_component(url_ref, "search")
        end

        set do
          new_search = args |> arg(0, nil) |> to_string()
          update_url_component(url_ref, "search", new_search)
          sync_search_params_from_url(search_params_obj, normalized_search(new_search))
        end
      end

      accessor "hash" do
        get do
          url_component(url_ref, "hash")
        end

        set do
          update_url_component(url_ref, "hash", args |> arg(0, nil) |> to_string())
        end
      end

      accessor "host" do
        get do
          components = Heap.get_obj(url_ref, %{}) || %{}
          hostname = components["hostname"] || ""
          port = components["port"] || ""
          if port == "", do: hostname, else: "#{hostname}:#{port}"
        end
      end

      accessor "origin" do
        get do
          url_component(url_ref, "origin")
        end
      end

      method "toString" do
        url_component(url_ref, "href")
      end

      method "toJSON" do
        url_component(url_ref, "href")
      end
    end
  end

  defp url_component(url_ref, component) do
    (Heap.get_obj(url_ref, %{}) || %{})[component] || ""
  end

  defp normalized_search(""), do: ""
  defp normalized_search("?"), do: ""
  defp normalized_search("?" <> _ = search), do: search
  defp normalized_search(search), do: "?" <> search

  defp update_url_component(url_ref, component, new_val) do
    c = Heap.get_obj(url_ref, %{}) || %{}
    updated = Map.put(c, component, new_val)
    recomposed = recompose_url(updated)
    Heap.put_obj(url_ref, recomposed)
    :undefined
  end

  defp recompose_url(c) do
    href = build_href_from_components(c)

    case QuickBEAM.URL.parse([href]) do
      %{"ok" => true, "components" => new_c} ->
        new_c

      _ ->
        # Fallback: just update href from components string
        Map.put(c, "href", href)
    end
  end

  defp build_href_from_components(c) do
    QuickBEAM.URL.recompose([c])
  rescue
    _ ->
      c["href"] || ""
  end

  defp sync_search_params_from_url(search_params_obj, new_search) do
    case Get.get(search_params_obj, "__entries__") do
      {:obj, ref} ->
        query =
          case new_search do
            "?" <> q -> q
            q -> q
          end

        entries =
          if query == "" do
            []
          else
            QuickBEAM.URL.dissect_query([query])
          end

        Heap.put_obj(ref, %{"entries" => entries})

      _ ->
        :ok
    end

    :undefined
  end

  defp build_url_search_params(args, _this) do
    init = arg(args, 0, "")
    make_search_params_from_input(init, nil)
  end

  defp make_search_params_object(search_str, url_ref) do
    query =
      case search_str do
        "?" <> q -> q
        q -> q
      end

    make_search_params_from_input(query, url_ref)
  end

  defp make_search_params_from_input(input, url_ref) do
    entries =
      case input do
        s when is_binary(s) and s != "" ->
          q =
            case s do
              "?" <> rest -> rest
              other -> other
            end

          if q == "", do: [], else: QuickBEAM.URL.dissect_query([q])

        {:obj, _} = obj ->
          raw = Heap.get_obj(elem(obj, 1), %{})

          cond do
            is_list(raw) ->
              Enum.flat_map(raw, &extract_kv_pair/1)

            match?({:qb_arr, _}, raw) ->
              Heap.obj_to_list(elem(obj, 1))
              |> Enum.flat_map(&extract_kv_pair/1)

            is_map(raw) ->
              raw
              |> Enum.reject(fn {k, _} -> not is_binary(k) or String.starts_with?(k, "__") end)
              |> Enum.map(fn {k, v} -> [to_string(k), to_string(v)] end)

            true ->
              []
          end

        _ ->
          []
      end

    entries_ref = make_ref()
    Heap.put_obj(entries_ref, %{"entries" => entries})

    object heap: false do
      method "get" do
        name = args |> arg(0, nil) |> to_string()

        case Enum.find(load_entries_ref(entries_ref), fn [key, _] -> key == name end) do
          [_, value] -> value
          nil -> nil
        end
      end

      method "getAll" do
        name = args |> arg(0, nil) |> to_string()

        entries_ref
        |> load_entries_ref()
        |> Enum.filter(fn [key, _] -> key == name end)
        |> Enum.map(fn [_, value] -> value end)
        |> Heap.wrap()
      end

      method "set" do
        [name, value] = argv(args, [nil, nil])
        name = to_string(name)
        value = to_string(value)

        entries =
          entries_ref
          |> load_entries_ref()
          |> Enum.reject(fn [key, _] -> key == name end)

        save_entries_ref(entries_ref, entries ++ [[name, value]])
        sync_url_search(url_ref, entries_ref)
        :undefined
      end

      method "append" do
        [name, value] = argv(args, [nil, nil])
        entry = [to_string(name), to_string(value)]
        save_entries_ref(entries_ref, load_entries_ref(entries_ref) ++ [entry])
        sync_url_search(url_ref, entries_ref)
        :undefined
      end

      method "delete" do
        [name, value] = argv(args, [nil, :undefined])
        name = to_string(name)

        entries =
          case value do
            value when value != :undefined and value != nil ->
              value = to_string(value)

              entries_ref
              |> load_entries_ref()
              |> Enum.reject(fn [key, entry_value] -> key == name and entry_value == value end)

            _ ->
              entries_ref |> load_entries_ref() |> Enum.reject(fn [key, _] -> key == name end)
          end

        save_entries_ref(entries_ref, entries)
        sync_url_search(url_ref, entries_ref)
        :undefined
      end

      method "has" do
        name = args |> arg(0, nil) |> to_string()
        Enum.any?(load_entries_ref(entries_ref), fn [key, _] -> key == name end)
      end

      method "sort" do
        entries = entries_ref |> load_entries_ref() |> Enum.sort_by(fn [key, _] -> key end)
        save_entries_ref(entries_ref, entries)
        sync_url_search(url_ref, entries_ref)
        :undefined
      end

      method "toString" do
        result = QuickBEAM.URL.compose_query([load_entries_ref(entries_ref)])
        IO.iodata_to_binary(result)
      end

      method "entries" do
        entries_ref
        |> load_entries_ref()
        |> search_param_pairs()
        |> iterator_from()
      end

      method "keys" do
        entries_ref
        |> load_entries_ref()
        |> Enum.map(fn [key, _] -> key end)
        |> iterator_from()
      end

      method "values" do
        entries_ref
        |> load_entries_ref()
        |> Enum.map(fn [_, value] -> value end)
        |> iterator_from()
      end

      method "forEach" do
        callback = arg(args, 0, nil)

        Enum.each(load_entries_ref(entries_ref), fn [key, value] ->
          Callback.safe_invoke(callback, [value, key, this])
        end)

        :undefined
      end

      symbol_method "Symbol.iterator" do
        entries_ref
        |> load_entries_ref()
        |> search_param_pairs()
        |> iterator_from()
      end

      accessor "size" do
        get do
          length(load_entries_ref(entries_ref))
        end
      end

      prop("__entries__", {:obj, entries_ref})
    end
    |> Heap.wrap()
  end

  defp sync_url_search(nil, _entries_ref), do: :ok

  defp sync_url_search(url_ref, entries_ref) do
    es = load_entries_ref(entries_ref)
    query_str = QuickBEAM.URL.compose_query([es]) |> IO.iodata_to_binary()
    new_search = if query_str == "", do: "", else: "?" <> query_str

    c = Heap.get_obj(url_ref, %{}) || %{}
    updated = Map.put(c, "search", new_search)
    recomposed = recompose_url(updated)
    Heap.put_obj(url_ref, recomposed)
  end

  defp load_entries_ref(entries_ref) do
    case Heap.get_obj(entries_ref, %{}) do
      %{"entries" => list} when is_list(list) -> list
      _ -> []
    end
  end

  defp save_entries_ref(entries_ref, entries) do
    Heap.put_obj(entries_ref, %{"entries" => entries})
  end

  defp search_param_pairs(entries) do
    Enum.map(entries, fn [key, value] -> Heap.wrap([key, value]) end)
  end

  defp extract_kv_pair({:obj, iref}) do
    raw = Heap.get_obj(iref, [])

    list =
      case raw do
        {:qb_arr, _} -> Heap.obj_to_list(iref)
        l when is_list(l) -> l
        _ -> []
      end

    case list do
      [k, v | _] -> [[to_string(k), to_string(v)]]
      _ -> []
    end
  end

  defp extract_kv_pair([k, v | _]), do: [[to_string(k), to_string(v)]]
  defp extract_kv_pair(_), do: []
end
