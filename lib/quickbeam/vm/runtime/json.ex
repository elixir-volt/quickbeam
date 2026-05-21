defmodule QuickBEAM.VM.Runtime.JSON do
  @moduledoc "JSON.parse and JSON.stringify."

  use QuickBEAM.VM.Builtin

  import Bitwise
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Value

  alias QuickBEAM.VM.ObjectModel.{
    Delete,
    Get,
    OwnProperty,
    PropertyDescriptor,
    Put,
    WrappedPrimitive
  }

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
            map when is_map(map) ->
              Map.get(map, "__raw_json__") == true or Map.get(map, :__raw_json__) == true

            _ ->
              false
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

        Heap.put_obj(ref, %{
          :__internal_proto__ => nil,
          "__raw_json__" => true,
          "rawJSON" => json,
          key_order() => ["rawJSON"]
        })

        Heap.put_prop_desc(
          ref,
          "rawJSON",
          PropertyDescriptor.attrs(writable: false, enumerable: true, configurable: false)
        )

        {:obj, ref}

      {:ok, _} ->
        JSThrow.syntax_error!("Invalid raw JSON")

      _ ->
        JSThrow.syntax_error!("Invalid raw JSON")
    end
  end

  defp raw_json(_), do: raw_json([:undefined])

  defp raw_json_text({:symbol, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp raw_json_text({:symbol, _, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp raw_json_text(text), do: Runtime.stringify(text)

  defp invalid_raw_json?(""), do: true

  defp invalid_raw_json?(<<first::utf8, _::binary>>) when first in [0x09, 0x0A, 0x0D, 0x20],
    do: true

  defp invalid_raw_json?(json), do: json |> String.last() |> Kernel.in(["\t", "\n", "\r", " "])

  defp parse([text | rest]) do
    json_text = json_parse_text(text)
    reviver = Enum.at(rest, 0)

    decoded =
      try do
        :json.decode(json_text)
      rescue
        _ -> JSThrow.syntax_error!("Unexpected end of JSON input")
      catch
        _, _ -> JSThrow.syntax_error!("Unexpected end of JSON input")
      end

    if QuickBEAM.VM.Builtin.callable?(reviver) do
      ordered = decode_ordered_json(json_text)
      source = json_source_tree(json_text)
      value = to_js_reviver(ordered_value(ordered, decoded, json_text))
      wrapper = json_replacer_wrapper(value)
      internalize_json_property(wrapper, "", reviver, source)
    else
      to_js_root(decoded, json_text)
    end
  end

  defp parse(_), do: parse([:undefined])

  defp json_parse_text(text) when is_binary(text), do: text

  defp json_parse_text({:symbol, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp json_parse_text({:symbol, _, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp json_parse_text(text), do: Runtime.stringify(text)

  defp decode_ordered_json(json_text) do
    case Jason.decode(json_text, objects: :ordered_objects) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp ordered_value(nil, decoded, _json_text), do: decoded
  defp ordered_value(%Jason.OrderedObject{} = ordered, _decoded, _json_text), do: ordered
  defp ordered_value(value, _decoded, _json_text), do: value

  defp json_source_tree(json_text) do
    {source, _rest} = parse_json_source_value(String.trim_leading(json_text))
    source
  rescue
    _ -> {:primitive, String.trim(json_text)}
  end

  defp parse_json_source_value(<<"{", rest::binary>>),
    do: parse_json_source_object(String.trim_leading(rest), [])

  defp parse_json_source_value(<<"[", rest::binary>>),
    do: parse_json_source_array(String.trim_leading(rest), [])

  defp parse_json_source_value(<<"\"", _::binary>> = input) do
    {token, rest} = take_json_source_string(input, "")
    {{:primitive, token}, rest}
  end

  defp parse_json_source_value(input) do
    {token, rest} = take_json_source_atom(input, "")
    {{:primitive, token}, rest}
  end

  defp parse_json_source_object(<<"}", rest::binary>>, acc),
    do: {{:object, Enum.reverse(acc)}, rest}

  defp parse_json_source_object(input, acc) do
    {key_token, rest} = take_json_source_string(String.trim_leading(input), "")
    {:ok, key} = Jason.decode(key_token)
    rest = rest |> String.trim_leading() |> strip_json_char(?:)
    {value, rest} = parse_json_source_value(String.trim_leading(rest))
    rest = String.trim_leading(rest)
    acc = [{key, value} | acc]

    case rest do
      <<",", tail::binary>> -> parse_json_source_object(String.trim_leading(tail), acc)
      <<"}", tail::binary>> -> {{:object, Enum.reverse(acc)}, tail}
      _ -> {{:object, Enum.reverse(acc)}, rest}
    end
  end

  defp parse_json_source_array(<<"]", rest::binary>>, acc),
    do: {{:array, Enum.reverse(acc)}, rest}

  defp parse_json_source_array(input, acc) do
    {value, rest} = parse_json_source_value(String.trim_leading(input))
    rest = String.trim_leading(rest)
    acc = [value | acc]

    case rest do
      <<",", tail::binary>> -> parse_json_source_array(String.trim_leading(tail), acc)
      <<"]", tail::binary>> -> {{:array, Enum.reverse(acc)}, tail}
      _ -> {{:array, Enum.reverse(acc)}, rest}
    end
  end

  defp strip_json_char(<<char, rest::binary>>, char), do: rest
  defp strip_json_char(rest, _char), do: rest

  defp take_json_source_string(<<"\"", rest::binary>>, ""),
    do: take_json_source_string_content(rest, "")

  defp take_json_source_string_content(<<"\\", escaped, rest::binary>>, acc),
    do: take_json_source_string_content(rest, acc <> <<?\\, escaped>>)

  defp take_json_source_string_content(<<"\"", rest::binary>>, acc),
    do: {"\"" <> acc <> "\"", rest}

  defp take_json_source_string_content(<<char, rest::binary>>, acc),
    do: take_json_source_string_content(rest, acc <> <<char>>)

  defp take_json_source_atom(<<char, rest::binary>>, acc)
       when char in [?{, ?}, ?[, ?], ?:, ?,] or char in [9, 10, 13, 32],
       do: {acc, <<char, rest::binary>>}

  defp take_json_source_atom(<<char, rest::binary>>, acc),
    do: take_json_source_atom(rest, acc <> <<char>>)

  defp take_json_source_atom(<<>>, acc), do: {acc, ""}

  defp json_source_context(source) do
    ref = make_ref()

    Heap.put_obj(ref, %{
      :__internal_proto__ => Heap.get_object_prototype(),
      "source" => source,
      key_order() => ["source"]
    })

    {:obj, ref}
  end

  defp to_js_root(0, json_str) when is_binary(json_str) do
    if Regex.match?(~r/^\s*-0(?:\.0*)?(?:[eE][+\-]?0+)?\s*$/, json_str), do: -0.0, else: 0
  end

  defp to_js_root(val, json_str) when is_map(val) do
    case Jason.decode(json_str, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{values: pairs}} ->
        keys = pairs |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
        to_js(ordered_json_object_to_map(pairs), keys)

      _ ->
        to_js(val, Map.keys(val) |> Enum.reverse())
    end
  end

  defp to_js_root(val, _) when is_list(val), do: Enum.map(val, &to_js/1)
  defp to_js_root(val, _), do: to_js(val)

  defp to_js_reviver(%Jason.OrderedObject{values: pairs}) do
    map = ordered_json_object_to_map(pairs)
    keys = pairs |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
    to_js_reviver(map, keys)
  end

  defp to_js_reviver(value) when is_map(value), do: to_js_reviver(value, nil)
  defp to_js_reviver(value) when is_list(value), do: Heap.wrap(Enum.map(value, &to_js_reviver/1))
  defp to_js_reviver(value), do: to_js(value)

  defp to_js_reviver(value, key_order) when is_map(value) do
    ref = make_ref()
    map = Map.new(value, fn {key, child} -> {key, to_js_reviver(child)} end)
    order = key_order || Map.keys(value) |> Enum.reverse()

    object =
      map
      |> Map.put(:__internal_proto__, Heap.get_object_prototype())
      |> Map.put(key_order(), order)

    Heap.put_obj(ref, object)
    {:obj, ref}
  end

  defp ordered_json_object_to_map(pairs) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      Map.put(acc, key, ordered_json_value(value))
    end)
  end

  defp ordered_json_value(%Jason.OrderedObject{values: pairs}),
    do: ordered_json_object_to_map(pairs)

  defp ordered_json_value(list) when is_list(list), do: Enum.map(list, &ordered_json_value/1)
  defp ordered_json_value(value), do: value

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
        value = val |> apply_root_to_json() |> apply_root_replacer(replacer)

        if value == :undefined do
          :undefined
        else
          result = to_json(value)
          if result == :undefined, do: :undefined, else: encode(result, replacer, space)
        end
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

  defp apply_root_to_json(value), do: apply_to_json_hook(value, "")

  defp apply_root_replacer(value, replacer) do
    if QuickBEAM.VM.Builtin.callable?(replacer) do
      wrapper = json_replacer_wrapper(value)
      QuickBEAM.VM.Invocation.invoke_with_receiver(replacer, ["", value], wrapper)
    else
      value
    end
  end

  defp internalize_json_property(holder, key, reviver, source) do
    value = Get.get(holder, key)
    internalize_json_children(value, reviver, source)
    value = Get.get(holder, key)

    QuickBEAM.VM.Invocation.invoke_with_receiver(
      reviver,
      [key, value, json_reviver_context(value, source)],
      holder
    )
  end

  defp internalize_json_children({:obj, _} = value, reviver, source) do
    cond do
      revoked_json_proxy?(value) ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      json_array_like?(value) ->
        sources = array_source_items(source)
        length = value |> Get.get("length") |> Runtime.to_int() |> max(0)

        if length > 0 do
          Enum.each(0..(length - 1), fn index ->
            key = Integer.to_string(index)
            new_value = internalize_json_property(value, key, reviver, Enum.at(sources, index))
            create_or_delete_json_property(value, key, new_value)
          end)
        end

      true ->
        sources = object_source_pairs(source)

        value
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(&OwnProperty.enumerable?(value, &1))
        |> Enum.uniq()
        |> Enum.each(fn key ->
          key = to_string(key)

          new_value =
            internalize_json_property(value, key, reviver, object_child_source(sources, key))

          create_or_delete_json_property(value, key, new_value)
        end)
    end
  end

  defp internalize_json_children(_value, _reviver, _source), do: :ok

  defp create_or_delete_json_property(object, key, :undefined),
    do: Delete.delete_property(object, key)

  defp create_or_delete_json_property({:obj, ref} = object, key, value) do
    case Heap.get_prop_desc(ref, key) do
      %{configurable: false} -> object
      _ -> Put.put(object, key, value)
    end
  end

  defp revoked_json_proxy?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} -> true
      _ -> false
    end
  end

  defp array_source_items({:array, items}), do: items
  defp array_source_items(_source), do: []

  defp object_source_pairs({:object, pairs}), do: pairs
  defp object_source_pairs(_source), do: []

  defp object_child_source(pairs, key) do
    pairs
    |> Enum.reverse()
    |> Enum.find_value(fn {source_key, source} -> if source_key == key, do: source end)
  end

  defp json_reviver_context({:obj, _}, _source), do: json_empty_context()

  defp json_reviver_context(value, {:primitive, source}) do
    if same_json_primitive?(value, source),
      do: json_source_context(source),
      else: json_empty_context()
  end

  defp json_reviver_context(_value, _source), do: json_empty_context()

  defp same_json_primitive?(value, source) do
    case Jason.decode(source) do
      {:ok, decoded} when is_number(decoded) and is_number(value) -> decoded == value
      {:ok, decoded} -> decoded == value
      _ -> false
    end
  end

  defp json_empty_context do
    ref = make_ref()
    Heap.put_obj(ref, %{:__internal_proto__ => Heap.get_object_prototype(), key_order() => []})
    {:obj, ref}
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
    |> Enum.reduce(json, fn {token, raw}, acc ->
      String.replace(acc, Jason.encode!(token), raw)
    end)
  end

  defp normalize_json_escapes(json) do
    Regex.replace(~r/\\u[0-9A-Fa-f]{4}/, json, &String.downcase/1)
  end

  defp raw_json_entries({:__raw_json__, json}), do: [{raw_token(json), json}]

  defp raw_json_entries(%Jason.OrderedObject{values: pairs}),
    do: Enum.flat_map(pairs, fn {_k, v} -> raw_json_entries(v) end)

  defp raw_json_entries({_key, value}), do: raw_json_entries(value)
  defp raw_json_entries(list) when is_list(list), do: Enum.flat_map(list, &raw_json_entries/1)
  defp raw_json_entries(_), do: []

  defp raw_token(json), do: "__quickbeam_raw_json_#{:erlang.phash2(json)}__"

  defp to_elixir({:raw_json, json}), do: {:__raw_json__, json}
  defp to_elixir(value) when is_binary(value), do: json_string_value(value)

  defp to_elixir({:ordered_map, pairs}) do
    Jason.OrderedObject.new(Enum.map(pairs, fn {k, v} -> {k, to_elixir(v)} end))
  end

  defp to_elixir(list) when is_list(list), do: Enum.map(list, &to_elixir/1)
  defp to_elixir(:null), do: nil
  defp to_elixir(:undefined), do: nil
  defp to_elixir(val), do: val

  defp json_string_value(value) do
    if String.valid?(value), do: value, else: {:__raw_json__, quote_json_string(value)}
  end

  defp quote_json_string(value), do: "\"" <> quote_json_string_content(value, "") <> "\""

  defp quote_json_string_content(<<>>, acc), do: acc

  defp quote_json_string_content(<<0xED, b2, b3, rest::binary>>, acc)
       when b2 in 0xA0..0xBF and b3 in 0x80..0xBF do
    code = (0xD <<< 12) + ((b2 &&& 0x3F) <<< 6) + (b3 &&& 0x3F)
    quote_json_string_content(rest, acc <> "\\u" <> String.downcase(Integer.to_string(code, 16)))
  end

  defp quote_json_string_content(<<cp::utf8, rest::binary>>, acc) do
    escaped = Jason.encode!(<<cp::utf8>>) |> String.slice(1..-2//1)
    quote_json_string_content(rest, acc <> escaped)
  end

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
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => target} ->
        proxy_replacer_property_list(replacer, target)

      {:qb_arr, _} ->
        {:ok, replacer |> Heap.to_list() |> property_list_items()}

      list when is_list(list) ->
        {:ok, property_list_items(list)}

      _ ->
        :not_array
    end
  end

  defp proxy_replacer_property_list(replacer, target) do
    if json_array_like?(target) do
      length = replacer |> Get.get("length") |> Runtime.to_int() |> max(0)

      values =
        if length == 0,
          do: [],
          else: for(index <- 0..(length - 1), do: Get.get(replacer, Integer.to_string(index)))

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

  defp property_list_item(value) when value in [:infinity, :neg_infinity, :nan],
    do: Runtime.stringify(value)

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

        {:qb_arr, _arr} ->
          json_array_or_to_json(obj)

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
              order =
                case Map.get(map, key_order()) do
                  {:qb_arr, arr} -> :array.to_list(arr)
                  list when is_list(list) -> Enum.reverse(list)
                  _ -> nil
                end

              entries =
                map
                |> Map.drop([key_order()])
                |> Enum.reject(fn {k, v} -> v == :undefined or internal?(k) or symbol_key?(k) end)

              entries = order_json_entries(entries, order)

              pairs =
                entries
                |> Enum.map(fn {k, _v} ->
                  key = to_string(k)

                  replaced =
                    obj
                    |> Get.get(key)
                    |> apply_to_json_hook(key)
                    |> apply_property_replacer(key, obj)

                  value = if replaced == :undefined, do: :undefined, else: to_json(replaced)
                  {key, value}
                end)
                |> Enum.reject(fn {_, v} -> v == :undefined end)

              {:ordered_map, pairs}
          end
      end
    end)
  end

  defp to_json(nil), do: :null
  defp to_json(:undefined), do: :null

  defp to_json({:bigint, _}), do: JSThrow.type_error!("Do not know how to serialize a BigInt")
  defp to_json({:symbol, _}), do: :undefined
  defp to_json({:symbol, _, _}), do: :undefined
  defp to_json({:regexp, _, _, _}), do: {:ordered_map, []}

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
      :number -> {:ok, map |> Heap.wrap() |> Runtime.to_number()}
      :string -> {:ok, map |> Heap.wrap() |> Runtime.stringify()}
      :boolean -> WrappedPrimitive.value(map, :boolean)
      :bigint -> WrappedPrimitive.value(map, :bigint)
      _ -> :error
    end
  end

  defp json_array_or_to_json(obj, values \\ nil),
    do: json_array_values(obj, json_array_length(obj, values))

  defp json_array_length(obj, nil), do: obj |> Get.get("length") |> Runtime.to_int() |> max(0)
  defp json_array_length(_obj, values) when is_list(values), do: length(values)

  defp json_array_values(obj, length) do
    if length == 0 do
      []
    else
      for index <- 0..(length - 1) do
        key = Integer.to_string(index)

        replaced =
          obj
          |> Get.get(key)
          |> apply_to_json_hook(key)
          |> apply_property_replacer(key, obj)

        if replaced == :undefined, do: :null, else: to_json(replaced)
      end
    end
  end

  defp proxy_to_json(proxy) do
    if json_array_like?(proxy) do
      length = proxy |> Get.get("length") |> Runtime.to_int() |> max(0)

      if length == 0 do
        []
      else
        for index <- 0..(length - 1) do
          key = Integer.to_string(index)

          replaced =
            proxy
            |> Get.get(key)
            |> apply_to_json_hook(key)
            |> apply_property_replacer(key, proxy)

          if replaced == :undefined, do: :null, else: to_json(replaced)
        end
      end
    else
      entries =
        proxy
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(&OwnProperty.enumerable?(proxy, &1))
        |> Enum.map(&{&1, nil})
        |> order_json_entries(nil)

      pairs =
        entries
        |> Enum.map(fn {key, _value} ->
          string_key = to_string(key)

          replaced =
            proxy
            |> Get.get(string_key)
            |> apply_to_json_hook(string_key)
            |> apply_property_replacer(string_key, proxy)

          value = if replaced == :undefined, do: :undefined, else: to_json(replaced)
          {string_key, value}
        end)
        |> Enum.reject(fn {_, value} -> value == :undefined end)

      {:ordered_map, pairs}
    end
  end

  defp json_array_like?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => target} ->
        json_array_like?(target)

      {:qb_arr, _} ->
        true

      list when is_list(list) ->
        true

      _ ->
        false
    end
  end

  defp json_array_like?({:qb_arr, _}), do: true
  defp json_array_like?(list) when is_list(list), do: true
  defp json_array_like?(_), do: false

  defp symbol_key?(value), do: Value.symbol?(value)

  defp apply_to_json_hook(value, key) when is_binary(key) do
    case value do
      {:obj, _} -> invoke_to_json_hook(value, key)
      {:bigint, _} -> invoke_to_json_hook(value, key)
      _ -> value
    end
  end

  defp invoke_to_json_hook(value, key) do
    case Get.get(value, "toJSON") do
      fun when fun != nil and fun != :undefined ->
        if QuickBEAM.VM.Builtin.callable?(fun),
          do: QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [key], value),
          else: value

      _ ->
        value
    end
  end

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
        order_index =
          if order, do: Enum.find_index(order, &(&1 == key || &1 == string_key)), else: nil

        {1, order_index || 4_294_967_295, string_key}
    end
  end
end
