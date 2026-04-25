defmodule QuickBEAM.VM.Runtime.Web.URL do
  @moduledoc "URL and URLSearchParams builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{
      "URL" => WebAPIs.register("URL", &build_url/2),
      "URLSearchParams" => WebAPIs.register("URLSearchParams", &build_url_search_params/2)
    }
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
        throw({:js_throw, Heap.make_error("Invalid URL: #{input_str}", "TypeError")})
    end
  end

  defp make_url_object(c) do
    search_params_obj = make_search_params_object(c["search"] || "")

    Heap.wrap(
      Map.merge(
        %{
          "href" => c["href"] || "",
          "origin" => c["origin"] || "",
          "protocol" => c["protocol"] || "",
          "username" => c["username"] || "",
          "password" => c["password"] || "",
          "hostname" => c["hostname"] || "",
          "port" => c["port"] || "",
          "pathname" => c["pathname"] || "",
          "search" => c["search"] || "",
          "hash" => c["hash"] || "",
          "searchParams" => search_params_obj
        },
        build_methods do
          method "toString" do
            Get.get(this, "href")
          end
        end
      )
    )
  end

  defp build_url_search_params(args, _this) do
    init = List.first(args, "")
    make_search_params_from_input(init)
  end

  defp make_search_params_object(search_str) do
    query =
      case search_str do
        "?" <> q -> q
        q -> q
      end

    make_search_params_from_input(query)
  end

  defp make_search_params_from_input(input) do
    entries =
      case input do
        s when is_binary(s) and s != "" -> QuickBEAM.URL.dissect_query([s])
        _ -> []
      end

    entries_ref = make_ref()
    Heap.put_obj(entries_ref, %{"entries" => entries})

    Heap.wrap(
      Map.merge(
        %{"__entries__" => {:obj, entries_ref}},
        build_methods do
          method "get" do
            [name | _] = args
            es = load_entries(this)

            case Enum.find(es, fn [k, _] -> k == to_string(name) end) do
              [_, v] -> v
              nil -> nil
            end
          end

          method "getAll" do
            [name | _] = args

            load_entries(this)
            |> Enum.filter(fn [k, _] -> k == to_string(name) end)
            |> Enum.map(fn [_, v] -> v end)
          end

          method "set" do
            [name, val | _] = args
            n = to_string(name)
            v = to_string(val)
            es = load_entries(this) |> Enum.reject(fn [k, _] -> k == n end)
            save_entries(this, es ++ [[n, v]])
            :undefined
          end

          method "append" do
            [name, val | _] = args
            n = to_string(name)
            v = to_string(val)
            save_entries(this, load_entries(this) ++ [[n, v]])
            :undefined
          end

          method "delete" do
            [name | _] = args
            n = to_string(name)
            save_entries(this, load_entries(this) |> Enum.reject(fn [k, _] -> k == n end))
            :undefined
          end

          method "has" do
            [name | _] = args
            n = to_string(name)
            Enum.any?(load_entries(this), fn [k, _] -> k == n end)
          end

          method "toString" do
            QuickBEAM.URL.compose_query([load_entries(this)])
          end

          method "keys" do
            load_entries(this) |> Enum.map(fn [k, _] -> k end)
          end

          method "values" do
            load_entries(this) |> Enum.map(fn [_, v] -> v end)
          end
        end
      )
    )
  end

  defp load_entries(this) do
    case Get.get(this, "__entries__") do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          %{"entries" => list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp save_entries(this, entries) do
    case Get.get(this, "__entries__") do
      {:obj, ref} -> Heap.put_obj(ref, %{"entries" => entries})
      _ -> :ok
    end
  end
end
