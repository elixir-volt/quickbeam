defmodule QuickBEAM.BeamVM.Runtime do
  import QuickBEAM.BeamVM.Heap.Keys

  @moduledoc """
  JS built-in runtime: property resolution, shared helpers, global bindings.

  Domain-specific builtins live in sub-modules:
  - `Runtime.Array` — Array.prototype + Array static
  - `Runtime.String` — String.prototype
  - `Runtime.JSON` — parse/stringify
  - `Runtime.Object` — Object static methods
  - `Runtime.RegExp` — RegExp prototype + exec
  - `Runtime.Builtins` — Math, Number, Boolean, Console, constructors, global functions
  """

  alias QuickBEAM.BeamVM.Heap
  import Bitwise, only: [band: 2]

  alias QuickBEAM.BeamVM.Bytecode

  alias QuickBEAM.BeamVM.Runtime.String, as: JSString

  alias QuickBEAM.BeamVM.Runtime.{
    Array,
    Console,
    Globals,
    Math,
    MapSet,
    Number,
    Prototypes,
    JSON,
    Object,
    Reflect,
    RegExp,
    Boolean,
    Builtins,
    Promise,
    Symbol,
    TypedArray
  }

  alias QuickBEAM.BeamVM.Runtime.Date, as: JSDate
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.{Builtin, Interpreter}

  # ── Global bindings ──

  defp register_builtin(name, constructor, opts) do
    builtin = {:builtin, name, constructor}

    # Register module for static_property dispatch
    case Keyword.get(opts, :module) do
      nil -> :ok
      mod -> Heap.put_ctor_static(builtin, :__module__, mod)
    end

    # Legacy: direct statics stored in PD (being phased out)
    for {k, v} <- Keyword.get(opts, :statics, []) do
      Heap.put_ctor_static(builtin, k, v)
    end

    case Keyword.get(opts, :prototype) do
      nil ->
        :ok

      proto_map ->
        proto_ref = make_ref()
        Heap.put_obj(proto_ref, Map.put(proto_map, "constructor", builtin))
        Heap.put_class_proto(builtin, {:obj, proto_ref})
        Heap.put_ctor_static(builtin, "prototype", {:obj, proto_ref})
    end

    builtin
  end

  @error_types ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError)

  defp error_builtins do
    for name <- @error_types, into: %{} do
      {name,
       register_builtin(name, Builtins.error_constructor(),
         prototype: %{"name" => name, "message" => ""}
       )}
    end
  end

  def global_bindings do
    case Heap.get_global_cache() do
      nil -> build_global_bindings()
      cached -> cached
    end
  end

  defp build_global_bindings do
    obj_proto_ref = Heap.get_object_prototype()

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

        Heap.put_object_prototype({:obj, ref})
        {:obj, ref}
      end

    obj_builtin = {:builtin, "Object", Builtins.object_constructor()}
    Heap.put_ctor_static(obj_builtin, "prototype", obj_proto_ref)

    bindings =
      %{
        "Object" => obj_builtin,
        "Array" => {:builtin, "Array", Builtins.array_constructor()},
        "String" => {:builtin, "String", Builtins.string_constructor()},
        "Number" => {:builtin, "Number", Builtins.number_constructor()},
        "BigInt" => {:builtin, "BigInt", Builtins.bigint_constructor()},
        "gc" => {:builtin, "gc", fn _, _this -> :undefined end},
        "Boolean" => {:builtin, "Boolean", Boolean.constructor()},
        "Function" => {:builtin, "Function", Builtins.function_constructor()},
        "Math" => Math.object(),
        "JSON" => JSON.object(),
        "Date" => register_builtin("Date", &JSDate.constructor/2, module: JSDate),
        "Promise" => register_builtin("Promise", Promise.constructor(), module: Promise),
        "RegExp" => {:builtin, "RegExp", Builtins.regexp_constructor()},
        "Symbol" => register_builtin("Symbol", Symbol.constructor(), module: Symbol),
        "parseInt" => {:builtin, "parseInt", fn args, _this -> Globals.parse_int(args) end},
        "parseFloat" => {:builtin, "parseFloat", fn args, _this -> Globals.parse_float(args) end},
        "isNaN" => {:builtin, "isNaN", fn args, _this -> Globals.is_nan(args) end},
        "isFinite" => {:builtin, "isFinite", fn args, _this -> Globals.is_finite(args) end},
        "NaN" => :nan,
        "Infinity" => :infinity,
        "undefined" => :undefined,
        "Map" => {:builtin, "Map", MapSet.map_constructor()},
        "Set" => {:builtin, "Set", MapSet.set_constructor()},
        "WeakMap" => {:builtin, "WeakMap", MapSet.map_constructor()},
        "WeakSet" => {:builtin, "WeakSet", MapSet.set_constructor()},
        "WeakRef" => {:builtin, "WeakRef", fn _, _this -> new_object() end},
        "Reflect" => Reflect.object(),
        "Proxy" =>
          {:builtin, "Proxy",
           fn
             [target, handler | _], _this ->
               Heap.wrap(%{proxy_target() => target, proxy_handler() => handler})

             _, _this ->
               new_object()
           end},
        "console" => Console.object(),
        "require" =>
          {:builtin, "require",
           fn [name | _], _this ->
             case Heap.get_module(name) do
               nil ->
                 throw({:js_throw, Heap.make_error("Cannot find module '\#{name}'", "Error")})

               exports ->
                 exports
             end
           end},
        "eval" =>
          {:builtin, "eval",
           fn [code | _], _this ->
             ctx = Heap.get_ctx()

             if (is_binary(code) and ctx) && ctx.runtime_pid do
               case QuickBEAM.Runtime.compile(ctx.runtime_pid, code) do
                 {:ok, bc} ->
                   case Bytecode.decode(bc) do
                     {:ok, parsed} ->
                       case Interpreter.eval(
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
        "globalThis" => new_object(),
        "structuredClone" => {:builtin, "structuredClone", fn [val | _], _this -> val end},
        "queueMicrotask" =>
          {:builtin, "queueMicrotask",
           fn [cb | _], _this ->
             Heap.enqueue_microtask({:resolve, nil, cb, :undefined})
             :undefined
           end},
        "ArrayBuffer" => {:builtin, "ArrayBuffer", &TypedArray.array_buffer_constructor/1}
      }
      |> Map.merge(
        for {name, type} <- [
              {"Uint8Array", :uint8},
              {"Int8Array", :int8},
              {"Uint8ClampedArray", :uint8_clamped},
              {"Uint16Array", :uint16},
              {"Int16Array", :int16},
              {"Uint32Array", :uint32},
              {"Int32Array", :int32},
              {"Float32Array", :float32},
              {"Float64Array", :float64}
            ],
            into: %{} do
          {name, {:builtin, name, TypedArray.typed_array_constructor(type)}}
        end
      )
      |> Map.merge(%{
        "DataView" => {:builtin, "DataView", fn _, _this -> new_object() end}
      })
      |> Map.merge(error_builtins())

    Heap.put_global_cache(bindings)
    bindings
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

  def get_property(value, key) when is_integer(key),
    do: get_property(value, Integer.to_string(key))

  def get_property(_, _), do: :undefined

  defp get_prototype_raw({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      map when is_map(map) and is_map_key(map, proto()) ->
        proto = Map.get(map, proto())

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

      _ ->
        get_prototype_property({:obj, ref}, key)
    end
  end

  defp get_prototype_raw(value, key), do: get_prototype_property(value, key)

  def string_length(s) do
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

      %{
        proxy_target() => target,
        proxy_handler() => handler
      } ->
        get_trap = get_own_property(handler, "get")

        if get_trap != :undefined do
          call_callback(get_trap, [target, key])
        else
          get_own_property(target, key)
        end

      list when is_list(list) ->
        get_own_property(list, key)

      %{date_ms() => _} = map ->
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

  defp get_own_property(s, "length") when is_binary(s), do: string_length(s)
  defp get_own_property(s, key) when is_binary(s), do: JSString.proto_property(key)

  defp get_own_property(n, _) when is_number(n), do: :undefined
  defp get_own_property(true, _), do: :undefined
  defp get_own_property(false, _), do: :undefined
  defp get_own_property(nil, _), do: :undefined
  defp get_own_property(:undefined, _), do: :undefined

  defp get_own_property({:builtin, _name, map}, key) when is_map(map) do
    Map.get(map, key, :undefined)
  end

  defp get_own_property({:builtin, name, _}, "from")
       when name in ~w(Uint8Array Int8Array Uint8ClampedArray Uint16Array Int16Array Uint32Array Int32Array Float32Array Float64Array) do
    type_map = %{
      "Uint8Array" => :uint8,
      "Int8Array" => :int8,
      "Uint8ClampedArray" => :uint8_clamped,
      "Uint16Array" => :uint16,
      "Int16Array" => :int16,
      "Uint32Array" => :uint32,
      "Int32Array" => :int32,
      "Float32Array" => :float32,
      "Float64Array" => :float64
    }

    type = Map.get(type_map, name, :uint8)

    {:builtin, "from",
     fn [source | _], _this ->
       list = Heap.to_list(source)
       TypedArray.typed_array_constructor(type).(list)
     end}
  end

  defp get_own_property({:builtin, _, _} = b, key) do
    statics = Heap.get_ctor_statics(b)

    case Map.get(statics, :__module__) do
      nil ->
        Map.get(statics, key, :undefined)

      mod ->
        case mod.static_property(key) do
          :undefined -> Map.get(statics, key, :undefined)
          val -> val
        end
    end
  end

  defp get_own_property({:regexp, bytecode, _source}, "flags"), do: regexp_flags(bytecode)
  defp get_own_property({:regexp, _bytecode, source}, "source") when is_binary(source), do: source

  defp get_own_property({:regexp, _, _}, key), do: RegExp.proto_property(key)

  defp get_own_property(%Bytecode.Function{} = f, "prototype") do
    Heap.get_or_create_prototype(f)
  end

  defp get_own_property(%Bytecode.Function{} = f, key) do
    Map.get(Heap.get_ctor_statics(f), key, :undefined)
  end

  defp get_own_property({:closure, _, %Bytecode.Function{}} = c, "prototype") do
    Heap.get_or_create_prototype(c)
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

  def regexp_flags(<<flags_byte::8, _::binary>>) do
    [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}]
    |> Enum.reduce("", fn {bit, ch}, acc ->
      if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
    end)
  end

  def regexp_flags(_), do: ""

  def invoke_getter(fun, this_obj) do
    Interpreter.invoke_with_receiver(fun, [], 10_000_000, this_obj)
  end

  defp get_prototype_property({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      list when is_list(list) ->
        Array.proto_property(key)

      map when is_map(map) ->
        cond do
          Map.has_key?(map, map_data()) ->
            Prototypes.map_proto(key)

          Map.has_key?(map, set_data()) ->
            Prototypes.set_proto(key)

          Map.has_key?(map, proto()) ->
            # Walk prototype chain
            get_property(Map.get(map, proto()), key)

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
  defp get_prototype_property(s, key) when is_binary(s), do: JSString.proto_property(key)
  defp get_prototype_property(n, key) when is_number(n), do: Number.proto_property(key)
  defp get_prototype_property(true, key), do: Boolean.proto_property(key)
  defp get_prototype_property(false, key), do: Boolean.proto_property(key)

  defp get_prototype_property(%Bytecode.Function{} = f, key),
    do: Prototypes.function_proto_property(f, key)

  defp get_prototype_property({:closure, _, %Bytecode.Function{}} = c, key),
    do: Prototypes.function_proto_property(c, key)

  defp get_prototype_property({:builtin, "Error", _}, _key),
    do: :undefined

  defp get_prototype_property({:builtin, "Array", _}, key), do: Array.static_property(key)
  defp get_prototype_property({:builtin, "Object", _}, key), do: Object.static_property(key)
  defp get_prototype_property({:builtin, "Map", _}, _key), do: :undefined
  defp get_prototype_property({:builtin, "Set", _}, _key), do: :undefined

  defp get_prototype_property({:builtin, "Number", _}, key),
    do: Number.static_property(key)

  defp get_prototype_property({:builtin, "String", _}, key),
    do: JSString.static_property(key)

  defp get_prototype_property({:builtin, name, _} = fun, key) when is_binary(name),
    do: Prototypes.function_proto_property(fun, key)

  defp get_prototype_property(_, _), do: :undefined

  # ── Callback dispatch (used by higher-order array methods) ──

  def call_callback(fun, args) do
    case fun do
      %Bytecode.Function{} = f ->
        Interpreter.invoke(f, args, 10_000_000)

      {:closure, _, %Bytecode.Function{}} = c ->
        Interpreter.invoke(c, args, 10_000_000)

      other ->
        try do
          Builtin.call(other, args, nil)
        catch
          {:js_throw, _} -> :undefined
        end
    end
  end

  # ── Shared helpers (public for cross-module use) ──

  def new_object do
    Heap.wrap(%{})
  end

  defdelegate truthy?(val), to: Values

  def strict_equal?(a, b), do: a === b

  def stringify(val), do: Values.stringify(val)

  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: trunc(n)
  def to_int(_), do: 0

  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0
  def to_float(_), do: 0.0

  def to_number({:bigint, n}), do: n
  def to_number(val), do: Values.to_number(val)

  def normalize_index(idx, len) when idx < 0, do: max(len + idx, 0)
  def normalize_index(idx, len), do: min(idx, len)

  def sort_numeric_keys(keys) do
    {numeric, strings} =
      Enum.split_with(keys, fn
        k when is_integer(k) -> true
        k when is_binary(k) -> match?({_, ""}, Integer.parse(k))
        _ -> false
      end)

    sorted =
      Enum.sort_by(numeric, fn
        k when is_integer(k) -> k
        k when is_binary(k) -> elem(Integer.parse(k), 0)
      end)
      |> Enum.map(fn
        k when is_integer(k) -> Integer.to_string(k)
        k -> k
      end)

    sorted ++ Enum.filter(strings, &is_binary/1)
  end
end
