defmodule QuickBEAM.VM.Runtime.Web.Headers do
  @moduledoc "Headers constructor builtin for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{"Headers" => WebAPIs.register("Headers", &build_headers/2)}
  end

  def build_from_map(initial_map) do
    store_ref = make_ref()
    Heap.put_obj(store_ref, initial_map)

    sym_iter = {:symbol, "Symbol.iterator"}

    entries_fn =
      {:builtin, "entries",
       fn _args, _this ->
         store = load_store_ref(store_ref)
         items = store |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(fn {k, v} -> Heap.wrap([k, v]) end)
         make_iterable_iterator(Heap.wrap_iterator(items))
       end}

    keys_fn =
      {:builtin, "keys",
       fn _args, _this ->
         store = load_store_ref(store_ref)
         keys = store |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(fn {k, _} -> k end)
         make_iterable_iterator(Heap.wrap_iterator(keys))
       end}

    values_fn =
      {:builtin, "values",
       fn _args, _this ->
         store = load_store_ref(store_ref)
         vals = store |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(fn {_, v} -> v end)
         make_iterable_iterator(Heap.wrap_iterator(vals))
       end}

    iter_fn =
      {:builtin, "[Symbol.iterator]",
       fn _args, _this ->
         store = load_store_ref(store_ref)
         items = store |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(fn {k, v} -> Heap.wrap([k, v]) end)
         make_iterable_iterator(Heap.wrap_iterator(items))
       end}

    for_each_fn =
      {:builtin, "forEach",
       fn args, _this ->
         [callback | _] = args ++ [nil]
         store = load_store_ref(store_ref)
         sorted = Enum.sort_by(store, fn {k, _} -> k end)

         Enum.each(sorted, fn {k, v} ->
           try do
             QuickBEAM.VM.Invocation.invoke_with_receiver(callback, [v, k], :undefined)
           rescue
             _ -> :ok
           catch
             _, _ -> :ok
           end
         end)

         :undefined
       end}

    base_methods =
      build_methods do
        method "get" do
          [name | _] = args
          Map.get(load_store_ref(store_ref), String.downcase(to_string(name)), nil)
        end

        method "set" do
          [name, val | _] = args
          store = load_store_ref(store_ref)
          save_store_ref(store_ref, Map.put(store, String.downcase(to_string(name)), to_string(val)))
          :undefined
        end

        method "append" do
          [name, val | _] = args
          k = String.downcase(to_string(name))
          store = load_store_ref(store_ref)
          existing = Map.get(store, k, nil)
          new_val = if existing, do: existing <> ", " <> to_string(val), else: to_string(val)
          save_store_ref(store_ref, Map.put(store, k, new_val))
          :undefined
        end

        method "delete" do
          [name | _] = args
          save_store_ref(store_ref, Map.delete(load_store_ref(store_ref), String.downcase(to_string(name))))
          :undefined
        end

        method "has" do
          [name | _] = args
          Map.has_key?(load_store_ref(store_ref), String.downcase(to_string(name)))
        end
      end

    Map.merge(base_methods, %{
      "entries" => entries_fn,
      "keys" => keys_fn,
      "values" => values_fn,
      "forEach" => for_each_fn,
      sym_iter => iter_fn,
      "__store__" => {:obj, store_ref}
    })
    |> Heap.wrap()
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
        raw
        |> Enum.map(&extract_pair/1)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      match?({:qb_arr, _}, raw) ->
        Heap.obj_to_list(ref)
        |> Enum.map(&extract_pair/1)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      is_map(raw) ->
        case Map.get(raw, "__store__") do
          {:obj, store_ref} ->
            load_store_ref(store_ref)

          _ ->
            raw
            |> Enum.reject(fn {k, _} -> not is_binary(k) or String.starts_with?(k, "__") end)
            |> Enum.map(fn {k, v} -> {String.downcase(k), to_string(v)} end)
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
      [k, v | _] -> {String.downcase(to_string(k)), to_string(v)}
      _ -> nil
    end
  end

  defp extract_pair(list) when is_list(list) do
    case list do
      [k, v | _] -> {String.downcase(to_string(k)), to_string(v)}
      _ -> nil
    end
  end

  defp extract_pair(_), do: nil

  defp load_store_ref(store_ref) do
    case Heap.get_obj(store_ref, %{}) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp save_store_ref(store_ref, store) do
    Heap.put_obj(store_ref, store)
  end

  defp make_iterable_iterator(iter) do
    sym_iter = {:symbol, "Symbol.iterator"}

    case iter do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, fn m ->
          Map.put(m, sym_iter, {:builtin, "[Symbol.iterator]", fn _, this -> this end})
        end)

        iter

      _ ->
        iter
    end
  end
end
