defmodule QuickBEAM.BeamVM.Runtime do
  @moduledoc """
  JS built-in runtime: property resolution, shared helpers, global bindings.

  Domain-specific builtins live in sub-modules:
  - `Runtime.Array` — Array.prototype + Array static
  - `Runtime.StringProto` — String.prototype
  - `Runtime.JSON` — parse/stringify
  - `Runtime.Object` — Object static methods
  - `Runtime.RegExp` — RegExp prototype + exec
  - `Runtime.Builtins` — Math, Number, Boolean, Console, constructors, global functions
  """

  alias QuickBEAM.BeamVM.Heap
  import Bitwise, only: [band: 2]

  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Runtime.{Array, StringProto, JSON, Object, RegExp, Builtins, TypedArray}
  alias QuickBEAM.BeamVM.Runtime.Date, as: JSDate

  # ── Global bindings ──

  defp register_symbol_statics(symbol_builtin) do
    for {k, v} <- Builtins.symbol_statics() do
      Heap.put_ctor_static(symbol_builtin, k, v)
    end

    symbol_builtin
  end

  defp register_date_statics(date_builtin) do
    Heap.put_ctor_static(date_builtin, "now", JSDate.static_now())

    Heap.put_ctor_static(
      date_builtin,
      "UTC",
      {:builtin, "UTC",
       fn args ->
         [y | rest] = args ++ List.duplicate(0, 7)
         m = Enum.at(rest, 0, 0)
         d = Enum.at(rest, 1, 1)
         h = Enum.at(rest, 2, 0)
         mi = Enum.at(rest, 3, 0)
         s = Enum.at(rest, 4, 0)
         ms = Enum.at(rest, 5, 0)
         year = if is_number(y) and y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y || 0)

         case NaiveDateTime.new(
                year,
                trunc(m) + 1,
                max(1, trunc(d)),
                trunc(h),
                trunc(mi),
                trunc(s)
              ) do
           {:ok, dt} ->
             DateTime.from_naive!(dt, "Etc/UTC")
             |> DateTime.to_unix(:millisecond)
             |> Kernel.+(trunc(ms))

           _ ->
             :nan
         end
       end}
    )

    date_builtin
  end

  defp register_promise_statics(promise_builtin) do
    for {k, v} <- Builtins.promise_statics() do
      Heap.put_ctor_static(promise_builtin, k, v)
    end

    promise_builtin
  end

  defp register_error_builtin(name) do
    builtin = {:builtin, name, Builtins.error_constructor()}
    proto_ref = make_ref()
    Heap.put_obj(proto_ref, %{"name" => name, "message" => "", "constructor" => builtin})
    proto = {:obj, proto_ref}
    Heap.put_class_proto(builtin, proto)
    Heap.put_ctor_static(builtin, "prototype", proto)
    builtin
  end

  def global_bindings do
    obj_proto_ref = Process.get(:qb_object_prototype)

    obj_proto_ref =
      if obj_proto_ref do
        obj_proto_ref
      else
        ref = make_ref()
        obj_ctor = {:builtin, "Object", Builtins.object_constructor()}

        Heap.put_obj(ref, %{
          "toString" => {:builtin, "toString", fn _, _ -> "[object Object]" end},
          "valueOf" => {:builtin, "valueOf", fn _, this -> this end},
          "hasOwnProperty" =>
            {:builtin, "hasOwnProperty",
             fn [key | _], this ->
               case this do
                 {:obj, r} ->
                   data = Heap.get_obj(r, %{})
                   is_map(data) and Map.has_key?(data, key)

                 _ ->
                   false
               end
             end},
          "isPrototypeOf" => {:builtin, "isPrototypeOf", fn _, _ -> false end},
          "propertyIsEnumerable" =>
            {:builtin, "propertyIsEnumerable",
             fn [key | _], this ->
               case this do
                 {:obj, r} ->
                   desc = Heap.get_prop_desc(r, key)
                   not match?(%{enumerable: false}, desc)

                 _ ->
                   false
               end
             end},
          "constructor" => obj_ctor
        })

        Process.put(:qb_object_prototype, {:obj, ref})
        {:obj, ref}
      end

    obj_builtin = {:builtin, "Object", Builtins.object_constructor()}
    Heap.put_ctor_static(obj_builtin, "prototype", obj_proto_ref)

    %{
      "Object" => obj_builtin,
      "Array" => {:builtin, "Array", Builtins.array_constructor()},
      "String" => {:builtin, "String", Builtins.string_constructor()},
      "Number" => {:builtin, "Number", Builtins.number_constructor()},
      "BigInt" => {:builtin, "BigInt", Builtins.bigint_constructor()},
      "gc" => {:builtin, "gc", fn _ -> :undefined end},
      "Boolean" => {:builtin, "Boolean", Builtins.boolean_constructor()},
      "Function" => {:builtin, "Function", Builtins.function_constructor()},
      "Error" => register_error_builtin("Error"),
      "TypeError" => register_error_builtin("TypeError"),
      "RangeError" => register_error_builtin("RangeError"),
      "SyntaxError" => register_error_builtin("SyntaxError"),
      "ReferenceError" => register_error_builtin("ReferenceError"),
      "URIError" => register_error_builtin("URIError"),
      "EvalError" => register_error_builtin("EvalError"),
      "Math" => Builtins.math_object(),
      "JSON" => JSON.object(),
      "Date" => register_date_statics({:builtin, "Date", &JSDate.constructor/1}),
      "Promise" =>
        register_promise_statics({:builtin, "Promise", Builtins.promise_constructor()}),
      "RegExp" => {:builtin, "RegExp", Builtins.regexp_constructor()},
      "Symbol" => register_symbol_statics({:builtin, "Symbol", Builtins.symbol_constructor()}),
      "parseInt" => {:builtin, "parseInt", fn args -> Builtins.parse_int(args) end},
      "parseFloat" => {:builtin, "parseFloat", fn args -> Builtins.parse_float(args) end},
      "isNaN" => {:builtin, "isNaN", fn args -> Builtins.is_nan(args) end},
      "isFinite" => {:builtin, "isFinite", fn args -> Builtins.is_finite(args) end},
      "NaN" => :nan,
      "Infinity" => :infinity,
      "undefined" => :undefined,
      "Map" => {:builtin, "Map", Builtins.map_constructor()},
      "Set" => {:builtin, "Set", Builtins.set_constructor()},
      "WeakMap" => {:builtin, "WeakMap", Builtins.map_constructor()},
      "WeakSet" => {:builtin, "WeakSet", Builtins.set_constructor()},
      "WeakRef" => {:builtin, "WeakRef", fn _ -> __MODULE__.obj_new() end},
      "Reflect" =>
        {:builtin, "Reflect",
         %{
           "get" => {:builtin, "get", fn [obj, key | _] -> get_property(obj, key) end},
           "set" =>
             {:builtin, "set",
              fn [obj, key, val | _] ->
                QuickBEAM.BeamVM.Interpreter.Objects.put(obj, key, val)
                true
              end},
           "has" =>
             {:builtin, "has",
              fn [obj, key | _] -> QuickBEAM.BeamVM.Interpreter.Objects.has_property(obj, key) end},
           "ownKeys" =>
             {:builtin, "ownKeys",
              fn [obj | _] ->
                case obj do
                  {:obj, ref} ->
                    keys = Map.keys(Heap.get_obj(ref, %{}))
                    r = make_ref()
                    Heap.put_obj(r, keys)
                    {:obj, r}

                  _ ->
                    {:obj,
                     (
                       r = make_ref()
                       Heap.put_obj(r, [])
                       r
                     )}
                end
              end}
         }},
      # TODO: Proxy only intercepts get/set/has traps. Missing: deleteProperty,
      # ownKeys, getPrototypeOf, apply, construct. Prototype chain lookup
      # (get_prototype_property) does not check for proxy handlers.
      "Proxy" =>
        {:builtin, "Proxy",
         fn
           [target, handler | _] ->
             ref = make_ref()
             Heap.put_obj(ref, %{"__proxy_target__" => target, "__proxy_handler__" => handler})
             {:obj, ref}

           _ ->
             __MODULE__.obj_new()
         end},
      "console" => Builtins.console_object(),
      "require" =>
        {:builtin, "require",
         fn [name | _] ->
           case Heap.get_module(name) do
             nil ->
               ref = make_ref()

               Heap.put_obj(ref, %{
                 "message" => "Cannot find module '#{name}'",
                 "name" => "Error",
                 "stack" => ""
               })

               throw({:js_throw, {:obj, ref}})

             exports ->
               exports
           end
         end},
      "eval" =>
        {:builtin, "eval",
         fn [code | _] ->
           ctx = QuickBEAM.BeamVM.Heap.get_ctx()

           if (is_binary(code) and ctx) && ctx.runtime_pid do
             case QuickBEAM.Runtime.compile(ctx.runtime_pid, code) do
               {:ok, bc} ->
                 case QuickBEAM.BeamVM.Bytecode.decode(bc) do
                   {:ok, parsed} ->
                     case QuickBEAM.BeamVM.Interpreter.eval(
                            parsed.value,
                            [],
                            %{gas: 1_000_000_000, runtime_pid: ctx.runtime_pid},
                            parsed.atoms
                          ) do
                       {:ok, val} -> val
                       _ -> :undefined
                     end

                   _ ->
                     :undefined
                 end

               _ ->
                 :undefined
             end
           else
             :undefined
           end
         end},
      "globalThis" => obj_new(),
      "structuredClone" => {:builtin, "structuredClone", fn [val | _] -> val end},
      "queueMicrotask" =>
        {:builtin, "queueMicrotask",
         fn [cb | _] ->
           Heap.enqueue_microtask({:resolve, nil, cb, :undefined})
           :undefined
         end},
      "ArrayBuffer" => {:builtin, "ArrayBuffer", &TypedArray.array_buffer_constructor/1},
      "Uint8Array" => {:builtin, "Uint8Array", TypedArray.typed_array_constructor(:uint8)},
      "Int8Array" => {:builtin, "Int8Array", TypedArray.typed_array_constructor(:int8)},
      "Uint8ClampedArray" =>
        {:builtin, "Uint8ClampedArray", TypedArray.typed_array_constructor(:uint8_clamped)},
      "Uint16Array" => {:builtin, "Uint16Array", TypedArray.typed_array_constructor(:uint16)},
      "Int16Array" => {:builtin, "Int16Array", TypedArray.typed_array_constructor(:int16)},
      "Uint32Array" => {:builtin, "Uint32Array", TypedArray.typed_array_constructor(:uint32)},
      "Int32Array" => {:builtin, "Int32Array", TypedArray.typed_array_constructor(:int32)},
      "Float32Array" => {:builtin, "Float32Array", TypedArray.typed_array_constructor(:float32)},
      "Float64Array" => {:builtin, "Float64Array", TypedArray.typed_array_constructor(:float64)},
      "DataView" => {:builtin, "DataView", fn _ -> obj_new() end}
    }
  end

  # ── Property resolution (prototype chain) ──

  def get_property(value, key) when is_binary(key) do
    case get_own_property(value, key) do
      :undefined ->
        result = get_prototype_raw(value, key)

        case result do
          {:accessor, getter, _} when getter != nil -> invoke_getter(getter, value)
          _ -> result
        end

      val ->
        val
    end
  end

  defp get_prototype_raw({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      map when is_map(map) and is_map_key(map, "__proto__") ->
        proto = Map.get(map, "__proto__")

        case proto do
          {:obj, pref} ->
            pmap = Heap.get_obj(pref, %{})

            if is_map(pmap) do
              case Map.get(pmap, key, :undefined) do
                :undefined -> get_prototype_raw(proto, key)
                val -> val
              end
            else
              get_prototype_property(proto, key)
            end

          _ ->
            get_prototype_property(proto, key)
        end

      data ->
        get_prototype_property({:obj, ref}, key)
    end
  end

  defp get_prototype_raw(value, key), do: get_prototype_property(value, key)

  def get_property(value, key) when is_integer(key),
    do: get_property(value, Integer.to_string(key))

  def get_property(_, _), do: :undefined

  def js_string_length(s) do
    len = String.length(s)

    if len == byte_size(s) do
      # ASCII-only fast path
      len
    else
      s
      |> String.to_charlist()
      |> Enum.reduce(0, fn cp, acc ->
        if cp > 0xFFFF, do: acc + 2, else: acc + 1
      end)
    end
  end

  defp get_own_property({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      nil ->
        :undefined

      %{"__proxy_target__" => target, "__proxy_handler__" => handler} ->
        get_trap = get_own_property(handler, "get")

        if get_trap != :undefined do
          call_builtin_callback(get_trap, [target, key], :no_interp)
        else
          get_own_property(target, key)
        end

      list when is_list(list) ->
        get_own_property(list, key)

      %{"__date_ms__" => _} = map ->
        case Map.get(map, key) do
          nil -> JSDate.proto_property(key)
          val -> val
        end

      map when is_map(map) ->
        case Map.get(map, key) do
          {:accessor, getter, _setter} when getter != nil -> invoke_getter(getter, {:obj, ref})
          nil -> :undefined
          val -> val
        end
    end
  end

  defp get_own_property(list, "length") when is_list(list), do: length(list)

  defp get_own_property(list, key) when is_list(list) and is_integer(key) do
    if key >= 0 and key < length(list), do: Enum.at(list, key), else: :undefined
  end

  defp get_own_property(list, key) when is_list(list) and is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> Enum.at(list, idx, :undefined)
      _ -> :undefined
    end
  end

  defp get_own_property(s, "length") when is_binary(s), do: js_string_length(s)
  defp get_own_property(s, key) when is_binary(s), do: StringProto.proto_property(key)

  defp get_own_property(n, _) when is_number(n), do: :undefined
  defp get_own_property(true, _), do: :undefined
  defp get_own_property(false, _), do: :undefined
  defp get_own_property(nil, _), do: :undefined
  defp get_own_property(:undefined, _), do: :undefined

  defp get_own_property({:builtin, _name, map}, key) when is_map(map) do
    Map.get(map, key, :undefined)
  end

  defp get_own_property({:builtin, _, _} = b, key) do
    Map.get(Heap.get_ctor_statics(b), key, :undefined)
  end

  defp get_own_property({:regexp, bytecode, _source}, "flags"), do: extract_regexp_flags(bytecode)
  defp get_own_property({:regexp, _bytecode, source}, "source") when is_binary(source), do: source

  defp get_own_property({:regexp, _, _}, key), do: RegExp.proto_property(key)

  defp get_own_property(%Bytecode.Function{} = f, "prototype") do
    get_or_create_prototype(f)
  end

  defp get_own_property(%Bytecode.Function{} = f, key) do
    Map.get(Heap.get_ctor_statics(f), key, :undefined)
  end

  defp get_own_property({:closure, _, %Bytecode.Function{}} = c, "prototype") do
    get_or_create_prototype(c)
  end

  defp get_own_property({:closure, _, %Bytecode.Function{} = f} = c, key) do
    case Map.get(Heap.get_ctor_statics(c), key, :undefined) do
      :undefined -> Map.get(Heap.get_ctor_statics(f), key, :undefined)
      val -> val
    end
  end

  defp get_own_property({:symbol, desc}, "toString"),
    do: {:builtin, "toString", fn _, _ -> "Symbol(#{desc})" end}

  defp get_own_property({:symbol, desc, _}, "toString"),
    do: {:builtin, "toString", fn _, _ -> "Symbol(#{desc})" end}

  defp get_own_property({:symbol, desc}, "description"), do: desc
  defp get_own_property({:symbol, desc, _}, "description"), do: desc
  defp get_own_property(_, _), do: :undefined

  defp get_or_create_prototype(ctor) do
    # Check class proto first (set during class definition)
    class_proto = Heap.get_class_proto(ctor)

    if class_proto do
      class_proto
    else
      key = {:qb_func_proto, :erlang.phash2(ctor)}

      case Process.get(key) do
        nil ->
          proto_ref = make_ref()
          Heap.put_obj(proto_ref, %{"constructor" => ctor})
          proto = {:obj, proto_ref}
          Process.put(key, proto)
          proto

        existing ->
          existing
      end
    end
  end

  def extract_regexp_flags(<<flags_byte::8, _::binary>>) do
    [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}]
    |> Enum.reduce("", fn {bit, ch}, acc ->
      if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
    end)
  end

  def extract_regexp_flags(_), do: ""

  defp invoke_getter(fun, this_obj) do
    QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(fun, [], 10_000_000, this_obj)
  end

  defp get_prototype_property({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      list when is_list(list) ->
        Array.proto_property(key)

      map when is_map(map) ->
        cond do
          Map.has_key?(map, "__map_data__") ->
            map_proto(key)

          Map.has_key?(map, "__set_data__") ->
            set_proto(key)

          Map.has_key?(map, "__proto__") ->
            # Walk prototype chain
            get_property(Map.get(map, "__proto__"), key)

          true ->
            :undefined
        end

      _ ->
        :undefined
    end
  end

  defp get_prototype_property(list, "constructor") when is_list(list) do
    Map.get(global_bindings(), "Array", :undefined)
  end

  defp get_prototype_property(list, key) when is_list(list), do: Array.proto_property(key)
  defp get_prototype_property(s, key) when is_binary(s), do: StringProto.proto_property(key)
  defp get_prototype_property(n, key) when is_number(n), do: Builtins.number_proto_property(key)
  defp get_prototype_property(true, key), do: Builtins.boolean_proto_property(key)
  defp get_prototype_property(false, key), do: Builtins.boolean_proto_property(key)
  defp get_prototype_property(%Bytecode.Function{} = f, key), do: function_proto_property(f, key)

  defp get_prototype_property({:closure, _, %Bytecode.Function{}} = c, key),
    do: function_proto_property(c, key)

  defp get_prototype_property({:builtin, "Error", _}, key),
    do: Builtins.error_static_property(key)

  defp get_prototype_property({:builtin, "Array", _}, key), do: Array.static_property(key)
  defp get_prototype_property({:builtin, "Object", _}, key), do: Object.static_property(key)
  defp get_prototype_property({:builtin, "Map", _}, _key), do: :undefined
  defp get_prototype_property({:builtin, "Set", _}, _key), do: :undefined

  defp get_prototype_property({:builtin, "Number", _}, key),
    do: Builtins.number_static_property(key)

  defp get_prototype_property({:builtin, "String", _}, key),
    do: Builtins.string_static_property(key)

  defp get_prototype_property({:builtin, name, _} = fun, key) when is_binary(name),
    do: function_proto_property(fun, key)

  defp get_prototype_property(_, _), do: :undefined

  defp invoke_fun(fun, args, this_arg) do
    case fun do
      {:builtin, _, cb} when is_function(cb, 2) -> cb.(args, this_arg)
      {:builtin, _, cb} when is_function(cb, 3) -> cb.(args, this_arg, :no_interp)
      {:builtin, _, cb} when is_function(cb, 1) -> cb.(args)
      _ -> QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(fun, args, 10_000_000, this_arg)
    end
  end

  defp function_proto_property(fun, "call") do
    {:builtin, "call",
     fn [this_arg | args], _this ->
       invoke_fun(fun, args, this_arg)
     end}
  end

  defp function_proto_property(fun, "apply") do
    {:builtin, "apply",
     fn [this_arg | rest], _this ->
       args_array = List.first(rest)

       args =
         case args_array do
           {:obj, ref} ->
             case Heap.get_obj(ref, []) do
               list when is_list(list) -> list
               _ -> []
             end

           list when is_list(list) ->
             list

           _ ->
             []
         end

       invoke_fun(fun, args, this_arg)
     end}
  end

  defp function_proto_property(fun, "bind") do
    {:builtin, "bind",
     fn [this_arg | bound_args], _this ->
       {:builtin, "bound",
        fn args, _this2 ->
          invoke_fun(fun, bound_args ++ args, this_arg)
        end}
     end}
  end

  defp function_proto_property(%Bytecode.Function{} = f, "name"), do: f.name || ""
  defp function_proto_property(%Bytecode.Function{} = f, "length"), do: f.defined_arg_count

  defp function_proto_property({:closure, _, %Bytecode.Function{} = f}, "name"),
    do: f.name || ""

  defp function_proto_property({:closure, _, %Bytecode.Function{} = f}, "length"),
    do: f.defined_arg_count

  defp function_proto_property(_fun, "length"), do: 0
  defp function_proto_property(_fun, "name"), do: ""
  defp function_proto_property(_fun, _), do: :undefined

  defp map_proto("get"),
    do:
      {:builtin, "get",
       fn [key | _], {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__map_data__", %{})
         Map.get(data, key, :undefined)
       end}

  defp map_proto("set"),
    do:
      {:builtin, "set",
       fn [key, val | _], {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, "__map_data__", %{})
         new_data = Map.put(data, key, val)
         Heap.put_obj(ref, %{obj | "__map_data__" => new_data, "size" => map_size(new_data)})
         {:obj, ref}
       end}

  defp map_proto("has"),
    do:
      {:builtin, "has",
       fn [key | _], {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__map_data__", %{})
         Map.has_key?(data, key)
       end}

  defp map_proto("delete"),
    do:
      {:builtin, "delete",
       fn [key | _], {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, "__map_data__", %{})
         new_data = Map.delete(data, key)
         Heap.put_obj(ref, %{obj | "__map_data__" => new_data, "size" => map_size(new_data)})
         true
       end}

  defp map_proto("clear"),
    do:
      {:builtin, "clear",
       fn _, {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         Heap.put_obj(ref, %{obj | "__map_data__" => %{}, "size" => 0})
         :undefined
       end}

  defp map_proto("keys"),
    do:
      {:builtin, "keys",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__map_data__", %{})
         keys = Map.keys(data)
         r = make_ref()
         Heap.put_obj(r, keys)
         {:obj, r}
       end}

  defp map_proto("values"),
    do:
      {:builtin, "values",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__map_data__", %{})
         vals = Map.values(data)
         r = make_ref()
         Heap.put_obj(r, vals)
         {:obj, r}
       end}

  defp map_proto("entries"),
    do:
      {:builtin, "entries",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__map_data__", %{})

         entries =
           Enum.map(data, fn {k, v} ->
             r = make_ref()
             Heap.put_obj(r, [k, v])
             {:obj, r}
           end)

         r = make_ref()
         Heap.put_obj(r, entries)
         {:obj, r}
       end}

  defp map_proto("forEach"),
    do:
      {:builtin, "forEach",
       fn [cb | _], {:obj, ref}, interp ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__map_data__", %{})
         Enum.each(data, fn {k, v} -> call_builtin_callback(cb, [v, k, {:obj, ref}], interp) end)
         :undefined
       end}

  defp map_proto(_), do: :undefined

  defp set_proto("has"),
    do:
      {:builtin, "has",
       fn [val | _], {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__set_data__", [])
         val in data
       end}

  defp set_proto("add"),
    do:
      {:builtin, "add",
       fn [val | _], {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, "__set_data__", [])

         unless val in data do
           new_data = data ++ [val]
           Heap.put_obj(ref, %{obj | "__set_data__" => new_data, "size" => length(new_data)})
         end

         {:obj, ref}
       end}

  defp set_proto("delete"),
    do:
      {:builtin, "delete",
       fn [val | _], {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         data = Map.get(obj, "__set_data__", [])
         new_data = List.delete(data, val)
         Heap.put_obj(ref, %{obj | "__set_data__" => new_data, "size" => length(new_data)})
         true
       end}

  defp set_proto("clear"),
    do:
      {:builtin, "clear",
       fn _, {:obj, ref} ->
         obj = Heap.get_obj(ref, %{})
         Heap.put_obj(ref, %{obj | "__set_data__" => [], "size" => 0})
         :undefined
       end}

  defp set_proto("values"),
    do:
      {:builtin, "values",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__set_data__", [])
         r = make_ref()
         Heap.put_obj(r, data)
         {:obj, r}
       end}

  defp set_proto("keys"), do: set_proto("values")

  defp set_proto("entries"),
    do:
      {:builtin, "entries",
       fn _, {:obj, ref} ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__set_data__", [])

         entries =
           Enum.map(data, fn v ->
             r = make_ref()
             Heap.put_obj(r, [v, v])
             {:obj, r}
           end)

         r = make_ref()
         Heap.put_obj(r, entries)
         {:obj, r}
       end}

  defp set_proto("forEach"),
    do:
      {:builtin, "forEach",
       fn [cb | _], {:obj, ref}, interp ->
         data = Heap.get_obj(ref, %{}) |> Map.get("__set_data__", [])
         Enum.each(data, fn v -> call_builtin_callback(cb, [v, v, {:obj, ref}], interp) end)
         :undefined
       end}

  defp set_proto(_), do: :undefined

  # ── Callback dispatch (used by higher-order array methods) ──

  def call_builtin_callback(fun, args, interp) do
    case fun do
      {:builtin, _, cb} when is_function(cb, 1) ->
        cb.(args)

      {:builtin, _, cb} when is_function(cb, 2) ->
        cb.(args, nil)

      {:builtin, _, cb} when is_function(cb, 3) ->
        cb.(args, nil, interp)

      %QuickBEAM.BeamVM.Bytecode.Function{} = f ->
        QuickBEAM.BeamVM.Interpreter.invoke(f, args, 10_000_000)

      {:closure, _, %QuickBEAM.BeamVM.Bytecode.Function{}} = c ->
        QuickBEAM.BeamVM.Interpreter.invoke(c, args, 10_000_000)

      f when is_function(f) ->
        apply(f, args)

      _ ->
        :undefined
    end
  end

  # ── Shared helpers (public for cross-module use) ──

  def obj_new do
    ref = make_ref()
    Heap.put_obj(ref, %{})
    {:obj, ref}
  end

  def js_truthy(nil), do: false
  def js_truthy(:undefined), do: false
  def js_truthy(false), do: false
  def js_truthy(0), do: false
  def js_truthy(""), do: false
  def js_truthy(_), do: true

  def js_strict_eq(a, b), do: a === b

  def js_to_string({:bigint, n}), do: Integer.to_string(n)
  def js_to_string(:undefined), do: "undefined"
  def js_to_string(nil), do: "null"
  def js_to_string(true), do: "true"
  def js_to_string(false), do: "false"
  def js_to_string(n) when is_integer(n), do: Integer.to_string(n)

  def js_to_string(n) when is_float(n) and n == 0.0, do: "0"

  def js_to_string(n) when is_float(n) do
    QuickBEAM.BeamVM.Interpreter.Values.to_js_string(n)
  end

  def js_to_string(s) when is_binary(s), do: s

  def js_to_string({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      list when is_list(list) -> Enum.map_join(list, ",", &js_to_string/1)
      _ -> "[object Object]"
    end
  end

  def js_to_string(list) when is_list(list), do: Enum.map(list, &js_to_string/1) |> Enum.join(",")
  def js_to_string({:symbol, desc}), do: "Symbol(#{desc})"
  def js_to_string({:symbol, desc, _}), do: "Symbol(#{desc})"
  def js_to_string(_), do: ""

  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: trunc(n)
  def to_int(_), do: 0

  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0
  def to_float(_), do: 0.0

  def to_number(n) when is_number(n), do: n
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(nil), do: 0
  def to_number(:undefined), do: :nan

  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      {f, _} -> f
      :error -> :nan
    end
  end

  def to_number(_), do: :nan

  def normalize_index(idx, len) when idx < 0, do: max(len + idx, 0)
  def normalize_index(idx, len), do: min(idx, len)
end
