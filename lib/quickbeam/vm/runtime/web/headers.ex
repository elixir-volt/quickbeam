defmodule QuickBEAM.VM.Runtime.Web.Headers do
  @moduledoc "Headers constructor builtin for BEAM mode."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get

  def bindings do
    %{"Headers" => register("Headers", &build_headers/2)}
  end

  def build_from_map(initial_map) do
    store_ref = make_ref()
    Heap.put_obj(store_ref, initial_map)

    Heap.wrap(%{
      "__store__" => {:obj, store_ref},
      "get" =>
        {:builtin, "get",
         fn [name | _], this ->
           Map.get(load_store(this), String.downcase(to_string(name)), nil)
         end},
      "set" =>
        {:builtin, "set",
         fn [name, val | _], this ->
           store = load_store(this)
           save_store(this, Map.put(store, String.downcase(to_string(name)), to_string(val)))
           :undefined
         end},
      "append" =>
        {:builtin, "append",
         fn [name, val | _], this ->
           k = String.downcase(to_string(name))
           store = load_store(this)
           existing = Map.get(store, k, nil)
           new_val = if existing, do: existing <> ", " <> to_string(val), else: to_string(val)
           save_store(this, Map.put(store, k, new_val))
           :undefined
         end},
      "delete" =>
        {:builtin, "delete",
         fn [name | _], this ->
           save_store(this, Map.delete(load_store(this), String.downcase(to_string(name))))
           :undefined
         end},
      "has" =>
        {:builtin, "has",
         fn [name | _], this ->
           Map.has_key?(load_store(this), String.downcase(to_string(name)))
         end}
    })
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
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        map
        |> Enum.reject(fn {k, _} -> not is_binary(k) or String.starts_with?(k, "__") end)
        |> Enum.map(fn {k, v} -> {String.downcase(k), to_string(v)} end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp extract_headers_map(_), do: %{}

  defp load_store(this) do
    case Get.get(this, "__store__") do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          m when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_store(this, store) do
    case Get.get(this, "__store__") do
      {:obj, ref} -> Heap.put_obj(ref, store)
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
