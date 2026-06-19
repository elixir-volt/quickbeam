defmodule QuickBEAM.VM.Host.Web.Headers do
  @moduledoc "Headers constructor builtin for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, iterator_from: 1, object: 1]
  import QuickBEAM.VM.Heap.Keys, only: [internal_namespace?: 1]

  alias Mint.Core.Headers, as: MintHeaders
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.Callback
  alias QuickBEAM.VM.Host.WebAPIs

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
        this_arg = arg(args, 1, :undefined)

        Enum.each(sorted_headers(store_ref), fn {name, value} ->
          Callback.invoke(callback, [value, name, this], this_arg)
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

      symbol :iterator do
        method do
          store_ref
          |> sorted_headers()
          |> Enum.map(fn {name, value} -> Heap.wrap([name, value]) end)
          |> iterator_from()
        end
      end

      prop("__store__", {:obj, store_ref})
    end
  end

  defp build_headers(args, _this) do
    args
    |> List.first()
    |> to_map()
    |> build_from_map()
  end

  @doc "Converts a HeadersInit value or Headers object into a normalized header map."
  def to_map(value, opts \\ [])

  def to_map(nil, _opts), do: %{}
  def to_map(:undefined, _opts), do: %{}

  def to_map({:obj, ref}, opts) do
    skip_internal_values? = Keyword.get(opts, :skip_internal_values, false)
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
            |> Enum.reject(fn {key, value} ->
              not is_binary(key) or internal_namespace?(key) or
                internal_header_value?(value, skip_internal_values?)
            end)
            |> Enum.map(fn {key, value} -> {header_name(key), to_string(value)} end)
            |> Map.new()
        end

      true ->
        %{}
    end
  end

  def to_map(_value, _opts), do: %{}

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

  @doc "Appends a normalized header pair to a map using Headers append semantics."
  def append_to_map(map, name, value) do
    Map.update(
      map,
      header_name(name),
      to_string(value),
      &append_header_value(&1, to_string(value))
    )
  end

  defp pairs_to_map(pairs) do
    pairs
    |> Enum.map(&extract_pair/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn {name, value}, acc -> append_to_map(acc, name, value) end)
  end

  defp internal_header_value?(value, true), do: is_atom(value) or is_tuple(value)
  defp internal_header_value?(_value, _skip_internal_values?), do: false

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
