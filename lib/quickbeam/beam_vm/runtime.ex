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

  alias QuickBEAM.BeamVM.Bytecode


  alias QuickBEAM.BeamVM.Runtime.{
    Boolean,
    Builtins,
    Console,
    Globals,
    JSON,
    MapSet,
    Math,
    Promise,
    Reflect,
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
