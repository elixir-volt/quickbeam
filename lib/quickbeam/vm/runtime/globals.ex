defmodule QuickBEAM.VM.Runtime.Globals do
  @moduledoc "JS global scope: constructors, global functions, and the binding map."

  import QuickBEAM.VM.Builtin, only: [object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime

  alias QuickBEAM.VM.Runtime.WebAPIs

  alias QuickBEAM.VM.Runtime.{
    ArrayBuffer,
    Boolean,
    Console,
    Errors,
    GlobalNumeric,
    JSON,
    Math,
    Number,
    Object,
    PromiseBuiltins,
    RegExp,
    Reflect,
    Symbol,
    Test262Host,
    TypedArray
  }

  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.String, as: JSString
  alias QuickBEAM.VM.Runtime.Globals.{Constructors, Functions}
  alias QuickBEAM.VM.Runtime.Map, as: JSMap
  alias QuickBEAM.VM.Runtime.Set, as: JSSet

  @doc "Builds the runtime value represented by this module."
  def build do
    obj_proto = ensure_object_prototype()
    obj_ctor = register("Object", &Constructors.object/2, module: Object, prototype: obj_proto)

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
    |> Map.merge(WebAPIs.bindings())
    |> tap(&install_global_this_properties/1)
    |> tap(&Heap.put_global_cache/1)
  end

  defp install_global_this_properties(%{"globalThis" => {:obj, ref}} = bindings) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        globals = Map.delete(bindings, "globalThis")
        Heap.put_obj(ref, Map.merge(globals, map))
        install_global_property_descriptors(ref, globals)

      _ ->
        :ok
    end
  end

  defp install_global_this_properties(_), do: :ok

  defp install_global_property_descriptors(ref, globals) do
    Enum.each(globals, fn
      {key, {:builtin, _, _}} ->
        Heap.put_prop_desc(ref, key, %{writable: true, enumerable: false, configurable: true})

      {key, _value} when key in ["NaN", "Infinity", "undefined"] ->
        Heap.put_prop_desc(ref, key, %{writable: false, enumerable: false, configurable: false})

      {_key, _value} ->
        :ok
    end)
  end

  # ── Binding map ──

  defp bindings do
    %{
      "$262" => Test262Host.object(),
      "Array" =>
        (
          ctor = register("Array", &Constructors.array/2, module: QuickBEAM.VM.Runtime.Array)
          proto = QuickBEAM.VM.Runtime.Array.prototype()
          ConstructorRegistry.put_prototype(ctor, proto)
          Heap.put_array_proto(proto)

          case proto do
            {:obj, proto_ref} ->
              Heap.put_obj_key(proto_ref, "constructor", ctor)

              Heap.put_prop_desc(proto_ref, "constructor", %{
                writable: true,
                enumerable: false,
                configurable: true
              })

            _ ->
              :ok
          end

          sym_species = {:symbol, "Symbol.species"}

          Heap.put_ctor_static(
            ctor,
            sym_species,
            {:accessor, {:builtin, "get [Symbol.species]", fn _args, this -> this end}, nil}
          )

          Heap.put_ctor_prop_desc(ctor, sym_species, %{enumerable: false, configurable: true})

          Heap.put_ctor_static(ctor, "length", 1)

          Heap.put_ctor_prop_desc(ctor, "length", %{
            writable: false,
            enumerable: false,
            configurable: true
          })

          Heap.put_ctor_prop_desc(ctor, "prototype", %{
            writable: false,
            enumerable: false,
            configurable: false
          })

          ctor
        ),
      "String" =>
        (fn ->
           ctor = register("String", &Constructors.string/2, module: JSString, auto_proto: true)

           install_prototype_methods(
             ctor,
             JSString,
             ~w(charAt charCodeAt codePointAt indexOf lastIndexOf includes startsWith endsWith slice substring substr split trim trimStart trimEnd toUpperCase toLowerCase repeat padStart padEnd replace replaceAll match matchAll localeCompare search normalize concat toString valueOf at isWellFormed toWellFormed)
           )

           case Heap.get_ctor_statics(ctor)["prototype"] do
             {:obj, proto_ref} ->
               QuickBEAM.VM.ObjectModel.Put.put({:obj, proto_ref}, "constructor", ctor)

               Heap.put_prop_desc(proto_ref, "constructor", %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

             _ ->
               :ok
           end

           Heap.put_prop_desc(ctor, "prototype", %{
             writable: false,
             enumerable: false,
             configurable: false
           })

           ctor
         end).(),
      "Number" =>
        (fn ->
           ctor = register("Number", &Constructors.number/2, module: Number, auto_proto: true)

           install_prototype_methods(
             ctor,
             Number,
             ~w(toString toFixed valueOf toExponential toPrecision toLocaleString)
           )

           case Heap.get_ctor_statics(ctor)["prototype"] do
             {:obj, proto_ref} ->
               QuickBEAM.VM.ObjectModel.Put.put({:obj, proto_ref}, "constructor", ctor)

               Heap.put_prop_desc(proto_ref, "constructor", %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

             _ ->
               :ok
           end

           ctor
         end).(),
      "BigInt" => register("BigInt", &Constructors.bigint/2),
      "Boolean" => register("Boolean", Boolean.constructor(), module: Boolean, auto_proto: true),
      "Function" =>
        (fn ->
           fun_ctor =
             register("Function", &Constructors.function/2,
               prototype: QuickBEAM.VM.Runtime.Function.prototype()
             )

           proto = Heap.get_ctor_statics(fun_ctor)["prototype"]

           if match?({:obj, _}, proto),
             do: QuickBEAM.VM.ObjectModel.Put.put(proto, "constructor", fun_ctor)

           Heap.put_prop_desc(fun_ctor, "prototype", %{
             writable: false,
             enumerable: false,
             configurable: false
           })

           fun_ctor
         end).(),
      "RegExp" =>
        (fn ->
           ctor = register("RegExp", &Constructors.regexp/2, module: RegExp, auto_proto: true)
           install_prototype_methods(ctor, RegExp, ~w(exec test toString))
           install_regexp_prototype_accessors(ctor)
           ctor
         end).(),
      "Date" =>
        (fn ->
           ctor = register("Date", &JSDate.constructor/2, module: JSDate, auto_proto: true)
           install_date_prototype_methods(ctor)
           ctor
         end).(),
      "Promise" =>
        register("Promise", PromiseBuiltins.constructor(),
          module: PromiseBuiltins,
          prototype: PromiseBuiltins.prototype()
        ),
      "Symbol" => register("Symbol", Symbol.constructor(), module: Symbol),
      "Map" =>
        (fn ->
           ctor = register("Map", JSMap.constructor(), auto_proto: true)

           Heap.put_ctor_prop_desc(ctor, "prototype", %{
             writable: false,
             enumerable: false,
             configurable: false
           })

           group_by = {:builtin, "groupBy", fn args, _this -> JSMap.group_by(args) end}
           Heap.put_ctor_static(ctor, "groupBy", group_by)

           sym_species = {:symbol, "Symbol.species"}

           Heap.put_ctor_static(
             ctor,
             sym_species,
             {:accessor, {:builtin, "get [Symbol.species]", fn _args, this -> this end}, nil}
           )

           Heap.put_ctor_prop_desc(ctor, sym_species, %{enumerable: false, configurable: true})

           case Heap.get_ctor_statics(ctor)["prototype"] do
             {:obj, proto_ref} ->
               Heap.put_obj_key(proto_ref, "__proto__", Heap.get_object_prototype())

               for name <-
                     ~w(get set has delete clear keys values entries forEach getOrInsert getOrInsertComputed) do
                 method = JSMap.proto_property(name)
                 Heap.put_obj_key(proto_ref, name, method)

                 if name in ~w(keys values entries) do
                   Heap.put_ctor_static(method, "length", 0)

                   Heap.put_ctor_prop_desc(method, "length", %{
                     writable: false,
                     enumerable: false,
                     configurable: true
                   })
                 end

                 Heap.put_prop_desc(proto_ref, name, %{
                   writable: true,
                   enumerable: false,
                   configurable: true
                 })
               end

               sym_iter = {:symbol, "Symbol.iterator"}
               Heap.put_obj_key(proto_ref, sym_iter, JSMap.proto_property(sym_iter))

               Heap.put_prop_desc(proto_ref, sym_iter, %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

               Heap.put_obj_key(
                 proto_ref,
                 "size",
                 {:accessor, {:builtin, "get size", fn _args, this -> JSMap.size(this) end}, nil}
               )

               Heap.put_prop_desc(proto_ref, "size", %{enumerable: false, configurable: true})

               sym_to_string_tag = {:symbol, "Symbol.toStringTag"}
               Heap.put_obj_key(proto_ref, sym_to_string_tag, "Map")

               Heap.put_prop_desc(proto_ref, sym_to_string_tag, %{
                 writable: false,
                 enumerable: false,
                 configurable: true
               })

               QuickBEAM.VM.ObjectModel.Put.put({:obj, proto_ref}, "constructor", ctor)

               Heap.put_prop_desc(proto_ref, "constructor", %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

             _ ->
               :ok
           end

           ctor
         end).(),
      "Set" =>
        (fn ->
           ctor = register("Set", JSSet.constructor(), auto_proto: true)

           case Heap.get_ctor_statics(ctor)["prototype"] do
             {:obj, proto_ref} ->
               Heap.put_obj_key(proto_ref, "__proto__", Heap.get_object_prototype())

               for name <-
                     ~w(has add delete clear values keys entries forEach difference intersection union symmetricDifference isSubsetOf isSupersetOf isDisjointFrom) do
                 method = JSSet.proto_property(name)
                 Heap.put_obj_key(proto_ref, name, method)

                 if name in ~w(keys values entries) do
                   Heap.put_ctor_static(method, "length", 0)

                   Heap.put_ctor_prop_desc(method, "length", %{
                     writable: false,
                     enumerable: false,
                     configurable: true
                   })
                 end

                 Heap.put_prop_desc(proto_ref, name, %{
                   writable: true,
                   enumerable: false,
                   configurable: true
                 })
               end

               sym_iter = {:symbol, "Symbol.iterator"}
               Heap.put_obj_key(proto_ref, sym_iter, JSSet.proto_property(sym_iter))

               Heap.put_prop_desc(proto_ref, sym_iter, %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

               Heap.put_obj_key(
                 proto_ref,
                 "size",
                 {:accessor, {:builtin, "get size", fn _args, this -> JSSet.size(this) end}, nil}
               )

               Heap.put_prop_desc(proto_ref, "size", %{enumerable: false, configurable: true})

               sym_to_string_tag = {:symbol, "Symbol.toStringTag"}
               Heap.put_obj_key(proto_ref, sym_to_string_tag, "Set")

               Heap.put_prop_desc(proto_ref, sym_to_string_tag, %{
                 writable: false,
                 enumerable: false,
                 configurable: true
               })

               QuickBEAM.VM.ObjectModel.Put.put({:obj, proto_ref}, "constructor", ctor)

               Heap.put_prop_desc(proto_ref, "constructor", %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

             _ ->
               :ok
           end

           sym_species = {:symbol, "Symbol.species"}

           Heap.put_ctor_static(
             ctor,
             sym_species,
             {:accessor, {:builtin, "get [Symbol.species]", fn _args, this -> this end}, nil}
           )

           Heap.put_ctor_prop_desc(ctor, sym_species, %{
             enumerable: false,
             configurable: true
           })

           ctor
         end).(),
      "WeakMap" =>
        (fn ->
           ctor = register("WeakMap", JSMap.weak_constructor(), auto_proto: true)

           Heap.put_ctor_prop_desc(ctor, "prototype", %{
             writable: false,
             enumerable: false,
             configurable: false
           })

           case Heap.get_ctor_statics(ctor)["prototype"] do
             {:obj, proto_ref} ->
               Heap.put_obj_key(proto_ref, "__proto__", Heap.get_object_prototype())

               Heap.put_prop_desc(proto_ref, "constructor", %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

               for name <- ~w(get set has delete getOrInsert getOrInsertComputed) do
                 Heap.put_obj_key(proto_ref, name, JSMap.weak_proto_property(name))

                 Heap.put_prop_desc(proto_ref, name, %{
                   writable: true,
                   enumerable: false,
                   configurable: true
                 })
               end

               sym_to_string_tag = {:symbol, "Symbol.toStringTag"}
               Heap.put_obj_key(proto_ref, sym_to_string_tag, "WeakMap")

               Heap.put_prop_desc(proto_ref, sym_to_string_tag, %{
                 writable: false,
                 enumerable: false,
                 configurable: true
               })

             _ ->
               :ok
           end

           ctor
         end).(),
      "WeakSet" =>
        (fn ->
           ctor = register("WeakSet", JSSet.weak_constructor(), auto_proto: true)

           Heap.put_ctor_prop_desc(ctor, "prototype", %{
             writable: false,
             enumerable: false,
             configurable: false
           })

           case Heap.get_ctor_statics(ctor)["prototype"] do
             {:obj, proto_ref} ->
               Heap.put_obj_key(proto_ref, "__proto__", Heap.get_object_prototype())

               Heap.put_prop_desc(proto_ref, "constructor", %{
                 writable: true,
                 enumerable: false,
                 configurable: true
               })

               for name <- ~w(add has delete) do
                 Heap.put_obj_key(proto_ref, name, JSSet.weak_proto_property(name))

                 Heap.put_prop_desc(proto_ref, name, %{
                   writable: true,
                   enumerable: false,
                   configurable: true
                 })
               end

               sym_to_string_tag = {:symbol, "Symbol.toStringTag"}
               Heap.put_obj_key(proto_ref, sym_to_string_tag, "WeakSet")

               Heap.put_prop_desc(proto_ref, sym_to_string_tag, %{
                 writable: false,
                 enumerable: false,
                 configurable: true
               })

             _ ->
               :ok
           end

           ctor
         end).(),
      "DataView" => register("DataView", fn _, _ -> Runtime.new_object() end),
      "ArrayBuffer" =>
        (
          ab_ctor = register("ArrayBuffer", &ArrayBuffer.constructor/2, auto_proto: true)

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
                     case proxy do
                       {:obj, proxy_ref} -> Heap.put_obj_key(proxy_ref, "__proxy_revoked__", true)
                       _ -> :ok
                     end

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
      "decodeURI" => builtin("decodeURI", &Functions.decode_uri/2),
      "decodeURIComponent" => builtin("decodeURIComponent", &Functions.decode_uri_component/2),
      "encodeURI" => builtin("encodeURI", &Functions.encode_uri/2),
      "encodeURIComponent" => builtin("encodeURIComponent", &Functions.encode_uri_component/2),
      "require" => builtin("require", &Functions.js_require/2),
      "structuredClone" =>
        builtin("structuredClone", fn
          [val | _], _ -> QuickBEAM.VM.Runtime.StructuredClone.clone(val)
          [], _ -> nil
        end),
      "queueMicrotask" => builtin("queueMicrotask", &Functions.queue_microtask/2),
      "gc" => builtin("gc", fn _, _ -> :undefined end),
      "os" => Heap.wrap(%{"platform" => "elixir"}),
      "qjs" =>
        object do
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
    |> Map.merge(QuickBEAM.VM.Builtin.Discovery.bindings())
  end

  # ── Registration helpers ──

  defp builtin(name, fun), do: {:builtin, name, fun}

  defp register(name, constructor, opts \\ []) do
    ConstructorRegistry.register(name, constructor, opts)
  end

  defp ensure_object_prototype do
    case Heap.get_object_prototype() do
      nil -> Object.build_prototype()
      existing -> existing
    end
  end

  defp install_date_prototype_methods(ctor) do
    install_prototype_methods(ctor, JSDate, JSDate.proto_property_names())

    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, proto_ref} ->
        sym_key = {:symbol, "Symbol.toPrimitive"}

        to_prim =
          {:builtin, "[Symbol.toPrimitive]",
           fn args, this ->
             JSDate.symbol_to_primitive(this, args)
           end}

        Heap.put_obj_key(proto_ref, sym_key, to_prim)

        Heap.put_prop_desc(proto_ref, sym_key, %{
          writable: false,
          enumerable: false,
          configurable: true
        })

      _ ->
        :ok
    end
  end

  defp install_prototype_methods(ctor, module, names) do
    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, proto_ref} ->
        for name <- names do
          Heap.put_obj_key(proto_ref, name, module.proto_property(name))

          Heap.put_prop_desc(proto_ref, name, %{
            writable: true,
            enumerable: false,
            configurable: true
          })
        end

      _ ->
        :ok
    end
  end

  defp install_regexp_prototype_accessors(ctor) do
    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, proto_ref} ->
        for name <- ~w(source global ignoreCase multiline) do
          Heap.put_obj_key(proto_ref, name, RegExp.proto_accessor(name))
          Heap.put_prop_desc(proto_ref, name, %{enumerable: false, configurable: true})
        end

      _ ->
        :ok
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
      ctor = register(name, TypedArray.constructor(type), auto_proto: true)
      Heap.put_ctor_static(ctor, "__proto__", ta_base)
      Heap.put_ctor_static(ctor, "BYTES_PER_ELEMENT", TypedArray.elem_size(type))
      {name, ctor}
    end
  end
end
