defmodule QuickBEAM.BeamVM.Runtime.Globals do
  @moduledoc "JS global scope: constructors, global functions, and the binding map."

  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.{Bytecode, Heap}
  alias QuickBEAM.BeamVM.Interpreter
  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Runtime.{ArrayBuffer, Boolean, Console, JSON, MapSet, Math, Object, Promise, Reflect, Symbol, TypedArray}
  alias QuickBEAM.BeamVM.Runtime.Date, as: JSDate

  @error_types ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError)

  def build do
    obj_proto = ensure_object_prototype()
    obj_ctor = register("Object", &object_constructor/2, prototype: obj_proto)

    bindings()
    |> Map.put("Object", obj_ctor)
    |> Map.merge(typed_arrays())
    |> Map.merge(error_types())
    |> tap(&Heap.put_global_cache/1)
  end

  # ── Binding map ──

  defp bindings do
    %{
      "Array"      => register("Array", &array_constructor/2),
      "String"     => register("String", &string_constructor/2),
      "Number"     => register("Number", &number_constructor/2),
      "BigInt"     => register("BigInt", &bigint_constructor/2),
      "Boolean"    => register("Boolean", Boolean.constructor()),
      "Function"   => register("Function", &function_constructor/2),
      "RegExp"     => register("RegExp", &regexp_constructor/2),
      "Date"       => register("Date", &JSDate.constructor/2, module: JSDate),
      "Promise"    => register("Promise", Promise.constructor(), module: Promise),
      "Symbol"     => register("Symbol", Symbol.constructor(), module: Symbol),
      "Map"        => register("Map", MapSet.map_constructor()),
      "Set"        => register("Set", MapSet.set_constructor()),
      "WeakMap"    => register("WeakMap", MapSet.weak_map_constructor()),
      "WeakSet"    => register("WeakSet", MapSet.weak_set_constructor()),
      "WeakRef"    => register("WeakRef", fn _, _ -> Runtime.new_object() end),
      "FinalizationRegistry" => register("FinalizationRegistry", fn [callback | _], _ ->
        Heap.wrap(%{
          "register" => {:builtin, "register", fn _, _ -> :undefined end},
          "unregister" => {:builtin, "unregister", fn _, _ -> :undefined end}
        })
      end),
      "DataView"   => register("DataView", fn _, _ -> Runtime.new_object() end),
      "ArrayBuffer" => register("ArrayBuffer", &ArrayBuffer.constructor/2),
      "Proxy"      => register("Proxy", &proxy_constructor/2),
      "Math"       => Math.object(),
      "JSON"       => JSON.object(),
      "Reflect"    => Reflect.object(),
      "console"    => Console.object(),
      "parseInt"   => builtin("parseInt", &parse_int/2),
      "parseFloat" => builtin("parseFloat", &parse_float/2),
      "isNaN"      => builtin("isNaN", &is_nan/2),
      "isFinite"   => builtin("isFinite", &is_finite/2),
      "eval"       => builtin("eval", &js_eval/2),
      "require"    => builtin("require", &js_require/2),
      "structuredClone" => builtin("structuredClone", fn [val | _], _ -> val end),
      "queueMicrotask"  => builtin("queueMicrotask", &queue_microtask/2),
      "gc"         => builtin("gc", fn _, _ -> :undefined end),
      "os"         => Heap.wrap(%{"platform" => "elixir"}),
      "qjs"        => Heap.wrap(%{"getStringKind" => builtin("getStringKind", fn [s | _], _ -> if is_binary(s) and byte_size(s) > 256, do: 1, else: 0 end)}),
      "globalThis" => Runtime.new_object(),
      "NaN"        => :nan,
      "Infinity"   => :infinity,
      "undefined"  => :undefined
    }
  end

  # ── Constructors ──

  defp object_constructor(_, _), do: Runtime.new_object()

  defp array_constructor(args, _) do
    list =
      case args do
        [n] when is_integer(n) and n >= 0 -> List.duplicate(:undefined, n)
        _ -> args
      end

    Heap.wrap(list)
  end

  defp string_constructor(args, _), do: Runtime.stringify(List.first(args, ""))
  defp number_constructor(args, _), do: Runtime.to_number(List.first(args, 0))

  defp function_constructor(args, _) do
    ctx = Heap.get_ctx()

    if ctx && ctx.runtime_pid do
      {params, body} = case Enum.reverse(args) do
        [body | param_parts] ->
          {Enum.join(Enum.reverse(param_parts), ","), body}
        [] -> {"", ""}
      end

      code = "(function(" <> params <> "){" <> body <> "})"

      case QuickBEAM.Runtime.compile(ctx.runtime_pid, code) do
        {:ok, bc} ->
          case Bytecode.decode(bc) do
            {:ok, parsed} ->
              case Interpreter.eval(parsed.value, [], %{gas: Runtime.gas_budget(), runtime_pid: ctx.runtime_pid}, parsed.atoms) do
                {:ok, val} -> val
                _ -> throw({:js_throw, Heap.make_error("Invalid function", "SyntaxError")})
              end
            _ -> throw({:js_throw, Heap.make_error("Invalid function", "SyntaxError")})
          end
        {:error, %{message: msg}} -> throw({:js_throw, Heap.make_error(msg, "SyntaxError")})
        _ -> throw({:js_throw, Heap.make_error("Invalid function", "SyntaxError")})
      end
    else
      throw({:js_throw, Heap.make_error("Function constructor requires runtime", "Error")})
    end
  end

  defp bigint_constructor([n | _], _) when is_integer(n), do: {:bigint, n}
  defp bigint_constructor([{:bigint, n} | _], _), do: {:bigint, n}

  defp bigint_constructor([s | _], _) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:bigint, n}
      _ -> throw({:js_throw, Heap.make_error("Cannot convert to BigInt", "SyntaxError")})
    end
  end

  defp bigint_constructor(_, _) do
    throw({:js_throw, Heap.make_error("Cannot convert to BigInt", "TypeError")})
  end

  defp regexp_constructor([pattern | rest], _) do
    flags = case rest do
      [f | _] when is_binary(f) -> f
      _ -> ""
    end

    pat = case pattern do
      {:regexp, p, _} -> p
      s when is_binary(s) -> s
      _ -> ""
    end

    {:regexp, pat, flags}
  end

  defp error_constructor(args, _) do
    msg = List.first(args, "")
    Heap.wrap(%{"message" => Runtime.stringify(msg), "stack" => ""})
  end

  defp proxy_constructor([target, handler | _], _) do
    Heap.wrap(%{proxy_target() => target, proxy_handler() => handler})
  end

  defp proxy_constructor(_, _), do: Runtime.new_object()

  # ── Global functions ──

  defp parse_int([s, radix | _], _) when is_binary(s) and is_number(radix) do
    r = trunc(radix)
    s = String.trim_leading(s)

    cond do
      r == 0 or r == 10 ->
        parse_int([s], nil)

      r == 16 ->
        s = s |> String.replace_prefix("0x", "") |> String.replace_prefix("0X", "")
        case Integer.parse(s, 16) do
          {n, _} -> n
          :error -> :nan
        end

      r >= 2 and r <= 36 ->
        case Integer.parse(s, r) do
          {n, _} -> n
          :error -> :nan
        end

      true ->
        :nan
    end
  end

  defp parse_int([s | _], _) when is_binary(s) do
    s = String.trim_leading(s)

    if String.starts_with?(s, "0x") or String.starts_with?(s, "0X") do
      case Integer.parse(String.slice(s, 2..-1//1), 16) do
        {n, _} -> n
        :error -> :nan
      end
    else
      case Integer.parse(s) do
        {n, _} -> n
        :error -> :nan
      end
    end
  end

  defp parse_int([n | _], _) when is_number(n), do: trunc(n)
  defp parse_int(_, _), do: :nan

  defp parse_float([s | _], _) when is_binary(s) do
    s = String.trim(s)

    cond do
      s == "Infinity" or s == "+Infinity" -> :infinity
      s == "-Infinity" -> :neg_infinity
      true ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> :nan
        end
    end
  end

  defp parse_float([n | _], _) when is_number(n), do: n * 1.0
  defp parse_float(_, _), do: :nan

  defp is_nan([:nan | _], _), do: true
  defp is_nan([n | _], _) when is_number(n), do: false

  defp is_nan([s | _], _) when is_binary(s) do
    case Float.parse(s) do
      :error -> true
      _ -> false
    end
  end

  defp is_nan(_, _), do: true

  defp is_finite([n | _], _) when is_number(n), do: true
  defp is_finite([:infinity | _], _), do: false
  defp is_finite([:neg_infinity | _], _), do: false
  defp is_finite(_, _), do: false

  defp js_eval([code | _], _) when is_binary(code) do
    ctx = Heap.get_ctx()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, bc} <- QuickBEAM.Runtime.compile(pid, code),
         {:ok, parsed} <- Bytecode.decode(bc),
         {:ok, val} <- Interpreter.eval(parsed.value, [], %{gas: Runtime.gas_budget(), runtime_pid: pid}, parsed.atoms) do
      val
    else
      %{runtime_pid: nil} -> :undefined
      nil -> :undefined
      {:error, %{message: msg}} -> throw({:js_throw, Heap.make_error(msg, "SyntaxError")})
      {:error, msg} when is_binary(msg) -> throw({:js_throw, Heap.make_error(msg, "SyntaxError")})
      _ -> :undefined
    end
  end

  defp js_eval(_, _), do: :undefined

  defp js_require([name | _], _) do
    case Heap.get_module(name) do
      nil -> throw({:js_throw, Heap.make_error("Cannot find module '#{name}'", "Error")})
      exports -> exports
    end
  end

  defp queue_microtask([cb | _], _) do
    Heap.enqueue_microtask({:resolve, nil, cb, :undefined})
    :undefined
  end

  # ── Public API (called by Number.parseInt/parseFloat statics) ──

  def parse_int(args), do: parse_int(args, nil)
  def parse_float(args), do: parse_float(args, nil)
  def is_nan(args), do: is_nan(args, nil)
  def is_finite(args), do: is_finite(args, nil)

  # ── Registration helpers ──

  defp builtin(name, fun), do: {:builtin, name, fun}

  defp register(name, constructor, opts \\ []) do
    ctor = {:builtin, name, constructor}

    case Keyword.get(opts, :module) do
      nil -> :ok
      mod -> Heap.put_ctor_static(ctor, :__module__, mod)
    end

    case Keyword.get(opts, :prototype) do
      nil ->
        :ok

      proto ->
        Heap.put_class_proto(ctor, proto)
        Heap.put_ctor_static(ctor, "prototype", proto)
    end

    ctor
  end

  defp ensure_object_prototype do
    case Heap.get_object_prototype() do
      nil -> Object.build_prototype()
      existing -> existing
    end
  end

  defp typed_arrays do
    for {name, type} <- TypedArray.types(), into: %{} do
      {name, register(name, TypedArray.constructor(type))}
    end
  end

  defp error_types do
    for name <- @error_types, into: %{} do
      proto_ref = make_ref()
      ctor = {:builtin, name, &error_constructor/2}
      Heap.put_obj(proto_ref, %{"name" => name, "message" => "", "constructor" => ctor})
      Heap.put_class_proto(ctor, {:obj, proto_ref})
      Heap.put_ctor_static(ctor, "prototype", {:obj, proto_ref})

      if name == "Error" do
        Heap.put_ctor_static(ctor, "captureStackTrace",
          {:builtin, "captureStackTrace", fn [obj | _], _ ->
            case obj do
              {:obj, ref} -> Heap.update_obj(ref, %{}, &Map.put(&1, "stack", ""))
              _ -> :ok
            end
            :undefined
          end})
        Heap.put_ctor_static(ctor, "stackTraceLimit", 10)
      end

      {name, ctor}
    end
  end

end
