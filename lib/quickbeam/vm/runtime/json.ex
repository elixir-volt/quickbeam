defmodule QuickBEAM.VM.Runtime.JSON do
  @moduledoc "JSON.parse and JSON.stringify."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, OwnProperty, PropertyDescriptor, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime

  @method_lengths %{"parse" => 2, "stringify" => 3, "rawJSON" => 1, "isRawJSON" => 1}
  @property_list_key {__MODULE__, :property_list}
  @seen_refs_key {__MODULE__, :seen_refs}
  @replacer_function_key {__MODULE__, :replacer_function}

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

    object =
      map
      |> Map.put(:__internal_proto__, Heap.get_object_prototype())
      |> Map.put(key_order(), order)

    Heap.put_obj(ref, object)
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

      previous_property_list = Process.get(@property_list_key)
      previous_seen_refs = Process.get(@seen_refs_key)
      previous_replacer_function = Process.get(@replacer_function_key)
      install_replacer_function(replacer)
      install_replacer_property_list(replacer)
      Process.put(@seen_refs_key, MapSet.new())

      try do
        value = apply_root_replacer(val, replacer)
        result = to_json(value)
        if result == :undefined, do: :undefined, else: encode(result, replacer, space)
      rescue
        _ -> :undefined
      after
        restore_replacer_property_list(previous_property_list)
        restore_seen_refs(previous_seen_refs)
        restore_replacer_function(previous_replacer_function)
      end
    end
  end

  defp stringify([]), do: :undefined

  defp apply_root_replacer(value, replacer) do
    if QuickBEAM.VM.Builtin.callable?(replacer) do
      wrapper = json_replacer_wrapper(value)
      QuickBEAM.VM.Invocation.invoke_with_receiver(replacer, ["", value], wrapper)
    else
      value
    end
  end

  defp json_replacer_wrapper(value) do
    ref = make_ref()

    Heap.put_obj(ref, %{
      :__internal_proto__ => Heap.get_object_prototype(),
      "" => value,
      key_order() => [""]
    })

    {:obj, ref}
  end

  defp install_replacer_function(replacer) do
    if QuickBEAM.VM.Builtin.callable?(replacer),
      do: Process.put(@replacer_function_key, replacer),
      else: Process.delete(@replacer_function_key)
  end

  defp restore_replacer_function(nil), do: Process.delete(@replacer_function_key)
  defp restore_replacer_function(replacer), do: Process.put(@replacer_function_key, replacer)

  defp install_replacer_property_list({:obj, _} = replacer) do
    case replacer_property_list(replacer) do
      {:ok, list} -> Process.put(@property_list_key, list)
      :not_array -> Process.delete(@property_list_key)
    end
  end

  defp install_replacer_property_list(_), do: Process.delete(@property_list_key)

  defp restore_replacer_property_list(nil), do: Process.delete(@property_list_key)
  defp restore_replacer_property_list(list), do: Process.put(@property_list_key, list)

  defp restore_seen_refs(nil), do: Process.delete(@seen_refs_key)
  defp restore_seen_refs(seen_refs), do: Process.put(@seen_refs_key, seen_refs)

  defp encode(result, replacer, space) do
    result = apply_replacer(result, replacer)
    elixir_val = to_elixir(result)

    opts =
      case json_space_string(space) do
        "" -> []
        indent -> [pretty: [indent: indent]]
      end

    case encode_raw_json(elixir_val, opts) do
      {:ok, json} -> json
      _ -> :undefined
    end
  end

  defp json_space_string(n) when is_integer(n) and n > 0, do: String.duplicate(" ", min(n, 10))
  defp json_space_string(n) when is_float(n) and n > 0, do: n |> trunc() |> json_space_string()
  defp json_space_string(s) when is_binary(s), do: String.slice(s, 0, 10)

  defp json_space_string({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> json_space_wrapped(map)
      _ -> ""
    end
  end

  defp json_space_string(_), do: ""

  defp json_space_wrapped(map) do
    cond do
      WrappedPrimitive.type(map) == :number ->
        map |> Heap.wrap() |> Runtime.to_number() |> json_space_string()

      WrappedPrimitive.type(map) == :string ->
        map |> Heap.wrap() |> Runtime.stringify() |> json_space_string()

      true ->
        ""
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

  defp apply_replacer({:ordered_map, pairs}, {:obj, _} = replacer) do
    case replacer_property_list(replacer) do
      {:ok, allowed} ->
        filtered =
          for key <- allowed,
              {pair_key, value} <- pairs,
              pair_key == key do
            {pair_key, value}
          end

        {:ordered_map, filtered}

      :not_array ->
        {:ordered_map, pairs}
    end
  end

  defp apply_replacer({:ordered_map, pairs}, replacer)
       when replacer != nil and replacer != :undefined do
    if QuickBEAM.VM.Builtin.callable?(replacer) and Process.get(@replacer_function_key) == nil do
      filtered =
        Enum.reduce(pairs, [], fn {k, v}, acc ->
          result = Runtime.call_callback(replacer, [k, v])
          if result == :undefined, do: acc, else: [{k, result} | acc]
        end)

      {:ordered_map, Enum.reverse(filtered)}
    else
      {:ordered_map, pairs}
    end
  end

  defp apply_replacer(result, _), do: result

  defp replacer_property_list({:obj, ref} = replacer) do
    case Heap.get_obj(ref) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} -> JSThrow.type_error!("Cannot perform operation on a revoked proxy")
      %{proxy_target() => target} -> proxy_replacer_property_list(replacer, target)
      {:qb_arr, _} -> {:ok, replacer |> Heap.to_list() |> property_list_items()}
      list when is_list(list) -> {:ok, property_list_items(list)}
      _ -> :not_array
    end
  end

  defp proxy_replacer_property_list(replacer, target) do
    if json_array_like?(target) do
      length = replacer |> Get.get("length") |> Runtime.to_int() |> max(0)
      values = if length == 0, do: [], else: for(index <- 0..(length - 1), do: Get.get(replacer, Integer.to_string(index)))
      {:ok, property_list_items(values)}
    else
      :not_array
    end
  end

  defp property_list_items(values) do
    values
    |> Enum.reduce([], fn value, acc ->
      case property_list_item(value) do
        nil -> acc
        item -> if item in acc, do: acc, else: acc ++ [item]
      end
    end)
  end

  defp property_list_item(value) when is_binary(value), do: value
  defp property_list_item(value) when is_integer(value), do: Integer.to_string(value)
  defp property_list_item(value) when is_float(value), do: Runtime.stringify(value)
  defp property_list_item(value) when value in [:infinity, :neg_infinity, :nan], do: Runtime.stringify(value)

  defp property_list_item({:obj, ref} = value) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case WrappedPrimitive.type(map) do
          type when type in [:string, :number] -> Runtime.stringify(value)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp property_list_item(_), do: nil

  defp to_json({:obj, ref} = obj) do
    with_json_ref(ref, fn ->
    case Heap.get_obj(ref) do
      nil ->
        %{}

      {:qb_arr, arr} ->
        json_array_or_to_json(obj, :array.to_list(arr))

      list when is_list(list) ->
        json_array_or_to_json(obj, list)

      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target} ->
        proxy_to_json(obj)

      map when is_map(map) ->
        cond do
          Map.get(map, "__raw_json__") == true or Map.get(map, :__raw_json__) == true ->
            {:raw_json, Map.get(map, "rawJSON")}

          match?({:ok, _}, json_boxed_primitive(map)) ->
            {:ok, value} = json_boxed_primitive(map)
            to_json(value)

          true ->
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

            entries = order_json_entries(entries, order)

            pairs =
              entries
              |> Enum.map(fn {k, v} ->
                key = to_string(k)
                value = v |> resolve_value(obj) |> apply_property_replacer(key, obj) |> to_json()
                {key, value}
              end)
              |> Enum.reject(fn {_, v} -> v == :undefined end)

            {:ordered_map, pairs}
        end
        end
    end
    end)
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

  defp json_boxed_primitive(map) do
    case WrappedPrimitive.type(map) do
      type when type in [:string, :number, :boolean] -> WrappedPrimitive.value(map, type)
      _ -> :error
    end
  end

  defp json_array_or_to_json(obj, values) do
    case Get.get(obj, "toJSON") do
      fun when fun != nil and fun != :undefined ->
        if QuickBEAM.VM.Builtin.callable?(fun) do
          fun |> QuickBEAM.VM.Invocation.invoke_with_receiver([], obj) |> to_json()
        else
          json_array_values(obj, values)
        end

      _ ->
        json_array_values(obj, values)
    end
  end

  defp json_array_values(obj, values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      value
      |> apply_property_replacer(Integer.to_string(index), obj)
      |> to_json()
    end)
  end

  defp proxy_to_json(proxy) do
    if json_array_like?(proxy) do
      length = proxy |> Get.get("length") |> Runtime.to_int() |> max(0)

      if length == 0 do
        []
      else
        for index <- 0..(length - 1) do
          proxy
          |> Get.get(Integer.to_string(index))
          |> to_json()
        end
      end
    else
      pairs =
        proxy
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(&OwnProperty.enumerable?(proxy, &1))
        |> Enum.map(fn key -> {to_string(key), proxy |> Get.get(key) |> to_json()} end)
        |> Enum.reject(fn {_, value} -> value == :undefined end)

      {:ordered_map, pairs}
    end
  end

  defp json_array_like?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} -> JSThrow.type_error!("Cannot perform operation on a revoked proxy")
      %{proxy_target() => target} -> json_array_like?(target)
      {:qb_arr, _} -> true
      list when is_list(list) -> true
      _ -> false
    end
  end

  defp json_array_like?({:qb_arr, _}), do: true
  defp json_array_like?(list) when is_list(list), do: true
  defp json_array_like?(_), do: false

  defp apply_property_replacer(value, key, holder) do
    case Process.get(@replacer_function_key) do
      nil -> value
      replacer -> QuickBEAM.VM.Invocation.invoke_with_receiver(replacer, [key, value], holder)
    end
  end

  defp with_json_ref(ref, fun) do
    seen_refs = Process.get(@seen_refs_key, MapSet.new())

    if MapSet.member?(seen_refs, ref) do
      JSThrow.type_error!("Converting circular structure to JSON")
    else
      Process.put(@seen_refs_key, MapSet.put(seen_refs, ref))

      try do
        fun.()
      after
        Process.put(@seen_refs_key, seen_refs)
      end
    end
  end

  defp order_json_entries(entries, order) do
    case Process.get(@property_list_key) do
      list when is_list(list) ->
        for key <- list,
            {entry_key, value} <- entries,
            to_string(entry_key) == key do
          {entry_key, value}
        end

      _ ->
        sort_json_entries(entries, order)
    end
  end

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
