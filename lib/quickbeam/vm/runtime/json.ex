defmodule QuickBEAM.VM.Runtime.JSON do
  @moduledoc "JSON.parse and JSON.stringify."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor}
  alias QuickBEAM.VM.Runtime

  @method_lengths %{"parse" => 2, "stringify" => 3, "rawJSON" => 1, "isRawJSON" => 1}

  def install_metadata({:builtin, _name, map} = json) when is_map(map) do
    Enum.each(@method_lengths, fn {name, length} ->
      method = Map.get(map, name)
      Heap.put_ctor_static(json, name, method)
      Heap.put_prop_desc(json, name, PropertyDescriptor.method())
      Heap.put_ctor_prop_desc(json, name, PropertyDescriptor.method())

      case method do
        {:builtin, _, _} = method ->
          Heap.put_ctor_static(method, "length", length)
          Heap.put_ctor_prop_desc(method, "length", PropertyDescriptor.hidden_readonly())

        _ ->
          :ok
      end
    end)

    tag = {:symbol, "Symbol.toStringTag"}
    Heap.put_ctor_static(json, tag, "JSON")
    Heap.put_prop_desc(json, tag, PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(json, tag, PropertyDescriptor.hidden_readonly())

    case Heap.get_object_prototype() do
      {:obj, _} = object_proto -> Heap.put_ctor_static(json, proto(), object_proto)
      _ -> :ok
    end

    json
  end

  js_object "JSON" do
    method "parse" do
      parse(args)
    end

    method "stringify" do
      stringify(args)
    end

    method "rawJSON" do
      raw_json(args)
    end

    method "isRawJSON" do
      case args do
        [{:obj, ref} | _] ->
          case Heap.get_obj(ref, %{}) do
            map when is_map(map) -> Map.get(map, "__raw_json__") == true or Map.get(map, :__raw_json__) == true
            _ -> false
          end

        _ ->
          false
      end
    end
  end

  defp raw_json([text | _]) do
    json = raw_json_text(text)

    if invalid_raw_json?(json) do
      JSThrow.syntax_error!("Invalid raw JSON")
    end

    case Jason.decode(json) do
      {:ok, decoded} when not is_map(decoded) and not is_list(decoded) ->
        ref = make_ref()
        Heap.put_obj(ref, %{:__internal_proto__ => nil, "__raw_json__" => true, "rawJSON" => json, key_order() => ["rawJSON"]})
        Heap.put_prop_desc(ref, "rawJSON", PropertyDescriptor.attrs(writable: false, enumerable: true, configurable: false))
        {:obj, ref}

      {:ok, _} ->
        JSThrow.syntax_error!("Invalid raw JSON")

      _ ->
        JSThrow.syntax_error!("Invalid raw JSON")
    end
  end

  defp raw_json(_), do: raw_json([:undefined])

  defp raw_json_text({:symbol, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")
  defp raw_json_text({:symbol, _, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")
  defp raw_json_text(text), do: Runtime.stringify(text)

  defp invalid_raw_json?(""), do: true
  defp invalid_raw_json?(<<first::utf8, _::binary>>) when first in [0x09, 0x0A, 0x0D, 0x20], do: true
  defp invalid_raw_json?(json), do: json |> String.last() |> Kernel.in(["\t", "\n", "\r", " "])

  defp parse([text | _]) do
    json_text = json_parse_text(text)

    decoded =
      try do
        :json.decode(json_text)
      rescue
        _ -> JSThrow.syntax_error!("Unexpected end of JSON input")
      catch
        _, _ -> JSThrow.syntax_error!("Unexpected end of JSON input")
      end

    to_js_root(decoded, json_text)
  end

  defp parse(_), do: parse([:undefined])

  defp json_parse_text(text) when is_binary(text), do: text

  defp json_parse_text({:symbol, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")
  defp json_parse_text({:symbol, _, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp json_parse_text(text), do: Runtime.stringify(text)

  defp to_js_root(0, json_str) when is_binary(json_str) do
    if Regex.match?(~r/^\s*-0(?:\.0*)?(?:[eE][+\-]?0+)?\s*$/, json_str), do: -0.0, else: 0
  end

  defp to_js_root(val, json_str) when is_map(val) do
    keys =
      case Jason.decode(json_str, objects: :ordered_objects) do
        {:ok, %Jason.OrderedObject{values: pairs}} ->
          pairs |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

        _ ->
          Map.keys(val) |> Enum.reverse()
      end

    to_js(val, keys)
  end

  defp to_js_root(val, _) when is_list(val), do: Enum.map(val, &to_js/1)
  defp to_js_root(val, _), do: to_js(val)

  defp to_js(nil), do: nil
  defp to_js(:null), do: nil
  defp to_js(val) when is_map(val), do: to_js(val, nil)
  defp to_js(val) when is_list(val), do: Enum.map(val, &to_js/1)
  defp to_js(val), do: val

  defp to_js(val, key_order) when is_map(val) do
    ref = make_ref()
    map = Map.new(val, fn {k, v} -> {k, to_js(v, nil)} end)
    order = key_order || Map.keys(val) |> Enum.reverse()
    Heap.put_obj(ref, Map.put(map, key_order(), order))
    {:obj, ref}
  end

  defp to_js(val, _) when is_list(val), do: Enum.map(val, &to_js/1)
  defp to_js(val, _), do: to_js(val)

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

    opts =
      case space do
        n when is_integer(n) and n > 0 -> [pretty: [indent: String.duplicate(" ", min(n, 10))]]
        s when is_binary(s) and s != "" -> [pretty: [indent: String.slice(s, 0, 10)]]
        _ -> []
      end

    case encode_raw_json(elixir_val, opts) do
      {:ok, json} -> json
      _ -> :undefined
    end
  end

  defp encode_raw_json({:__raw_json__, json}, _opts), do: {:ok, json}

  defp encode_raw_json(%Jason.OrderedObject{values: pairs} = object, opts) do
    with {:ok, json} <- Jason.encode(raw_placeholder(object), opts) do
      {:ok, json |> restore_raw_placeholders(pairs) |> normalize_json_escapes()}
    end
  end

  defp encode_raw_json(list, opts) when is_list(list) do
    with {:ok, json} <- Jason.encode(raw_placeholder(list), opts) do
      {:ok, json |> restore_raw_placeholders(list) |> normalize_json_escapes()}
    end
  end

  defp encode_raw_json(value, opts) do
    case Jason.encode(value, opts) do
      {:ok, json} -> {:ok, normalize_json_escapes(json)}
      other -> other
    end
  end

  defp raw_placeholder({:__raw_json__, json}), do: raw_token(json)

  defp raw_placeholder(%Jason.OrderedObject{values: pairs}),
    do: %Jason.OrderedObject{values: Enum.map(pairs, fn {k, v} -> {k, raw_placeholder(v)} end)}

  defp raw_placeholder(list) when is_list(list), do: Enum.map(list, &raw_placeholder/1)
  defp raw_placeholder(value), do: value

  defp restore_raw_placeholders(json, value) do
    value
    |> raw_json_entries()
    |> Enum.reduce(json, fn {token, raw}, acc -> String.replace(acc, Jason.encode!(token), raw) end)
  end

  defp normalize_json_escapes(json) do
    Regex.replace(~r/\\u[0-9A-Fa-f]{4}/, json, &String.downcase/1)
  end

  defp raw_json_entries({:__raw_json__, json}), do: [{raw_token(json), json}]
  defp raw_json_entries(%Jason.OrderedObject{values: pairs}), do: Enum.flat_map(pairs, fn {_k, v} -> raw_json_entries(v) end)
  defp raw_json_entries({_key, value}), do: raw_json_entries(value)
  defp raw_json_entries(list) when is_list(list), do: Enum.flat_map(list, &raw_json_entries/1)
  defp raw_json_entries(_), do: []

  defp raw_token(json), do: "__quickbeam_raw_json_#{:erlang.phash2(json)}__"

  defp to_elixir({:raw_json, json}), do: {:__raw_json__, json}

  defp to_elixir({:ordered_map, pairs}) do
    Jason.OrderedObject.new(Enum.map(pairs, fn {k, v} -> {k, to_elixir(v)} end))
  end

  defp to_elixir(list) when is_list(list), do: Enum.map(list, &to_elixir/1)
  defp to_elixir(:null), do: nil
  defp to_elixir(:undefined), do: nil
  defp to_elixir(val), do: val

  defp apply_replacer({:ordered_map, pairs}, {:obj, ref}) do
    allowed = Heap.to_list({:obj, ref})

    if allowed != [] and Enum.all?(allowed, &is_binary/1) do
      {:ordered_map, Enum.filter(pairs, fn {k, _} -> k in allowed end)}
    else
      {:ordered_map, pairs}
    end
  end

  defp apply_replacer({:ordered_map, pairs}, replacer)
       when replacer != nil and replacer != :undefined do
    filtered =
      Enum.reduce(pairs, [], fn {k, v}, acc ->
        result = Runtime.call_callback(replacer, [k, v])
        if result == :undefined, do: acc, else: [{k, result} | acc]
      end)

    {:ordered_map, Enum.reverse(filtered)}
  end

  defp apply_replacer(result, _), do: result

  defp to_json({:obj, ref} = obj) do
    case Heap.get_obj(ref) do
      nil ->
        %{}

      {:qb_arr, arr} ->
        :array.to_list(arr) |> Enum.map(&to_json/1)

      list when is_list(list) ->
        Enum.map(list, &to_json/1)

      map when is_map(map) ->
        if Map.get(map, "__raw_json__") == true or Map.get(map, :__raw_json__) == true do
          {:raw_json, Map.get(map, "rawJSON")}
        else
        case Map.get(map, "toJSON") do
          fun when fun != nil and fun != :undefined ->
            result = Runtime.call_callback(fun, [])
            to_json(result)

          _ ->
            order =
              case Map.get(map, key_order()) do
                {:qb_arr, arr} -> :array.to_list(arr)
                list when is_list(list) -> Enum.reverse(list)
                _ -> nil
              end

            entries =
              map
              |> Map.drop([key_order()])
              |> Enum.reject(fn {k, v} -> v == :undefined or internal?(k) end)

            entries = sort_json_entries(entries, order)

            pairs =
              entries
              |> Enum.map(fn {k, v} -> {to_string(k), to_json(resolve_value(v, obj))} end)
              |> Enum.reject(fn {_, v} -> v == :undefined end)

            {:ordered_map, pairs}
        end
        end
    end
  end

  defp to_json(nil), do: :null
  defp to_json(:undefined), do: :null
  defp to_json({:closure, _, _}), do: :undefined
  defp to_json(%QuickBEAM.VM.Function{}), do: :undefined
  defp to_json({:builtin, _, _}), do: :undefined
  defp to_json({:bound, _, _, _, _}), do: :undefined
  defp to_json(n) when is_float(n) and n == 0, do: 0
  defp to_json(:nan), do: :null
  defp to_json(:infinity), do: :null
  defp to_json(:neg_infinity), do: :null
  defp to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  defp to_json({:accessor, _, _}), do: :undefined
  defp to_json(val), do: val

  defp sort_json_entries(entries, order) do
    Enum.sort_by(entries, fn {key, _} -> json_entry_sort_key(key, order) end)
  end

  defp json_entry_sort_key(key, order) do
    string_key = to_string(key)

    case Integer.parse(string_key) do
      {index, ""} when index >= 0 and index < 4_294_967_295 ->
        {0, index}

      _ ->
        order_index = if order, do: Enum.find_index(order, &(&1 == key || &1 == string_key)), else: nil
        {1, order_index || 4_294_967_295, string_key}
    end
  end

  defp resolve_value({:accessor, getter, _}, obj) when getter != nil do
    Get.call_getter(getter, obj)
  rescue
    _ -> :undefined
  catch
    _, _ -> :undefined
  end

  defp resolve_value(val, _obj), do: val
end
