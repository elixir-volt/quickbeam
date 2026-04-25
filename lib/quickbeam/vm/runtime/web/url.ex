defmodule QuickBEAM.VM.Runtime.Web.URL do
  @moduledoc "URL and URLSearchParams builtins for BEAM mode."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get

  def bindings do
    %{
      "URL" => register("URL", &build_url/2),
      "URLSearchParams" => register("URLSearchParams", &build_url_search_params/2)
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

    Heap.wrap(%{
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
      "searchParams" => search_params_obj,
      "toString" => {:builtin, "toString", fn _, this -> Get.get(this, "href") end}
    })
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
    Process.put(entries_ref, entries)

    Heap.wrap(%{
      "__entries__" => {:obj, entries_ref},
      "get" =>
        {:builtin, "get",
         fn [name | _], this ->
           es = load_entries(this)

           case Enum.find(es, fn [k, _] -> k == to_string(name) end) do
             [_, v] -> v
             nil -> nil
           end
         end},
      "getAll" =>
        {:builtin, "getAll",
         fn [name | _], this ->
           load_entries(this)
           |> Enum.filter(fn [k, _] -> k == to_string(name) end)
           |> Enum.map(fn [_, v] -> v end)
         end},
      "set" =>
        {:builtin, "set",
         fn [name, val | _], this ->
           n = to_string(name)
           v = to_string(val)
           es = load_entries(this) |> Enum.reject(fn [k, _] -> k == n end)
           save_entries(this, es ++ [[n, v]])
           :undefined
         end},
      "append" =>
        {:builtin, "append",
         fn [name, val | _], this ->
           n = to_string(name)
           v = to_string(val)
           save_entries(this, load_entries(this) ++ [[n, v]])
           :undefined
         end},
      "delete" =>
        {:builtin, "delete",
         fn [name | _], this ->
           n = to_string(name)
           save_entries(this, load_entries(this) |> Enum.reject(fn [k, _] -> k == n end))
           :undefined
         end},
      "has" =>
        {:builtin, "has",
         fn [name | _], this ->
           n = to_string(name)
           Enum.any?(load_entries(this), fn [k, _] -> k == n end)
         end},
      "toString" =>
        {:builtin, "toString",
         fn _, this ->
           QuickBEAM.URL.compose_query([load_entries(this)])
         end},
      "keys" =>
        {:builtin, "keys",
         fn _, this -> load_entries(this) |> Enum.map(fn [k, _] -> k end) end},
      "values" =>
        {:builtin, "values",
         fn _, this -> load_entries(this) |> Enum.map(fn [_, v] -> v end) end}
    })
  end

  defp load_entries(this) do
    case Get.get(this, "__entries__") do
      {:obj, ref} -> Process.get(ref, [])
      _ -> []
    end
  end

  defp save_entries(this, entries) do
    case Get.get(this, "__entries__") do
      {:obj, ref} -> Process.put(ref, entries)
      _ -> :ok
    end
  end

  defp register(name, constructor) do
    ctor = {:builtin, name, constructor}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end
end
