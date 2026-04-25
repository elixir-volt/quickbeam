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

    # Set constructor on Object.prototype
    {:obj, proto_ref} = obj_proto
    proto_data = Heap.get_obj(proto_ref, %{})

    if is_map(proto_data),
      do: Heap.put_obj(proto_ref, Map.put(proto_data, "constructor", obj_ctor))

    bindings()
    |> Map.put("Object", obj_ctor)
    |> Map.merge(typed_arrays())
    |> Map.merge(Errors.bindings())
    |> tap(&Heap.put_global_cache/1)
  end

  # ── Binding map ──

  defp bindings do
    %{
      "Array" =>
        (
          ctor = register("Array", &Constructors.array/2)
          proto = QuickBEAM.VM.Runtime.Array.prototype()
          Heap.put_ctor_static(ctor, "prototype", proto)
          Heap.put_array_proto(proto)
          ctor
        ),
      "String" => register("String", &Constructors.string/2, auto_proto: true),
      "Number" => register("Number", &Constructors.number/2, auto_proto: true),
      "BigInt" => register("BigInt", &Constructors.bigint/2),
      "Boolean" => register("Boolean", Boolean.constructor(), auto_proto: true),
      "Function" =>
        (fn ->
           fun_ctor =
             register("Function", &Constructors.function/2,
               prototype: QuickBEAM.VM.Runtime.Function.prototype()
             )

           proto = Heap.get_ctor_statics(fun_ctor)["prototype"]

           if match?({:obj, _}, proto),
             do: QuickBEAM.VM.ObjectModel.Put.put(proto, "constructor", fun_ctor)

           fun_ctor
         end).(),
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
      "Proxy" =>
        (fn ->
           ctor = register("Proxy", &Constructors.proxy/2)

           Heap.put_ctor_static(
             ctor,
             "revocable",
             {:builtin, "revocable",
              fn [target, handler | _], _ ->
                proxy = Constructors.proxy([target, handler], nil)

                revoke_fn =
                  {:builtin, "revoke",
                   fn _, _ ->
                     :undefined
                   end}

                Heap.wrap(%{"proxy" => proxy, "revoke" => revoke_fn})
              end}
           )

           ctor
         end).(),
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
      nil ->
        if Keyword.get(opts, :auto_proto, false) do
          proto = Heap.wrap(%{"constructor" => ctor})
          Heap.put_class_proto(ctor, proto)
          Heap.put_ctor_static(ctor, "prototype", proto)
        end

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
