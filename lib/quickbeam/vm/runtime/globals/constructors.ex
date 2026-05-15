defmodule QuickBEAM.VM.Runtime.Globals.Constructors do
  @moduledoc "Global constructor built-ins: `Object`, `Array`, `String`, `Boolean`, and other wrapper constructors."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1]
  import QuickBEAM.VM.Value, only: [is_builtin: 1, is_closure: 1]

  alias QuickBEAM.VM.{BytecodeParser, Heap}
  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def object([arg | _], _) do
    case arg do
      {:symbol, _, _} = symbol ->
        WrappedPrimitive.wrap(symbol)

      {:obj, _} = obj ->
        obj

      %QuickBEAM.VM.Function{} = value ->
        value

      value when is_closure(value) or is_builtin(value) ->
        value

      {:bound, _, _, _, _} = value ->
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

  defp ordinary_object do
    ref = make_ref()

    data =
      case QuickBEAM.VM.Runtime.Constructors.class_proto("Object") do
        {:obj, _} = proto -> %{"__proto__" => proto}
        _ -> %{}
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
    case QuickBEAM.VM.ObjectModel.Prototype.get(this) do
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
        QuickBEAM.VM.ObjectModel.Put.put(this, WrappedPrimitive.slot(:string), val)
        this
    end
  end

  def string(args, _), do: args |> arg(0, "") |> Runtime.stringify()

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def number(args, {:obj, _} = this) do
    val = args |> arg(0, 0) |> Runtime.to_number()
    QuickBEAM.VM.ObjectModel.Put.put(this, WrappedPrimitive.slot(:number), val)
    this
  end

  def number(args, _), do: args |> arg(0, 0) |> Runtime.to_number()

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def function(args, _), do: dynamic_function(args, "function")
  def generator_function(args, _), do: dynamic_function(args, "function*")
  def async_function(args, _), do: dynamic_function(args, "async function")
  def async_generator_function(args, _), do: dynamic_function(args, "async function*")

  defp dynamic_function(args, prefix) do
    ctx = Heap.get_ctx()

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

      case QuickBEAM.Runtime.compile(ctx.runtime_pid, code) do
        {:ok, bytecode} ->
          case BytecodeParser.decode(bytecode) do
            {:ok, parsed} ->
              case Interpreter.eval(
                     parsed.value,
                     [],
                     %{gas: Runtime.gas_budget(), runtime_pid: ctx.runtime_pid},
                     parsed.atoms
                   ) do
                {:ok, value} -> value
                _ -> JSThrow.syntax_error!("Invalid function")
              end

            _ ->
              JSThrow.syntax_error!("Invalid function")
          end

        _ ->
          JSThrow.syntax_error!("Invalid function")
      end
    else
      JSThrow.error!("Function constructor requires runtime")
    end
  end

  defp stringify_arg(val) when is_binary(val), do: val
  defp stringify_arg(val), do: QuickBEAM.VM.Interpreter.Values.stringify(val)

  def bigint([n | _], _) when is_integer(n), do: {:bigint, n}
  def bigint([{:bigint, n} | _], _), do: {:bigint, n}

  def bigint([string | _], _) when is_binary(string) do
    case Integer.parse(string) do
      {n, ""} -> {:bigint, n}
      _ -> JSThrow.syntax_error!("Cannot convert to BigInt")
    end
  end

  def bigint([value | _], _) do
    case Runtime.to_number(value) do
      n when is_integer(n) -> {:bigint, n}
      n when is_float(n) and n == trunc(n) -> {:bigint, trunc(n)}
      _ -> JSThrow.type_error!("Cannot convert to BigInt")
    end
  end

  def bigint(_, _) do
    JSThrow.type_error!("Cannot convert to BigInt")
  end

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
      validate_regexp_source!(source)

      ref = make_ref()
      RegexpState.put(ref, "flags", flags)
      RegexpState.put(ref, "lastIndex", 0)

      case this do
        {:obj, this_ref} ->
          case Heap.get_obj(this_ref, %{}) do
            %{proto() => instance_proto} -> RegexpState.put(ref, proto(), instance_proto)
            _ -> :ok
          end

        _ ->
          :ok
      end

      {:regexp, nil, source, ref}
    end
  end

  defp regexp_function_identity?(pattern, rest, this) do
    regexp_value?(pattern) and regexp_flags_omitted?(rest) and not regexp_constructing?(this)
  end

  defp regexp_value?({:regexp, _, _}), do: true
  defp regexp_value?({:regexp, _, _, _}), do: true

  defp regexp_value?({:obj, _} = obj) do
    regexp_like?(obj) and Get.get(obj, "constructor") == QuickBEAM.VM.Runtime.Constructors.lookup("RegExp")
  end

  defp regexp_value?(_), do: false

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
    if regexp_like?(obj), do: Runtime.stringify(Get.get(obj, "source")), else: Runtime.stringify(obj)
  end

  defp regexp_source_flags({:regexp, bytecode, _source}) do
    QuickBEAM.VM.ObjectModel.Get.regexp_flags(bytecode)
  end

  defp regexp_source_flags({:regexp, bytecode, _source, ref}) do
    case RegexpState.fetch(ref, "flags") do
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

    unless valid? and unique? do
      JSThrow.syntax_error!("Invalid regular expression flags")
    end
  end

  defp validate_regexp_source!(source) when is_binary(source) do
    if invalid_regexp_source?(source) do
      JSThrow.syntax_error!("Invalid regular expression")
    end
  end

  defp invalid_regexp_source?(source) do
    starts_with_quantifier?(source) or dangling_escape?(source) or
      repeated_quantifier?(source) or adjacent_interval_quantifiers?(source) or invalid_class_range?(source) or
      descending_character_range?(source)
  end

  defp starts_with_quantifier?(<<first::binary-size(1), _::binary>>), do: first in ["*", "+", "?"]
  defp starts_with_quantifier?(""), do: false

  defp dangling_escape?(source) do
    source
    |> String.to_charlist()
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

  defp invalid_class_range?(source) do
    String.contains?(source, ["[{-", "--"])
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
    Heap.wrap(%{proxy_target() => target, proxy_handler() => handler})
  end

  def proxy(_, _), do: Runtime.new_object()

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
