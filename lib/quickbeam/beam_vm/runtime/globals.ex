defmodule QuickBEAM.BeamVM.Runtime.Globals do
  @moduledoc "JS global scope: constructors, global functions, and the binding map."

  import QuickBEAM.BeamVM.Builtin, only: [build_object: 1]
  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.{Bytecode, Heap}
  alias QuickBEAM.BeamVM.Interpreter
  alias QuickBEAM.BeamVM.Runtime

  alias QuickBEAM.BeamVM.Runtime.{
    ArrayBuffer,
    Boolean,
    Console,
    Errors,
    GlobalNumeric,
    JSON,
    MapSet,
    Math,
    Object,
    PromiseBuiltins,
    Reflect,
    Symbol,
    TypedArray
  }

  alias QuickBEAM.BeamVM.Runtime.Date, as: JSDate

  def build do
    obj_proto = ensure_object_prototype()
    obj_ctor = register("Object", &object_constructor/2, prototype: obj_proto)

    bindings()
    |> Map.put("Object", obj_ctor)
    |> Map.merge(typed_arrays())
    |> Map.merge(Errors.bindings())
    |> tap(&Heap.put_global_cache/1)
  end

  # ── Binding map ──

  defp bindings do
    %{
      "Array" => register("Array", &array_constructor/2),
      "String" => register("String", &string_constructor/2),
      "Number" => register("Number", &number_constructor/2),
      "BigInt" => register("BigInt", &bigint_constructor/2),
      "Boolean" => register("Boolean", Boolean.constructor()),
      "Function" => register("Function", &function_constructor/2),
      "RegExp" => register("RegExp", &regexp_constructor/2),
      "Date" => register("Date", &JSDate.constructor/2, module: JSDate),
      "Promise" => register("Promise", PromiseBuiltins.constructor(), module: PromiseBuiltins),
      "Symbol" => register("Symbol", Symbol.constructor(), module: Symbol),
      "Map" => register("Map", MapSet.map_constructor()),
      "Set" => register("Set", MapSet.set_constructor()),
      "WeakMap" => register("WeakMap", MapSet.weak_map_constructor()),
      "WeakSet" => register("WeakSet", MapSet.weak_set_constructor()),
      "WeakRef" => register("WeakRef", fn _, _ -> Runtime.new_object() end),
      "FinalizationRegistry" =>
        register("FinalizationRegistry", fn [_callback | _], _ ->
          build_object do
            method "register" do
              :undefined
            end

            method "unregister" do
              :undefined
            end
          end
        end),
      "DataView" => register("DataView", fn _, _ -> Runtime.new_object() end),
      "ArrayBuffer" =>
        (
          ab_ctor = register("ArrayBuffer", &ArrayBuffer.constructor/2)

          Heap.put_ctor_static(
            ab_ctor,
            {:symbol, "Symbol.species"},
            {:accessor, {:builtin, "get [Symbol.species]", fn _, _ -> ab_ctor end}, nil}
          )

          ab_ctor
        ),
      "Proxy" => register("Proxy", &proxy_constructor/2),
      "Math" => Math.object(),
      "JSON" => JSON.object(),
      "Reflect" => Reflect.object(),
      "console" => Console.object(),
      "parseInt" => builtin("parseInt", &GlobalNumeric.parse_int/2),
      "parseFloat" => builtin("parseFloat", &GlobalNumeric.parse_float/2),
      "isNaN" => builtin("isNaN", &GlobalNumeric.nan?/2),
      "isFinite" => builtin("isFinite", &GlobalNumeric.finite?/2),
      "eval" => builtin("eval", &js_eval/2),
      "require" => builtin("require", &js_require/2),
      "structuredClone" => builtin("structuredClone", fn [val | _], _ -> val end),
      "queueMicrotask" => builtin("queueMicrotask", &queue_microtask/2),
      "gc" => builtin("gc", fn _, _ -> :undefined end),
      "os" => Heap.wrap(%{"platform" => "elixir"}),
      "qjs" =>
        build_object do
          method "getStringKind" do
            s = hd(args)
            if is_binary(s) and byte_size(s) > 256, do: 1, else: 0
          end
        end,
      "globalThis" => Runtime.new_object(),
      "NaN" => :nan,
      "Infinity" => :infinity,
      "undefined" => :undefined
    }
  end

  # ── Constructors ──

  defp object_constructor([arg | _], _) do
    case arg do
      {:symbol, _, _} = sym ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_symbol__" => sym})
        {:obj, ref}

      {:obj, _} = obj ->
        obj

      v when is_binary(v) ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_string__" => v})
        {:obj, ref}

      v when is_number(v) ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_number__" => v})
        {:obj, ref}

      v when is_boolean(v) ->
        ref = make_ref()
        Heap.put_obj(ref, %{"__wrapped_boolean__" => v})
        {:obj, ref}

      _ ->
        Runtime.new_object()
    end
  end

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
      {params, body} =
        case Enum.reverse(args) do
          [body | param_parts] ->
            {Enum.join(Enum.reverse(param_parts), ","), body}

          [] ->
            {"", ""}
        end

      code = "(function(" <> params <> "){" <> body <> "})"

      case QuickBEAM.Runtime.compile(ctx.runtime_pid, code) do
        {:ok, bc} ->
          case Bytecode.decode(bc) do
            {:ok, parsed} ->
              case Interpreter.eval(
                     parsed.value,
                     [],
                     %{gas: Runtime.gas_budget(), runtime_pid: ctx.runtime_pid},
                     parsed.atoms
                   ) do
                {:ok, val} -> val
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
    flags =
      case rest do
        [f | _] when is_binary(f) -> f
        _ -> ""
      end

    pat =
      case pattern do
        {:regexp, p, _} -> p
        s when is_binary(s) -> s
        _ -> ""
      end

    {:regexp, pat, flags}
  end

  defp proxy_constructor([target, handler | _], _) do
    Heap.wrap(%{proxy_target() => target, proxy_handler() => handler})
  end

  defp proxy_constructor(_, _), do: Runtime.new_object()

  # ── Global functions ──

  defp js_eval([code | _], _) when is_binary(code) do
    ctx = Heap.get_ctx()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, bc} <- QuickBEAM.Runtime.compile(pid, code),
         {:ok, parsed} <- Bytecode.decode(bc),
         {:ok, val} <-
           Interpreter.eval(
             parsed.value,
             [],
             %{gas: Runtime.gas_budget(), runtime_pid: pid},
             parsed.atoms
           ) do
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
    ta_base =
      {:builtin, "TypedArray",
       fn _args, _this ->
         throw(
           {:js_throw, Heap.make_error("Abstract class TypedArray cannot be called", "TypeError")}
         )
       end}

    ta_base_ref = make_ref()
    Heap.put_obj(ta_base_ref, %{"__proto__" => nil})
    Heap.put_ctor_static(ta_base, "prototype", {:obj, ta_base_ref})

    for {name, type} <- TypedArray.types(), into: %{} do
      ctor = register(name, TypedArray.constructor(type))
      Heap.put_ctor_static(ctor, "__proto__", ta_base)
      {name, ctor}
    end
  end
end
