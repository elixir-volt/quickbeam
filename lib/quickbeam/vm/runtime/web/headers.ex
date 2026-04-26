defmodule QuickBEAM.VM.Runtime.Web.Headers do
  @moduledoc "Headers constructor builtin for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, iterator_from: 1, object: 1]

  alias Mint.Core.Headers, as: MintHeaders
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Web.Callback
  alias QuickBEAM.VM.Runtime.WebAPIs

  @doc "Returns the global binding for the JavaScript `Headers` constructor."
  def bindings do
    %{"Headers" => WebAPIs.register("Headers", &build_headers/2)}
  end

  @doc "Builds a `Headers` object backed by the supplied normalized header map."
  def build_from_map(initial_map) do
    store_ref = make_ref()
    Heap.put_obj(store_ref, initial_map)

    object do
      method "get" do
        Map.get(load_store_ref(store_ref), header_name(arg(args, 0, nil)), nil)
      end

      method "set" do
        [name, value] = argv(args, [nil, nil])
        store = Map.put(load_store_ref(store_ref), header_name(name), to_string(value))
        save_store_ref(store_ref, store)
        :undefined
      end

      method "append" do
        [name, value] = argv(args, [nil, nil])
        name = header_name(name)
        value = to_string(value)
        store = load_store_ref(store_ref)
        value = store |> Map.get(name) |> append_header_value(value)
        save_store_ref(store_ref, Map.put(store, name, value))
        :undefined
      end

      method "delete" do
        store = Map.delete(load_store_ref(store_ref), header_name(arg(args, 0, nil)))
        save_store_ref(store_ref, store)
        :undefined
      end

      method "has" do
        Map.has_key?(load_store_ref(store_ref), header_name(arg(args, 0, nil)))
      end

      method "forEach" do
        callback = arg(args, 0, nil)

        Enum.each(sorted_headers(store_ref), fn {name, value} ->
          Callback.safe_invoke(callback, [value, name])
        end)

        :undefined
      end

      method "entries" do
        store_ref
        |> sorted_headers()
        |> Enum.map(fn {name, value} -> Heap.wrap([name, value]) end)
        |> iterator_from()
      end

      method "keys" do
        store_ref
        |> sorted_headers()
        |> Enum.map(&elem(&1, 0))
        |> iterator_from()
      end

      method "values" do
        store_ref
        |> sorted_headers()
        |> Enum.map(&elem(&1, 1))
        |> iterator_from()
      end

      symbol_method "Symbol.iterator" do
        store_ref
        |> sorted_headers()
        |> Enum.map(fn {name, value} -> Heap.wrap([name, value]) end)
        |> iterator_from()
      end

      prop("__store__", {:obj, store_ref})
    end
  end

  defp build_headers(args, _this) do
    args
    |> List.first()
    |> extract_headers_map()
    |> build_from_map()
  end

  defp extract_headers_map(nil), do: %{}
  defp extract_headers_map(:undefined), do: %{}

  defp extract_headers_map({:obj, ref}) do
    raw = Heap.get_obj(ref, %{})

    cond do
      is_list(raw) ->
        pairs_to_map(raw)

      match?({:qb_arr, _}, raw) ->
        ref
        |> Heap.obj_to_list()
        |> pairs_to_map()

      is_map(raw) ->
        case Map.get(raw, "__store__") do
          {:obj, store_ref} ->
            load_store_ref(store_ref)

          _ ->
            raw
            |> Enum.reject(fn {key, _value} ->
              not is_binary(key) or String.starts_with?(key, "__")
            end)
            |> Enum.map(fn {key, value} -> {header_name(key), to_string(value)} end)
            |> Map.new()
        end

      true ->
        %{}
    end
  end

  defp extract_headers_map(_), do: %{}

  defp extract_pair({:obj, ref}) do
    list =
      case Heap.get_obj(ref, []) do
        {:qb_arr, _} -> Heap.obj_to_list(ref)
        l when is_list(l) -> l
        _ -> []
      end

    case list do
      [k, v | _] -> {header_name(k), to_string(v)}
      _ -> nil
    end
  end

  defp extract_pair(list) when is_list(list) do
    case list do
      [k, v | _] -> {header_name(k), to_string(v)}
      _ -> nil
    end
  end

  defp extract_pair(_), do: nil

  defp pairs_to_map(pairs) do
    pairs
    |> Enum.map(&extract_pair/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp sorted_headers(store_ref) do
    store_ref
    |> load_store_ref()
    |> Enum.sort_by(fn {name, _value} -> name end)
  end

  @doc "Normalizes a header name using Mint's ASCII header canonicalization."
  def header_name(value), do: value |> to_string() |> MintHeaders.lower_raw()

  defp append_header_value(nil, value), do: value
  defp append_header_value(existing, value), do: existing <> ", " <> value

  defp load_store_ref(store_ref) do
    case Heap.get_obj(store_ref, %{}) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp save_store_ref(store_ref, store) do
    Heap.put_obj(store_ref, store)
  end
end
