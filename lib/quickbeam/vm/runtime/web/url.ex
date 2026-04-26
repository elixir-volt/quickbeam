defmodule QuickBEAM.VM.Runtime.Web.URL do
  @moduledoc "URL and URLSearchParams builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.Get
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

    setters = %{
      "href" =>
        {:accessor,
         {:builtin, "get href", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["href"] || "" end},
         {:builtin, "set href",
          fn args, _ ->
            new_val = args |> List.first() |> to_string()
            case QuickBEAM.URL.parse([new_val]) do
              %{"ok" => true, "components" => new_c} ->
                Heap.put_obj(url_ref, new_c)
              _ -> :ok
            end
            :undefined
          end}},
      "protocol" =>
        {:accessor,
         {:builtin, "get protocol", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["protocol"] || "" end},
         {:builtin, "set protocol",
          fn args, _ ->
            update_url_component(url_ref, "protocol", args |> List.first() |> to_string())
          end}},
      "username" =>
        {:accessor,
         {:builtin, "get username", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["username"] || "" end},
         {:builtin, "set username",
          fn args, _ ->
            update_url_component(url_ref, "username", args |> List.first() |> to_string())
          end}},
      "password" =>
        {:accessor,
         {:builtin, "get password", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["password"] || "" end},
         {:builtin, "set password",
          fn args, _ ->
            update_url_component(url_ref, "password", args |> List.first() |> to_string())
          end}},
      "hostname" =>
        {:accessor,
         {:builtin, "get hostname", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["hostname"] || "" end},
         {:builtin, "set hostname",
          fn args, _ ->
            update_url_component(url_ref, "hostname", args |> List.first() |> to_string())
          end}},
      "port" =>
        {:accessor,
         {:builtin, "get port", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["port"] || "" end},
         {:builtin, "set port",
          fn args, _ ->
            update_url_component(url_ref, "port", args |> List.first() |> to_string())
          end}},
      "pathname" =>
        {:accessor,
         {:builtin, "get pathname", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["pathname"] || "" end},
         {:builtin, "set pathname",
          fn args, _ ->
            update_url_component(url_ref, "pathname", args |> List.first() |> to_string())
          end}},
      "search" =>
        {:accessor,
         {:builtin, "get search", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["search"] || "" end},
         {:builtin, "set search",
          fn args, _ ->
            new_search = args |> List.first() |> to_string()
            update_url_component(url_ref, "search", new_search)
            new_search_norm = if String.starts_with?(new_search, "?"), do: new_search, else: "?" <> new_search
            new_search_query = if new_search == "" or new_search == "?", do: "", else: new_search_norm
            sync_search_params_from_url(search_params_obj, new_search_query)
          end}},
      "hash" =>
        {:accessor,
         {:builtin, "get hash", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["hash"] || "" end},
         {:builtin, "set hash",
          fn args, _ ->
            new_hash = args |> List.first() |> to_string()
            update_url_component(url_ref, "hash", new_hash)
          end}},
      "host" =>
        {:accessor,
         {:builtin, "get host",
          fn _, _ ->
            c = Heap.get_obj(url_ref, %{}) || %{}
            hostname = c["hostname"] || ""
            port = c["port"] || ""
            if port == "", do: hostname, else: "#{hostname}:#{port}"
          end},
         nil},
      "origin" =>
        {:accessor,
         {:builtin, "get origin", fn _, _ -> (Heap.get_obj(url_ref, %{}) || %{})["origin"] || "" end},
         nil}
    }

    methods =
      build_methods do
        method "toString" do
          (Heap.get_obj(url_ref, %{}) || %{})["href"] || ""
        end

        method "toJSON" do
          (Heap.get_obj(url_ref, %{}) || %{})["href"] || ""
        end
      end

    all_props =
      Map.merge(methods, setters)
      |> Map.put("searchParams", search_params_obj)

    Heap.wrap(all_props)
  end

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
      %{"ok" => true, "components" => new_c} -> new_c
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
        query = case new_search do
          "?" <> q -> q
          q -> q
        end

        entries = if query == "" do
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
    init = List.first(args, "")
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
          q = case s do
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

    sym_iter = {:symbol, "Symbol.iterator"}

    entries_fn =
      {:builtin, "entries",
       fn _args, _this ->
         es = load_entries_ref(entries_ref)
         items = Enum.map(es, fn [k, v] -> Heap.wrap([k, v]) end)
         make_iterable_iterator(Heap.wrap_iterator(items))
       end}

    keys_fn =
      {:builtin, "keys",
       fn _args, _this ->
         es = load_entries_ref(entries_ref)
         make_iterable_iterator(Heap.wrap_iterator(Enum.map(es, fn [k, _] -> k end)))
       end}

    values_fn =
      {:builtin, "values",
       fn _args, _this ->
         es = load_entries_ref(entries_ref)
         make_iterable_iterator(Heap.wrap_iterator(Enum.map(es, fn [_, v] -> v end)))
       end}

    iter_fn =
      {:builtin, "[Symbol.iterator]",
       fn _args, _this ->
         es = load_entries_ref(entries_ref)
         items = Enum.map(es, fn [k, v] -> Heap.wrap([k, v]) end)
         make_iterable_iterator(Heap.wrap_iterator(items))
       end}

    base_methods =
      build_methods do
        method "get" do
          [name | _] = args
          es = load_entries_ref(entries_ref)

          case Enum.find(es, fn [k, _] -> k == to_string(name) end) do
            [_, v] -> v
            nil -> nil
          end
        end

        method "getAll" do
          [name | _] = args

          load_entries_ref(entries_ref)
          |> Enum.filter(fn [k, _] -> k == to_string(name) end)
          |> Enum.map(fn [_, v] -> v end)
          |> Heap.wrap()
        end

        method "set" do
          [name, val | _] = args
          n = to_string(name)
          v = to_string(val)
          es = load_entries_ref(entries_ref) |> Enum.reject(fn [k, _] -> k == n end)
          save_entries_ref(entries_ref, es ++ [[n, v]])
          sync_url_search(url_ref, entries_ref)
          :undefined
        end

        method "append" do
          [name, val | _] = args
          n = to_string(name)
          v = to_string(val)
          save_entries_ref(entries_ref, load_entries_ref(entries_ref) ++ [[n, v]])
          sync_url_search(url_ref, entries_ref)
          :undefined
        end

        method "delete" do
          [name | rest] = args
          n = to_string(name)

          updated =
            case rest do
              [val | _] when val != :undefined and val != nil ->
                v = to_string(val)
                load_entries_ref(entries_ref) |> Enum.reject(fn [k, ev] -> k == n and ev == v end)

              _ ->
                load_entries_ref(entries_ref) |> Enum.reject(fn [k, _] -> k == n end)
            end

          save_entries_ref(entries_ref, updated)
          sync_url_search(url_ref, entries_ref)
          :undefined
        end

        method "has" do
          [name | _] = args
          n = to_string(name)
          Enum.any?(load_entries_ref(entries_ref), fn [k, _] -> k == n end)
        end

        method "sort" do
          es = load_entries_ref(entries_ref)
          sorted = Enum.sort_by(es, fn [k, _] -> k end)
          save_entries_ref(entries_ref, sorted)
          sync_url_search(url_ref, entries_ref)
          :undefined
        end

        method "toString" do
          result = QuickBEAM.URL.compose_query([load_entries_ref(entries_ref)])
          IO.iodata_to_binary(result)
        end

        method "keys" do
          es = load_entries_ref(entries_ref)
          make_iterable_iterator(Heap.wrap_iterator(Enum.map(es, fn [k, _] -> k end)))
        end

        method "values" do
          es = load_entries_ref(entries_ref)
          make_iterable_iterator(Heap.wrap_iterator(Enum.map(es, fn [_, v] -> v end)))
        end

        method "forEach" do
          [callback | _] = args ++ [nil]
          es = load_entries_ref(entries_ref)

          Enum.each(es, fn [k, v] ->
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

    size_accessor =
      {:accessor,
       {:builtin, "get size", fn _, _ -> length(load_entries_ref(entries_ref)) end},
       nil}

    Map.merge(base_methods, %{
      "size" => size_accessor,
      "entries" => entries_fn,
      "keys" => keys_fn,
      "values" => values_fn,
      sym_iter => iter_fn,
      "__entries__" => {:obj, entries_ref}
    })
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

  defp make_iterable_iterator({:obj, ref} = iter) do
    sym_iter = {:symbol, "Symbol.iterator"}

    Heap.update_obj(ref, %{}, fn m ->
      Map.put(m, sym_iter, {:builtin, "[Symbol.iterator]", fn _, this -> this end})
    end)

    iter
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
