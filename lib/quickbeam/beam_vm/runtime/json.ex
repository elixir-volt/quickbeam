defmodule QuickBEAM.BeamVM.Runtime.JSON do
  @moduledoc "JSON.parse and JSON.stringify."

  use QuickBEAM.BeamVM.Builtin

  import QuickBEAM.BeamVM.Heap.Keys
  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime.Property
  js_object "JSON" do
    method "parse" do
      parse(hd(args))
    end

    method "stringify" do
      stringify(args)
    end
  end

  defp parse(s) when is_binary(s) do
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
    ref = make_ref()
    map = Map.new(val, fn {k, v} -> {k, to_js(v)} end)
    Heap.put_obj(ref, map)
    {:obj, ref}
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
        if result == :undefined, do: :undefined, else: do_stringify(result, replacer, space)
      rescue
        ArgumentError -> :undefined
      end
    end
  end

  defp stringify([]), do: :undefined

  defp do_stringify(result, replacer, space) do
    result = filter_by_replacer(result, replacer)
    json = encode_json(result)

    case space do
      n when is_integer(n) and n > 0 ->
        json |> add_colon_space() |> indent_json(String.duplicate(" ", min(n, 10)))
      s when is_binary(s) and s != "" ->
        json |> add_colon_space() |> indent_json(String.slice(s, 0, 10))
      _ -> json
    end
  end

  defp filter_by_replacer(result, replacer) when is_list(replacer) do
    # replacer is a plain list — but actually it comes as {:obj, ref}
    result
  end

  defp filter_by_replacer({:ordered_map, pairs}, {:obj, ref}) do
    allowed = Heap.to_list({:obj, ref})
    if allowed != [] and Enum.all?(allowed, &is_binary/1) do
      {:ordered_map, Enum.filter(pairs, fn {k, _} -> k in allowed end)}
    else
      {:ordered_map, pairs}
    end
  end

  defp filter_by_replacer(result, _), do: result

  defp add_colon_space(json), do: String.replace(json, ":", ": ")

  defp indent_json(json, indent) do
    json
    |> String.replace(",", ",\n")
    |> String.replace("{", "{\n")
    |> String.replace("}", "\n}")
    |> String.replace("[", "[\n")
    |> String.replace("]", "\n]")
    |> indent_lines(indent, 0)
  end

  defp indent_lines(json, indent, _level) do
    lines = String.split(json, "\n")
    {result, _} = Enum.reduce(lines, {"", 0}, fn line, {acc, level} ->
      trimmed = String.trim(line)
      new_level = if String.starts_with?(trimmed, "}") or String.starts_with?(trimmed, "]"), do: level - 1, else: level
      prefix = String.duplicate(indent, max(0, new_level))
      next_level = if String.ends_with?(trimmed, "{") or String.ends_with?(trimmed, "["), do: new_level + 1, else: new_level
      sep = if acc == "", do: "", else: "\n"
      {acc <> sep <> prefix <> trimmed, next_level}
    end)
    result
  end

  defp encode_json(val) do
    :json.encode(val, &json_encoder/2) |> IO.iodata_to_binary()
  end

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

  defp json_encoder({:ordered_map, pairs}, encoder) do
    ["{", Enum.intersperse(Enum.map(pairs, fn {k, v} ->
      [encoder.(k, encoder), ":", encoder.(v, encoder)]
    end), ","), "}"]
  end

  defp json_encoder(other, encoder), do: :json.encode_value(other, encoder)

  defp to_json({:obj, ref} = obj) do
    case Heap.get_obj(ref) do
      nil ->
        %{}

      list when is_list(list) ->
        Enum.map(list, &to_json/1)

      map when is_map(map) ->
        order =
          case Map.get(map, key_order()) do
            list when is_list(list) -> Enum.reverse(list)
            _ -> nil
          end

        entries =
          map
          |> Map.drop([key_order()])
          |> Enum.reject(fn {k, v} ->
            v == :undefined or internal?(k)
          end)

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
end
