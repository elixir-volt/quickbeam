defmodule QuickBEAM.BeamVM.Runtime.JSON do
  @moduledoc "JSON.parse and JSON.stringify."

  use QuickBEAM.BeamVM.Builtin

  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime.Property

  js_object "JSON" do
    method "parse" do
      parse(args)
    end

    method "stringify" do
      stringify(args)
    end
  end

  defp parse([s | _]) when is_binary(s) do
    try do
      to_js(:json.decode(s))
    rescue
      _ -> throw({:js_throw, Heap.make_error("Unexpected end of JSON input", "SyntaxError")})
    catch
      _, _ -> throw({:js_throw, Heap.make_error("Unexpected end of JSON input", "SyntaxError")})
    end
  end

  defp parse(_),
    do: throw({:js_throw, Heap.make_error("Unexpected end of JSON input", "SyntaxError")})

  defp to_js(nil), do: nil
  defp to_js(:null), do: nil

  defp to_js(val) when is_map(val) do
    map = Map.new(val, fn {k, v} -> {k, to_js(v)} end)
    Heap.wrap(map)
  end

  defp to_js(val) when is_list(val), do: Enum.map(val, &to_js/1)
  defp to_js(val), do: val

  defp stringify([val | rest]) do
    if val == :undefined do
      :undefined
    else
      replacer = Enum.at(rest, 0)
      space = Enum.at(rest, 1)

      try do
        result = to_json(val)
        if result == :undefined, do: :undefined, else: encode(result, replacer, space)
      rescue
        _ -> :undefined
      end
    end
  end

  defp stringify([]), do: :undefined

  defp encode(result, replacer, space) do
    result = apply_replacer(result, replacer)
    elixir_val = to_elixir(result)

    opts = case space do
      n when is_integer(n) and n > 0 -> [pretty: [indent: String.duplicate(" ", min(n, 10))]]
      s when is_binary(s) and s != "" -> [pretty: [indent: String.slice(s, 0, 10)]]
      _ -> []
    end

    case Jason.encode(elixir_val, opts) do
      {:ok, json} -> json
      _ -> :undefined
    end
  end

  defp to_elixir({:ordered_map, pairs}) do
    Jason.OrderedObject.new(Enum.map(pairs, fn {k, v} -> {k, to_elixir(v)} end))
  end

  defp to_elixir(list) when is_list(list), do: Enum.map(list, &to_elixir/1)
  defp to_elixir(:null), do: nil
  defp to_elixir(val), do: val

  defp apply_replacer({:ordered_map, pairs}, {:obj, ref}) do
    allowed = Heap.to_list({:obj, ref})

    if allowed != [] and Enum.all?(allowed, &is_binary/1) do
      {:ordered_map, Enum.filter(pairs, fn {k, _} -> k in allowed end)}
    else
      {:ordered_map, pairs}
    end
  end

  defp apply_replacer({:ordered_map, pairs}, replacer) when replacer != nil and replacer != :undefined do
    filtered = Enum.reduce(pairs, [], fn {k, v}, acc ->
      result = QuickBEAM.BeamVM.Runtime.call_callback(replacer, [k, v])
      if result == :undefined, do: acc, else: [{k, result} | acc]
    end)
    {:ordered_map, Enum.reverse(filtered)}
  end

  defp apply_replacer(result, _), do: result

  defp to_json({:obj, ref} = obj) do
    case Heap.get_obj(ref) do
      nil ->
        %{}

      list when is_list(list) ->
        Enum.map(list, &to_json/1)

      map when is_map(map) ->
        case Map.get(map, "toJSON") do
          fun when fun != nil and fun != :undefined ->
            result = QuickBEAM.BeamVM.Runtime.call_callback(fun, [])
            to_json(result)
          _ ->
        order =
          case Map.get(map, key_order()) do
            list when is_list(list) -> Enum.reverse(list)
            _ -> nil
          end

        entries =
          map
          |> Map.drop([key_order()])
          |> Enum.reject(fn {k, v} -> v == :undefined or internal?(k) end)

        entries =
          if order do
            Enum.sort_by(entries, fn {k, _} ->
              case Enum.find_index(order, &(&1 == k)) do
                nil -> length(order)
                idx -> idx
              end
            end)
          else
            entries
          end

        pairs =
          entries
          |> Enum.map(fn {k, v} -> {to_string(k), to_json(resolve_value(v, obj))} end)
          |> Enum.reject(fn {_, v} -> v == :undefined end)

        {:ordered_map, pairs}
        end
    end
  end

  defp to_json(nil), do: :null
  defp to_json(:undefined), do: :null
  defp to_json({:closure, _, _}), do: :undefined
  defp to_json(%Bytecode.Function{}), do: :undefined
  defp to_json({:builtin, _, _}), do: :undefined
  defp to_json({:bound, _, _}), do: :undefined
  defp to_json(:nan), do: :null
  defp to_json(:infinity), do: :null
  defp to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  defp to_json({:accessor, _, _}), do: :undefined
  defp to_json(val), do: val

  defp resolve_value({:accessor, getter, _}, obj) when getter != nil do
    try do
      Property.call_getter(getter, obj)
    rescue
      _ -> :undefined
    catch
      _, _ -> :undefined
    end
  end

  defp resolve_value(val, _obj), do: val
end
