defmodule QuickBEAM.VM.Runtime.Globals do
  @moduledoc "JS global scope: constructors, global functions, and the binding map."

  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime

  alias QuickBEAM.VM.Runtime.{
    ArrayBuffer,
    Boolean,
    Console,
    Errors,
    GlobalNumeric,
    JSON,
    Math,
    Object,
    PromiseBuiltins,
    Reflect,
    Symbol,
    TypedArray
  }

  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.Globals.{Constructors, Functions}
  alias QuickBEAM.VM.Runtime.Map, as: JSMap
  alias QuickBEAM.VM.Runtime.Set, as: JSSet

  def build do
    obj_proto = ensure_object_prototype()
    obj_ctor = register("Object", &Constructors.object/2, prototype: obj_proto)

    bindings()
    |> Map.put("Object", obj_ctor)
    |> Map.merge(typed_arrays())
    |> Map.merge(Errors.bindings())
    |> tap(&Heap.put_global_cache/1)
  end

  # ── Binding map ──

  defp bindings do
    %{
      "Array" => register("Array", &Constructors.array/2),
      "String" => register("String", &Constructors.string/2),
      "Number" => register("Number", &Constructors.number/2),
      "BigInt" => register("BigInt", &Constructors.bigint/2),
      "Boolean" => register("Boolean", Boolean.constructor()),
      "Function" => register("Function", &Constructors.function/2),
      "RegExp" => register("RegExp", &Constructors.regexp/2),
      "Date" => register("Date", &JSDate.constructor/2, module: JSDate),
      "Promise" =>
        register("Promise", PromiseBuiltins.constructor(),
          module: PromiseBuiltins,
          prototype: PromiseBuiltins.prototype()
        ),
      "Symbol" => register("Symbol", Symbol.constructor(), module: Symbol),
      "Map" => register("Map", JSMap.constructor()),
      "Set" => register("Set", JSSet.constructor()),
      "WeakMap" => register("WeakMap", JSMap.weak_constructor()),
      "WeakSet" => register("WeakSet", JSSet.weak_constructor()),
      "WeakRef" => register("WeakRef", fn _, _ -> Runtime.new_object() end),
      "FinalizationRegistry" =>
        register("FinalizationRegistry", &Constructors.finalization_registry/2),
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
      "Proxy" => register("Proxy", &Constructors.proxy/2),
      "Math" => Math.object(),
      "JSON" => JSON.object(),
      "Reflect" => Reflect.object(),
      "console" => Console.object(),
      "parseInt" => builtin("parseInt", &GlobalNumeric.parse_int/2),
      "parseFloat" => builtin("parseFloat", &GlobalNumeric.parse_float/2),
      "isNaN" => builtin("isNaN", &GlobalNumeric.nan?/2),
      "isFinite" => builtin("isFinite", &GlobalNumeric.finite?/2),
      "eval" => builtin("eval", &Functions.js_eval/2),
      "require" => builtin("require", &Functions.js_require/2),
      "structuredClone" => builtin("structuredClone", fn [val | _], _ -> val end),
      "queueMicrotask" => builtin("queueMicrotask", &Functions.queue_microtask/2),
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

  # ── Registration helpers ──

  defp builtin(name, fun), do: {:builtin, name, fun}

  defp register(name, constructor, opts \\ []) do
    ctor = {:builtin, name, constructor}

    case Keyword.get(opts, :module) do
      nil -> :ok
      mod -> Heap.put_ctor_static(ctor, :__module__, mod)
    end

    case Keyword.get(opts, :prototype) do
      nil -> :ok
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
