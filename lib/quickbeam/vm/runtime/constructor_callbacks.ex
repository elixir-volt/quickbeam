defmodule QuickBEAM.VM.Runtime.ConstructorCallbacks do
  @moduledoc "Global constructor built-ins: `Object`, `Array`, `String`, `Boolean`, and other wrapper constructors."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1, slot_key: 1]
  import QuickBEAM.VM.Value, only: [is_builtin: 1, is_closure: 1]

  require QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{Heap, RuntimeState, Value}
  alias QuickBEAM.VM.Execution.{Eval, RegexpState}
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def object([arg | _], this) do
    case arg do
      {:symbol, _, _} = symbol ->
        WrappedPrimitive.wrap(symbol)

      {:symbol, _} = symbol ->
        WrappedPrimitive.wrap(symbol)

      {:obj, _} = obj ->
        if subclass_object_this?(this), do: this, else: obj

      %QuickBEAM.VM.Function{} = value ->
        value

      value when is_closure(value) or is_builtin(value) ->
        value

      {:bound, _, _, _, _} = value ->
        value

      {:regexp, _, _} = value ->
        value

      {:regexp, _, _, _} = value ->
        value

      value when is_binary(value) ->
        WrappedPrimitive.wrap(:string, value)

      value when is_number(value) or value in [:nan, :infinity, :neg_infinity] ->
        WrappedPrimitive.wrap(:number, value)

      value when is_boolean(value) ->
        WrappedPrimitive.wrap(:boolean, value)

      {:bigint, _} = value ->
        WrappedPrimitive.wrap(:bigint, value)

      _ ->
        ordinary_object()
    end
  end

  def object([], {:obj, ref} = object) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, proto()) -> object
      _ -> ordinary_object()
    end
  end

  def object(_, _), do: ordinary_object()

  defp subclass_object_this?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        Map.get(map, "__proto__") not in [nil, Runtime.global_class_proto("Object")]

      _ ->
        false
    end
  end

  defp subclass_object_this?(_), do: false

  defp ordinary_object do
    ref = make_ref()

    data =
      case QuickBEAM.VM.Runtime.ConstructorRegistry.class_proto("Object") do
        {:obj, _} = proto ->
          QuickBEAM.VM.Builtin.object heap: false, extends: proto do
          end

        _ ->
          %{}
      end

    Heap.put_obj(ref, data)
    {:obj, ref}
  end

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  @max_array_length 4_294_967_295
  @max_materialized_array_length 100_000

  def array(args, this) do
    result =
      case args do
        [length] when is_number(length) or length in [:nan, :infinity, :neg_infinity] ->
          array_with_length(length)

        _ ->
          wrap_array_arguments(args)
      end

    inherit_array_prototype(result, this)
  end

  defp wrap_array_arguments(args) do
    {:obj, ref} = array = Heap.wrap(args)

    args
    |> Enum.with_index()
    |> Enum.each(fn
      {:undefined, index} -> mark_array_argument_present(ref, index)
      {:undefined, _, index} -> mark_array_argument_present(ref, index)
      {:undefined, _, _, index} -> mark_array_argument_present(ref, index)
      {value, index} when value == :undefined -> mark_array_argument_present(ref, index)
      _ -> :ok
    end)

    array
  end

  defp mark_array_argument_present(ref, index) do
    Heap.put_prop_desc(ref, Integer.to_string(index), %{
      writable: true,
      enumerable: true,
      configurable: true
    })
  end

  defp inherit_array_prototype({:obj, ref} = result, {:obj, _} = this) do
    case InternalMethods.get_prototype_of(this) do
      {:obj, _} = proto -> Heap.put_array_prop(ref, "__proto__", proto)
      _ -> :ok
    end

    result
  end

  defp inherit_array_prototype(result, _this), do: result

  defp array_with_length(length_value) do
    length = Runtime.to_number(length_value)

    cond do
      not is_number(length) or length < 0 or length != trunc(length) or length > @max_array_length ->
        JSThrow.range_error!("Invalid array length")

      length <= @max_materialized_array_length ->
        Heap.wrap(List.duplicate(:undefined, trunc(length)))

      true ->
        {:obj, ref} = array = Heap.wrap([])
        Heap.put_array_prop(ref, "length", trunc(length))
        array
    end
  end

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def string(args, {:obj, _} = this) do
    case arg(args, 0, "") do
      {:symbol, _} ->
        JSThrow.type_error!("Cannot convert a Symbol value to a string")

      {:symbol, _, _} ->
        JSThrow.type_error!("Cannot convert a Symbol value to a string")

      value ->
        val = Runtime.stringify(value)
        InternalMethods.set(this, slot_key(:StringData), val)
        this
    end
  end

  def string(args, _), do: args |> arg(0, "") |> Runtime.stringify()

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def number(args, {:obj, _} = this) do
    val = args |> arg(0, 0) |> Runtime.number_constructor_to_number()
    InternalMethods.set(this, slot_key(:NumberData), val)
    this
  end

  def number(args, _), do: args |> arg(0, 0) |> Runtime.number_constructor_to_number()

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def function(args, _), do: dynamic_function(args, "function")
  def generator_function(args, _), do: dynamic_function(args, "function*")
  def async_function(args, _), do: dynamic_function(args, "async function")
  def async_generator_function(args, _), do: dynamic_function(args, "async function*")

  defp dynamic_function(args, prefix) do
    ctx = RuntimeState.current()

    if ctx && ctx.runtime_pid do
      {params, body} =
        case Enum.reverse(args) do
          [body | param_parts] ->
            {Enum.join(Enum.map(Enum.reverse(param_parts), &stringify_arg/1), ","),
             stringify_arg(body)}

          [] ->
            {"", ""}
        end

      code = "(" <> prefix <> " anonymous(" <> params <> "\n) {\n" <> body <> "\n})"

      case Eval.compile_and_eval(ctx.runtime_pid, code) do
        {:ok, value} -> with_dynamic_function_prototype(value, ctx)
        _ -> JSThrow.syntax_error!("Invalid function")
      end
    else
      JSThrow.error!("Function constructor requires runtime")
    end
  end

  defp with_dynamic_function_prototype(value, _ctx) do
    new_target = :undefined

    proto =
      case Get.get(new_target, "prototype") do
        {:obj, _} = object ->
          object

        _ ->
          QuickBEAM.VM.Realm.default_prototype({:builtin, "Function", &function/2}, new_target) ||
            Runtime.global_class_proto("Function")
      end

    if proto != nil do
      Heap.put_ctor_static(value, "__proto__", proto)
    end

    define_dynamic_generator_prototype(value)
    value
  end

  defp define_dynamic_generator_prototype(
         {:closure, _, %QuickBEAM.VM.Function{func_kind: kind}} = value
       )
       when kind in [1, 3] do
    Heap.put_ctor_static(value, "prototype", Heap.get_or_create_prototype(value))
    :ok
  end

  defp define_dynamic_generator_prototype(%QuickBEAM.VM.Function{func_kind: kind} = value)
       when kind in [1, 3] do
    Heap.put_ctor_static(value, "prototype", Heap.get_or_create_prototype(value))
    :ok
  end

  defp define_dynamic_generator_prototype(_), do: :ok

  defp stringify_arg(val) when is_binary(val), do: val
  defp stringify_arg(val), do: QuickBEAM.VM.Semantics.Values.stringify(val)

  def bigint(args, this), do: bigint_call(args, this)

  defp bigint_call([:undefined | _], _), do: JSThrow.type_error!("Cannot convert to BigInt")
  defp bigint_call([:infinity | _], _), do: JSThrow.range_error!("Cannot convert to BigInt")
  defp bigint_call([:neg_infinity | _], _), do: JSThrow.range_error!("Cannot convert to BigInt")
  defp bigint_call([:nan | _], _), do: JSThrow.range_error!("Cannot convert to BigInt")
  defp bigint_call([n | _], _) when is_integer(n), do: {:bigint, number_integer_to_bigint(n)}
  defp bigint_call([{:bigint, n} | _], _), do: {:bigint, n}

  defp bigint_call([string | _], _) when is_binary(string) do
    case QuickBEAM.VM.Runtime.BigInt.parse_bigint_string(String.trim(string)) do
      {:ok, n} -> {:bigint, n}
      :error -> JSThrow.syntax_error!("Cannot convert to BigInt")
    end
  end

  defp bigint_call([{:obj, _} = value | _], _),
    do: bigint_call([QuickBEAM.VM.Semantics.Coercion.to_primitive(value, "number")], nil)

  defp bigint_call([value | _], _) do
    case Runtime.to_number(value) do
      n when is_integer(n) -> {:bigint, number_integer_to_bigint(n)}
      n when is_float(n) and n == trunc(n) -> {:bigint, trunc(n)}
      n when is_float(n) -> JSThrow.range_error!("Cannot convert to BigInt")
      :nan -> JSThrow.range_error!("Cannot convert to BigInt")
      _ -> JSThrow.type_error!("Cannot convert to BigInt")
    end
  end

  defp bigint_call(_, _) do
    JSThrow.type_error!("Cannot convert to BigInt")
  end

  defp number_integer_to_bigint(n) when abs(n) <= 9_007_199_254_740_991, do: n
  defp number_integer_to_bigint(n), do: n |> Kernel.*(1.0) |> trunc()

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def regexp([], this), do: regexp(["" | []], this)

  def regexp([pattern | rest], this) do
    if regexp_function_identity?(pattern, rest, this) do
      pattern
    else
      source =
        case pattern do
          {:regexp, _bytecode, value} -> value
          {:regexp, _bytecode, value, _ref} -> value
          {:obj, _} = obj -> regexp_object_source(obj)
          value when is_binary(value) -> value
          :undefined -> ""
          _ -> QuickBEAM.VM.Runtime.stringify(pattern)
        end

      flags =
        case rest do
          [value | _] when value != :undefined -> QuickBEAM.VM.Runtime.stringify(value)
          _ -> regexp_source_flags(pattern)
        end

      validate_regexp_flags!(flags)

      unless trusted_regexp_clone_source?(pattern, source, flags) do
        validate_regexp_source!(source, flags)
      end

      ref = make_ref()
      RegexpState.put_internal(ref, "flags", canonical_regexp_flags(flags))
      RegexpState.put(ref, "lastIndex", 0)

      Heap.put_prop_desc(ref, "lastIndex", %{
        writable: true,
        enumerable: false,
        configurable: false
      })

      case this do
        {:obj, this_ref} ->
          case Heap.get_obj(this_ref, %{}) do
            %{proto() => instance_proto} -> RegexpState.put(ref, proto(), instance_proto)
            _ -> :ok
          end

        _ ->
          :ok
      end

      case pattern do
        {:regexp, bytecode, ^source} when is_binary(bytecode) ->
          if compatible_regexp_clone_flags?(regexp_source_flags(pattern), flags),
            do: {:regexp, bytecode, source, ref},
            else: {:regexp, nil, source, ref}

        {:regexp, bytecode, ^source, _pattern_ref} when is_binary(bytecode) ->
          if compatible_regexp_clone_flags?(regexp_source_flags(pattern), flags),
            do: {:regexp, bytecode, source, ref},
            else: {:regexp, nil, source, ref}

        _ ->
          {:regexp, nil, source, ref}
      end
    end
  end

  defp trusted_regexp_clone_source?({:regexp, _bytecode, source} = pattern, source, flags),
    do: compatible_regexp_clone_flags?(regexp_source_flags(pattern), flags)

  defp trusted_regexp_clone_source?({:regexp, _bytecode, source, _ref} = pattern, source, flags),
    do: compatible_regexp_clone_flags?(regexp_source_flags(pattern), flags)

  defp trusted_regexp_clone_source?(_pattern, _source, _flags), do: false

  defp regexp_function_identity?(pattern, rest, this) do
    not regexp_constructing?(this) and regexp_flags_omitted?(rest) and regexp_value?(pattern) and
      Get.get(pattern, "constructor") == QuickBEAM.VM.Runtime.ConstructorRegistry.lookup("RegExp")
  end

  defp regexp_value?({:regexp, _, _} = regexp), do: regexp_matcher_truthy_or_absent?(regexp)
  defp regexp_value?({:regexp, _, _, _} = regexp), do: regexp_matcher_truthy_or_absent?(regexp)
  defp regexp_value?({:obj, _} = obj), do: regexp_like?(obj)
  defp regexp_value?(_), do: false

  defp regexp_matcher_truthy_or_absent?(regexp) do
    case Get.get(regexp, {:symbol, "Symbol.match"}) do
      :undefined -> true
      value -> Runtime.truthy?(value)
    end
  end

  defp regexp_like?({:obj, _} = obj) do
    Runtime.truthy?(Get.get(obj, {:symbol, "Symbol.match"}))
  end

  defp regexp_like?(_), do: false

  defp regexp_flags_omitted?([]), do: true
  defp regexp_flags_omitted?([:undefined | _]), do: true
  defp regexp_flags_omitted?(_), do: false

  defp regexp_constructing?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proto() => _} -> true
      _ -> false
    end
  end

  defp regexp_constructing?(_), do: false

  defp regexp_object_source(obj) do
    if regexp_like?(obj),
      do: Runtime.stringify(Get.get(obj, "source")),
      else: Runtime.stringify(obj)
  end

  defp regexp_source_flags({:regexp, bytecode, _source}) do
    QuickBEAM.VM.ObjectModel.Get.regexp_flags(bytecode)
  end

  defp regexp_source_flags({:regexp, bytecode, _source, ref}) do
    case RegexpState.fetch_internal(ref, "flags") do
      {:ok, flags} -> flags
      :error -> QuickBEAM.VM.ObjectModel.Get.regexp_flags(bytecode)
    end
  end

  defp regexp_source_flags({:obj, _} = obj) do
    if regexp_like?(obj), do: Runtime.stringify(Get.get(obj, "flags")), else: ""
  end

  defp regexp_source_flags(_), do: ""

  defp validate_regexp_flags!(flags) when is_binary(flags) do
    chars = String.graphemes(flags)
    valid? = Enum.all?(chars, &(&1 in ~w(d g i m s u v y)))
    unique? = Enum.uniq(chars) == chars
    unicode_mode_conflict? = "u" in chars and "v" in chars

    unless valid? and unique? and not unicode_mode_conflict? do
      JSThrow.syntax_error!("Invalid regular expression flags")
    end
  end

  defp canonical_regexp_flags(flags),
    do:
      Enum.reduce(~w(d g i m s u v y), "", fn flag, acc ->
        if String.contains?(flags, flag), do: acc <> flag, else: acc
      end)

  defp compatible_regexp_clone_flags?(original_flags, requested_flags) do
    requested = canonical_regexp_flags(requested_flags)
    original = canonical_regexp_flags(original_flags)
    requested == original or requested == canonical_regexp_flags(original_flags <> "y")
  end

  defp validate_regexp_source!(source, flags) when is_binary(source) do
    if invalid_regexp_source?(source) or invalid_unicode_regexp_source?(source, flags) do
      JSThrow.syntax_error!("Invalid regular expression")
    end
  end

  defp invalid_regexp_source?(source) do
    starts_with_quantifier?(source) or invalid_named_group_names?(source) or
      dangling_escape?(source) or
      repeated_quantifier?(source) or adjacent_interval_quantifiers?(source) or
      invalid_class_range?(source) or
      descending_character_range?(source) or invalid_interval_quantifier?(source) or
      invalid_modifiers?(source) or
      duplicate_group_name_in_alternative?(source)
  end

  defp invalid_named_group_names?(source) do
    ~r/\(\?<([^=!][^>]*)>/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.any?(fn [name] -> not valid_regexp_group_name?(decode_regexp_group_name(name)) end)
  rescue
    _ -> true
  end

  defp valid_regexp_group_name?(name) do
    case String.graphemes(name) do
      [first | rest] ->
        regexp_group_name_start?(first) and Enum.all?(rest, &regexp_group_name_continue?/1)

      [] ->
        false
    end
  rescue
    _ -> false
  end

  defp regexp_group_name_start?(char),
    do: char in ["$", "_"] or Regex.match?(~r/^\p{L}$/u, char)

  defp regexp_group_name_continue?(char),
    do:
      regexp_group_name_start?(char) or char in ["\u200C", "\u200D"] or
        Regex.match?(~r/^\p{N}$/u, char)

  defp decode_regexp_group_name(name) do
    ~r/\\u\{([0-9A-Fa-f]+)\}/
    |> Regex.replace(name, fn _all, hex -> decode_regexp_group_codepoint(hex) end)
    |> then(fn decoded ->
      Regex.replace(
        ~r/\\u([D-d][89A-Ba-b][0-9A-Fa-f]{2})\\u([D-d][C-Fc-f][0-9A-Fa-f]{2})/,
        decoded,
        fn _all, high, low ->
          decode_regexp_group_surrogate_pair(high, low)
        end
      )
    end)
    |> then(fn decoded ->
      Regex.replace(~r/\\u([0-9A-Fa-f]{4})/, decoded, fn _all, hex ->
        decode_regexp_group_codepoint(hex)
      end)
    end)
  end

  defp decode_regexp_group_surrogate_pair(high_hex, low_hex) do
    with {high, ""} <- Integer.parse(high_hex, 16),
         {low, ""} <- Integer.parse(low_hex, 16) do
      cp = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
      <<cp::utf8>>
    else
      _ -> "\\u" <> high_hex <> "\\u" <> low_hex
    end
  rescue
    _ -> "\\u" <> high_hex <> "\\u" <> low_hex
  end

  defp decode_regexp_group_codepoint(hex) do
    case Integer.parse(hex, 16) do
      {cp, ""} -> <<cp::utf8>>
      _ -> "\\u" <> hex
    end
  rescue
    _ -> "\\u" <> hex
  end

  defp starts_with_quantifier?(<<first::binary-size(1), _::binary>>), do: first in ["*", "+", "?"]
  defp starts_with_quantifier?(""), do: false

  defp dangling_escape?(source) do
    source
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> Enum.take_while(&(&1 == ?\\))
    |> length()
    |> rem(2) == 1
  end

  defp repeated_quantifier?(source) do
    String.contains?(source, ["**", "++", "???", "????"])
  end

  defp adjacent_interval_quantifiers?(source) do
    Regex.match?(~r/\{\d+(?:,\d*)?\}\{\d+(?:,\d*)?\}/, source)
  end

  defp invalid_interval_quantifier?(source) do
    ~r/\{(\d+),(\d+)\}/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.any?(fn [min, max] -> String.to_integer(max) < String.to_integer(min) end)
  end

  defp invalid_class_range?(source) do
    String.contains?(source, "[{-")
  end

  defp invalid_unicode_regexp_source?(source, flags) do
    (String.contains?(flags, "u") or String.contains?(flags, "v")) and
      (unicode_reserved_bracket?(source) or unicode_invalid_identity_escape?(source) or
         unicode_invalid_class_escape_range?(source) or unicode_invalid_bare_interval?(source) or
         unicode_quantified_assertion?(source))
  end

  defp unicode_reserved_bracket?(source), do: source in ["(", ")", "[", "]", "{", "}"]

  defp unicode_invalid_identity_escape?(source) do
    cond do
      Regex.match?(~r/\\(?:[1-9]|0[0-9])/, source) ->
        true

      source in ["\\u", "\\x", "\\c"] ->
        true

      Regex.match?(~r/(^|[^\\])\\[A-Za-z]/, source) ->
        not Regex.match?(~r/^\\(?:[bBfnrtvdDsSwW])$/, source)

      Regex.match?(~r/\[\\[A-Za-z]\]/, source) ->
        not Regex.match?(~r/^\[\\(?:[bfnrtvdDsSwW])\]$/, source)

      invalid_unicode_single_identity_escape?(source) ->
        true

      true ->
        false
    end
  end

  defp invalid_unicode_single_identity_escape?(<<"\\", ch>>) do
    not unicode_identity_escape_char?(ch, false)
  end

  defp invalid_unicode_single_identity_escape?(<<"[\\", ch, "]">>) do
    not unicode_identity_escape_char?(ch, true)
  end

  defp invalid_unicode_single_identity_escape?(_), do: false

  defp unicode_identity_escape_char?(ch, in_class?) do
    ch in ~c"^$\\.*+?()[]{}|/" or (in_class? and ch == ?-)
  end

  defp unicode_invalid_class_escape_range?(source),
    do:
      Regex.match?(~r/\[\\[dDsSwW]-[^\]]+\]/, source) or
        Regex.match?(~r/\[[^\]]+-\\[dDsSwW]\]/, source)

  defp unicode_invalid_bare_interval?(source),
    do:
      Regex.match?(~r/^\{\d+(?:,\d*)?\}\??$/, source) or
        Regex.match?(~r/^.?\{\d*(?:,\d*)?$/, source)

  defp unicode_quantified_assertion?(source), do: Regex.match?(~r/\(\?[=!][^)]*\)[*+?{]/, source)

  defp invalid_modifiers?(source) do
    ~r/\(\?([^):]+):/u
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.any?(fn [modifiers] -> invalid_modifier_text?(modifiers) end)
  end

  defp duplicate_group_name_in_alternative?(source) do
    source
    |> String.split("|")
    |> Enum.any?(fn alternative ->
      names =
        ~r/\(\?<([^>]+)>/
        |> Regex.scan(alternative, capture: :all_but_first)
        |> Enum.map(fn [name] -> name end)

      Enum.uniq(names) != names
    end)
  end

  defp invalid_modifier_text?(modifiers) do
    chars = modifiers |> String.replace("-", "") |> String.graphemes()
    Enum.any?(chars, &(&1 not in ~w(i m s))) or Enum.uniq(chars) != chars
  end

  defp descending_character_range?(source) do
    ~r/\[([^\]]*)\]/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.any?(fn [body] -> descending_range_in_class?(String.to_charlist(body)) end)
  end

  defp descending_range_in_class?([left, ?-, right | _rest]) when left > right and left != ?\\,
    do: true

  defp descending_range_in_class?([_ | rest]), do: descending_range_in_class?(rest)
  defp descending_range_in_class?([]), do: false

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def proxy([target, handler | _], _) do
    unless proxy_object?(target), do: JSThrow.type_error!("Proxy target must be an object")
    unless proxy_object?(handler), do: JSThrow.type_error!("Proxy handler must be an object")

    Heap.wrap(%{proxy_target() => target, proxy_handler() => handler})
  end

  def proxy(_, _), do: JSThrow.type_error!("Proxy target and handler are required")

  defp proxy_object?(value), do: Value.object_like?(value)

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def finalization_registry([_callback | _], _), do: finalization_registry_object()
  def finalization_registry(_, _), do: finalization_registry_object()

  defp finalization_registry_object do
    object do
      method "register" do
        :undefined
      end

      method "unregister" do
        :undefined
      end
    end
  end
end
