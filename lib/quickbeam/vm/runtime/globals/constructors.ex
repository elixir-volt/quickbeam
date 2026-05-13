defmodule QuickBEAM.VM.Runtime.Globals.Constructors do
  @moduledoc "Global constructor built-ins: `Object`, `Array`, `String`, `Boolean`, and other wrapper constructors."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1]
  import QuickBEAM.VM.Value, only: [is_builtin: 1, is_closure: 1]

  alias QuickBEAM.VM.{BytecodeParser, Heap}
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.WrappedPrimitive
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
          Heap.wrap(args)
      end

    inherit_array_prototype(result, this)
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
    val = args |> arg(0, "") |> Runtime.stringify()
    QuickBEAM.VM.ObjectModel.Put.put(this, WrappedPrimitive.slot(:string), val)
    this
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

  def bigint(_, _) do
    JSThrow.type_error!("Cannot convert to BigInt")
  end

  @doc "Helper for global constructor built-ins: `object`, `array`, `string`, `boolean`, and other wrapper constructors."
  def regexp([], this), do: regexp(["" | []], this)

  def regexp([pattern | rest], _) do
    flags =
      case rest do
        [flag | _] when is_binary(flag) -> flag
        _ -> ""
      end

    source =
      case pattern do
        {:regexp, value, _} -> value
        value when is_binary(value) -> value
        _ -> ""
      end

    {:regexp, source, flags}
  end

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
