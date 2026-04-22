defmodule QuickBEAM.VM.ObjectModel.Get do
  @moduledoc "JS property resolution: own properties, prototype chain, getters."

  import Bitwise, only: [band: 2]
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Bytecode, Heap}
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.Runtime

  alias QuickBEAM.VM.Runtime.{
    Array,
    Boolean,
    Function,
    Number,
    Object,
    RegExp,
    TypedArray
  }

  alias QuickBEAM.VM.Runtime.Map, as: JSMap
  alias QuickBEAM.VM.Runtime.Set, as: JSSet

  alias QuickBEAM.VM.Runtime.ArrayBuffer
  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.String, as: JSString

  def get(value, key) when is_binary(key) do
    case get_own(value, key) do
      :undefined ->
        result = get_prototype_raw(value, key)

        case result do
          {:accessor, getter, _} when getter != nil -> call_getter(getter, value)
          _ -> result
        end

      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, value)

      val ->
        val
    end
  end

  def get(value, key) when is_integer(key),
    do: get(value, Integer.to_string(key))

  def get(_, _), do: :undefined

  def call_getter(fun, this_obj) do
    Invocation.invoke_with_receiver(fun, [], this_obj)
  end

  def regexp_flags(<<flags_byte::8, _::binary>>) do
    [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}]
    |> Enum.reduce("", fn {bit, ch}, acc ->
      if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
    end)
  end

  def regexp_flags(_), do: ""

  def string_length(s) do
    if byte_size(s) == String.length(s) do
      byte_size(s)
    else
      s
      |> String.to_charlist()
      |> Enum.reduce(0, fn cp, acc ->
        if cp > 0xFFFF, do: acc + 2, else: acc + 1
      end)
    end
  end

  def length_of(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} -> :array.size(arr)
          list when is_list(list) -> length(list)
          map when is_map(map) -> Map.get(map, "length", map_size(map))
          _ -> 0
        end

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      string when is_binary(string) ->
        string_length(string)

      %Bytecode.Function{} = fun ->
        fun.defined_arg_count

      {:closure, _, %Bytecode.Function{} = fun} ->
        fun.defined_arg_count

      {:bound, len, _, _, _} ->
        len

      _ ->
        :undefined
    end
  end

  # ── Own property lookup ──

  defp get_own({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, _vals, proto} when key == "__proto__" ->
        if proto, do: proto, else: :undefined

      {:shape, shape_id, vals, _proto} ->
        case Heap.Shapes.lookup(shape_id, key) do
          {:ok, offset} -> elem(vals, offset)
          :error -> :undefined
        end

      nil ->
        :undefined

      %{
        proxy_target() => target,
        proxy_handler() => handler
      } ->
        get_trap = get_own(handler, "get")

        if get_trap != :undefined do
          Runtime.call_callback(get_trap, [target, key])
        else
          get_own(target, key)
        end

      {:qb_arr, _} = arr ->
        case Process.get({:qb_regexp_result, ref}) do
          %{^key => val} -> val
          _ -> get_own(arr, key)
        end

      list when is_list(list) ->
        case Process.get({:qb_regexp_result, ref}) do
          %{^key => val} -> val
          _ -> get_own(list, key)
        end

      %{date_ms() => _} = map ->
        case Map.get(map, key) do
          nil -> JSDate.proto_property(key)
          val -> val
        end

      %{buffer() => _} = map ->
        case Map.get(map, key) do
          nil -> ArrayBuffer.proto_property(key)
          val -> val
        end

      map when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, {:accessor, getter, _setter}} when getter != nil ->
            call_getter(getter, {:obj, ref})

          {:ok, val} ->
            val

          :error ->
            case Map.get(map, "__wrapped_symbol__") do
              sym when sym != nil -> get_own(sym, key)
              _ -> :undefined
            end
        end
    end
  end

  defp get_own({:qb_arr, arr}, "length"), do: :array.size(arr)

  defp get_own({:qb_arr, arr}, key) when is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 ->
        if idx < :array.size(arr), do: :array.get(idx, arr), else: :undefined

      _ ->
        :undefined
    end
  end

  defp get_own(list, "length") when is_list(list), do: length(list)

  defp get_own(list, key) when is_list(list) and is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> Enum.at(list, idx, :undefined)
      _ -> :undefined
    end
  end

  defp get_own(s, "length") when is_binary(s), do: string_length(s)
  defp get_own(s, key) when is_binary(s), do: JSString.proto_property(key)

  defp get_own(n, _) when is_number(n), do: :undefined
  defp get_own(true, _), do: :undefined
  defp get_own(false, _), do: :undefined
  defp get_own(nil, _), do: :undefined
  defp get_own(:undefined, _), do: :undefined

  defp get_own({:builtin, _name, map}, key) when is_map(map) do
    Map.get(map, key, :undefined)
  end

  defp get_own({:builtin, name, _}, "from")
       when name in ~w(Uint8Array Int8Array Uint8ClampedArray Uint16Array Int16Array Uint32Array Int32Array Float32Array Float64Array) do
    type = Map.get(TypedArray.types(), name, :uint8)

    {:builtin, "from",
     fn [source | _], _this ->
       list = Heap.to_list(source)
       TypedArray.constructor(type).(list, nil)
     end}
  end

  defp get_own({:builtin, _, _} = b, key) do
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

  defp get_own({:regexp, bytecode, _source}, "flags"), do: regexp_flags(bytecode)
  defp get_own({:regexp, _bytecode, source}, "source") when is_binary(source), do: source

  defp get_own({:regexp, _, _}, key), do: RegExp.proto_property(key)

  defp get_own(%Bytecode.Function{} = f, "prototype") do
    Heap.get_or_create_prototype(f)
  end

  defp get_own(%Bytecode.Function{} = f, key) do
    Map.get(Heap.get_ctor_statics(f), key, :undefined)
  end

  defp get_own({:closure, _, %Bytecode.Function{}} = c, "prototype") do
    Heap.get_or_create_prototype(c)
  end

  defp get_own({:closure, _, %Bytecode.Function{} = f} = c, key) do
    case Map.get(Heap.get_ctor_statics(c), key, :undefined) do
      :undefined -> Map.get(Heap.get_ctor_statics(f), key, :undefined)
      val -> val
    end
  end

  defp get_own({:symbol, desc}, "toString"),
    do: {:builtin, "toString", fn _, _ -> "Symbol(#{desc})" end}

  defp get_own({:symbol, desc, _}, "toString"),
    do: {:builtin, "toString", fn _, _ -> "Symbol(#{desc})" end}

  defp get_own({:symbol, _} = s, "valueOf"), do: {:builtin, "valueOf", fn _, _ -> s end}
  defp get_own({:symbol, _, _} = s, "valueOf"), do: {:builtin, "valueOf", fn _, _ -> s end}
  defp get_own({:symbol, desc}, "description"), do: desc
  defp get_own({:symbol, desc, _}, "description"), do: desc
  defp get_own({:bound, _, _, _, _} = b, key), do: Function.proto_property(b, key)
  defp get_own(_, _), do: :undefined

  # ── Prototype chain ──

  defp get_prototype_raw({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, _vals, proto} ->
        case proto do
          {:obj, pref} ->
            case Heap.get_obj_raw(pref) do
              {:shape, proto_shape_id, proto_vals, _proto_next} ->
                case Heap.Shapes.lookup(proto_shape_id, key) do
                  {:ok, offset} -> elem(proto_vals, offset)
                  :error -> get_prototype_raw(proto, key)
                end

              pmap when is_map(pmap) ->
                case Map.fetch(pmap, key) do
                  {:ok, val} -> val
                  :error -> get_prototype_raw(proto, key)
                end

              _ ->
                get_prototype_raw(proto, key)
            end

          _ ->
            get_from_prototype(proto, key)
        end

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
              get_from_prototype(proto, key)
            end

          _ ->
            get_from_prototype(proto, key)
        end

      _ ->
        get_from_prototype({:obj, ref}, key)
    end
  end

  defp get_prototype_raw(value, key), do: get_from_prototype(value, key)

  defp get_from_prototype({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      {:qb_arr, _} ->
        Array.proto_property(key)

      list when is_list(list) ->
        Array.proto_property(key)

      map when is_map(map) ->
        cond do
          Map.has_key?(map, map_data()) ->
            JSMap.proto_property(key)

          Map.has_key?(map, set_data()) ->
            JSSet.proto_property(key)

          Map.has_key?(map, proto()) ->
            get(Map.get(map, proto()), key)

          true ->
            :undefined
        end

      _ ->
        :undefined
    end
  end

  defp get_from_prototype({:qb_arr, _}, "constructor") do
    Map.get(Runtime.global_bindings(), "Array", :undefined)
  end

  defp get_from_prototype({:qb_arr, _}, key), do: Array.proto_property(key)

  defp get_from_prototype(list, "constructor") when is_list(list) do
    Map.get(Runtime.global_bindings(), "Array", :undefined)
  end

  defp get_from_prototype(list, key) when is_list(list), do: Array.proto_property(key)
  defp get_from_prototype(s, key) when is_binary(s), do: JSString.proto_property(key)
  defp get_from_prototype(n, key) when is_number(n), do: Number.proto_property(key)
  defp get_from_prototype(true, key), do: Boolean.proto_property(key)
  defp get_from_prototype(false, key), do: Boolean.proto_property(key)

  defp get_from_prototype(%Bytecode.Function{} = f, key) when key in ["length", "name"],
    do: Function.proto_property(f, key)

  defp get_from_prototype(%Bytecode.Function{} = f, key) do
    case Heap.get_parent_ctor(f) do
      nil -> Function.proto_property(f, key)
      parent -> fallback_to_function_proto(get(parent, key), f, key)
    end
  end

  defp get_from_prototype({:closure, _, %Bytecode.Function{}} = c, key)
       when key in ["length", "name"],
       do: Function.proto_property(c, key)

  defp get_from_prototype({:closure, _, %Bytecode.Function{} = f} = c, key) do
    case Heap.get_parent_ctor(f) do
      nil -> Function.proto_property(c, key)
      parent -> fallback_to_function_proto(get(parent, key), c, key)
    end
  end

  defp get_from_prototype({:builtin, "Error", _}, _key),
    do: :undefined

  defp get_from_prototype({:builtin, "Array", _}, key), do: Array.static_property(key)
  defp get_from_prototype({:builtin, "Object", _}, key), do: Object.static_property(key)
  defp get_from_prototype({:builtin, "Map", _}, _key), do: :undefined
  defp get_from_prototype({:builtin, "Set", _}, _key), do: :undefined

  defp get_from_prototype({:builtin, "Number", _}, key),
    do: Number.static_property(key)

  defp get_from_prototype({:builtin, "String", _}, key),
    do: JSString.static_property(key)

  defp get_from_prototype({:builtin, name, _} = fun, key) when is_binary(name),
    do: Function.proto_property(fun, key)

  defp get_from_prototype(_, _), do: :undefined

  defp fallback_to_function_proto(:undefined, fun, key), do: Function.proto_property(fun, key)
  defp fallback_to_function_proto(val, _fun, _key), do: val
end
