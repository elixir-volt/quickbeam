defmodule QuickBEAM.BeamVM.Runtime.JSON do
  use QuickBEAM.BeamVM.Builtin

  import QuickBEAM.BeamVM.Heap.Keys
  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime.Property
  @moduledoc "JSON.parse and JSON.stringify."

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
      ArgumentError ->
        throw({:js_throw, Heap.make_error("Unexpected end of JSON input", "SyntaxError")})
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

  defp stringify([val | _]) do
    if val == :undefined do
      :undefined
    else
      try do
        result = to_json(val)
        if result == :undefined, do: :undefined, else: encode_json(result)
      rescue
        ArgumentError -> :undefined
      end
    end
  end

  defp stringify([]), do: :undefined

  defp encode_json(val) do
    :json.encode(val, &json_encoder/2) |> IO.iodata_to_binary()
  end

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
          |> Enum.map(fn {k, v} ->
            resolved =
              case v do
                {:accessor, getter, _setter} when getter != nil ->
                  try do
                    Property.call_getter(getter, obj)
                  rescue
                    _ -> :undefined
                  catch
                    _, _ -> :undefined
                  end

                _ ->
                  v
              end

            {to_string(k), to_json(resolved)}
          end)
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
