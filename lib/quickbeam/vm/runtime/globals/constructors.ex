defmodule QuickBEAM.VM.Runtime.Globals.Constructors do
  @moduledoc false

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  alias QuickBEAM.VM.{Bytecode, Heap}
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Runtime

  def object([arg | _], _) do
    case arg do
      {:symbol, _, _} = symbol ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_symbol__" => symbol})
        {:obj, ref}

      {:obj, _} = obj ->
        obj

      value when is_binary(value) ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_string__" => value})
        {:obj, ref}

      value when is_number(value) ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_number__" => value})
        {:obj, ref}

      value when is_boolean(value) ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_boolean__" => value})
        {:obj, ref}

      {:bigint, _} = value ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_bigint__" => value})
        {:obj, ref}

      _ ->
        Runtime.new_object()
    end
  end

  def object(_, _), do: Runtime.new_object()

  def array(args, _) do
    list =
      case args do
        [n] when is_integer(n) and n >= 0 -> List.duplicate(:undefined, n)
        _ -> args
      end

    Heap.wrap(list)
  end

  def string(args, _), do: Runtime.stringify(List.first(args, ""))
  def number(args, _), do: Runtime.to_number(List.first(args, 0))

  def function(args, _) do
    ctx = Heap.get_ctx()

    if ctx && ctx.runtime_pid do
      {params, body} =
        case Enum.reverse(args) do
          [body | param_parts] ->
            {Enum.join(Enum.reverse(param_parts), ","), body}

          [] ->
            {"", ""}
        end

      code = "(function(" <> params <> "){" <> body <> "})"

      case QuickBEAM.Runtime.compile(ctx.runtime_pid, code) do
        {:ok, bytecode} ->
          case Bytecode.decode(bytecode) do
            {:ok, parsed} ->
              case Interpreter.eval(
                     parsed.value,
                     [],
                     %{gas: Runtime.gas_budget(), runtime_pid: ctx.runtime_pid},
                     parsed.atoms
                   ) do
                {:ok, value} -> value
                _ -> throw({:js_throw, Heap.make_error("Invalid function", "SyntaxError")})
              end

            _ ->
              throw({:js_throw, Heap.make_error("Invalid function", "SyntaxError")})
          end

        _ ->
          throw({:js_throw, Heap.make_error("Invalid function", "SyntaxError")})
      end
    else
      throw({:js_throw, Heap.make_error("Function constructor requires runtime", "Error")})
    end
  end

  def bigint([n | _], _) when is_integer(n), do: {:bigint, n}
  def bigint([{:bigint, n} | _], _), do: {:bigint, n}

  def bigint([string | _], _) when is_binary(string) do
    case Integer.parse(string) do
      {n, ""} -> {:bigint, n}
      _ -> throw({:js_throw, Heap.make_error("Cannot convert to BigInt", "SyntaxError")})
    end
  end

  def bigint(_, _) do
    throw({:js_throw, Heap.make_error("Cannot convert to BigInt", "TypeError")})
  end

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

  def proxy([target, handler | _], _) do
    Heap.wrap(%{proxy_target() => target, proxy_handler() => handler})
  end

  def proxy(_, _), do: Runtime.new_object()

  def finalization_registry([_callback | _], _) do
    build_object do
      method "register" do
        :undefined
      end

      method "unregister" do
        :undefined
      end
    end
  end

  def finalization_registry(_, _) do
    build_object do
      method "register" do
        :undefined
      end

      method "unregister" do
        :undefined
      end
    end
  end
end
