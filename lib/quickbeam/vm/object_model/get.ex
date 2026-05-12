defmodule QuickBEAM.VM.ObjectModel.Get do
  @moduledoc "JS property resolution: own properties, prototype chain, getters."

  import Bitwise, only: [band: 2]
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, JSThrow}
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

  alias QuickBEAM.VM.ObjectModel.PropertyKey
  alias QuickBEAM.VM.Runtime.ArrayBuffer
  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.String, as: JSString

  @doc "Reads a JavaScript property, including own lookup, prototype lookup, and getter invocation."
  def get(value, key) when is_binary(key) do
    case get_own(value, key) do
      :undefined ->
        if explicit_undefined_own?(value, key) do
          :undefined
        else
          result = get_prototype_raw(value, key)

          case result do
            {:accessor, getter, _} when getter != nil -> call_getter(getter, value)
            {:accessor, nil, _} -> :undefined
            _ -> result
          end
        end

      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, value)

      {:accessor, nil, _} ->
        :undefined

      val ->
        val
    end
  end

  def get(value, key) when is_integer(key),
    do: get(value, Integer.to_string(key))

  def get({:obj, _} = value, {:symbol, _} = sym_key), do: get_symbol(value, sym_key)
  def get({:obj, _} = value, {:symbol, _, _} = sym_key), do: get_symbol(value, sym_key)

  def get(value, {:symbol, _} = sym_key), do: get_own(value, sym_key)
  def get(value, {:symbol, _, _} = sym_key), do: get_own(value, sym_key)

  def get(_, _), do: :undefined

  defp array_prototype_shape?(offsets) do
    Map.has_key?(offsets, "constructor") and Map.has_key?(offsets, "push") and
      Map.has_key?(offsets, "pop")
  end

  defp array_prototype_map?(map) do
    Map.has_key?(map, "constructor") and Map.has_key?(map, "push") and Map.has_key?(map, "pop")
  end

  defp array_prototype_length(ref) do
    case Heap.get_obj_raw(ref) do
      {:shape, _, offsets, _, _} -> if array_prototype_shape?(offsets), do: 0
      map when is_map(map) -> if array_prototype_map?(map), do: 0
      _ -> nil
    end
  end

  defp function_prototype_has_own?(key) do
    case Heap.get_func_proto() do
      {:obj, ref} ->
        case Heap.get_obj_raw(ref) do
          map when is_map(map) -> Map.has_key?(map, key)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp get_symbol(value, sym_key) do
    case get_own(value, sym_key) do
      :undefined ->
        case get_prototype_raw(value, sym_key) do
          {:accessor, getter, _} when getter != nil -> call_getter(getter, value)
          {:accessor, nil, _} -> :undefined
          val -> val
        end

      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, value)

      val ->
        val
    end
  end

  @doc "Invokes a getter function with the provided receiver."
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

  @doc "Returns the JavaScript UTF-16 code-unit length of a string."
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

  @doc "Returns the JavaScript `length` value for array-like, string, and function values."
  def length_of(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj_raw(ref) do
          {:shape, _, offsets, vals, _} ->
            cond do
              array_prototype_shape?(offsets) ->
                0

              true ->
                case Map.fetch(offsets, "length") do
                  {:ok, off} -> elem(vals, off)
                  :error -> wrapped_shape_length(offsets, vals)
                end
            end

          {:qb_arr, arr} ->
            array_prototype_length(ref) || virtual_array_length(ref) || :array.size(arr)

          list when is_list(list) ->
            array_prototype_length(ref) || virtual_array_length(ref) || length(list)

          map when is_map(map) ->
            if array_prototype_map?(map),
              do: 0,
              else: Map.get(map, "length", wrapped_map_length(map))

          _ ->
            0
        end

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      string when is_binary(string) ->
        string_length(string)

      %QuickBEAM.VM.Function{} = fun ->
        fun.defined_arg_count

      {:closure, _, %QuickBEAM.VM.Function{} = fun} ->
        fun.defined_arg_count

      {:bound, len, _, _, _} ->
        len

      {:builtin, name, _} ->
        case QuickBEAM.VM.Builtin.named_meta(name) do
          %QuickBEAM.VM.Builtin.Meta{length: length} -> length
          _ -> :undefined
        end

      _ ->
        :undefined
    end
  end

  # ── Own property lookup ──

  defp virtual_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> nil
    end
  end

  defp wrapped_shape_length(offsets, vals) do
    case Map.fetch(offsets, "__wrapped_string__") do
      {:ok, off} -> string_length(elem(vals, off))
      :error -> map_size(offsets)
    end
  end

  defp wrapped_map_length(map) do
    case Map.fetch(map, "__wrapped_string__") do
      {:ok, value} -> string_length(value)
      :error -> map_size(map)
    end
  end

  defp wrapped_shape_proto_property(offsets, vals, key) do
    cond do
      Map.has_key?(offsets, "__wrapped_number__") ->
        Number.proto_property(key)

      Map.has_key?(offsets, "__wrapped_string__") ->
        offset = Map.fetch!(offsets, "__wrapped_string__")
        wrapped_string_property(elem(vals, offset), key)

      Map.has_key?(offsets, "__wrapped_boolean__") ->
        Boolean.proto_property(key)

      true ->
        :undefined
    end
  end

  defp prototype_object_property(%{"constructor" => {:builtin, "Date", _}}, key),
    do: JSDate.proto_property(key)

  defp prototype_object_property(_map, _key), do: :undefined

  defp wrapped_string_property(string, "length") when is_binary(string), do: string_length(string)

  defp wrapped_string_property(string, key) when is_binary(string) do
    case PropertyKey.array_index(key) do
      {:ok, idx} ->
        string
        |> String.graphemes()
        |> Enum.at(idx, :undefined)

      :error ->
        JSString.proto_property(key)
    end
  end

  defp wrapped_proto_property(map, key) do
    cond do
      Map.has_key?(map, "__wrapped_symbol__") ->
        get_own(Map.fetch!(map, "__wrapped_symbol__"), key)

      Map.has_key?(map, "__wrapped_number__") ->
        Number.proto_property(key)

      Map.has_key?(map, "__wrapped_string__") ->
        wrapped_string_property(Map.fetch!(map, "__wrapped_string__"), key)

      Map.has_key?(map, "__wrapped_boolean__") ->
        Boolean.proto_property(key)

      Map.has_key?(map, "__wrapped_bigint__") ->
        get_own(Map.fetch!(map, "__wrapped_bigint__"), key)

      true ->
        :undefined
    end
  end

  defp get_map_property(map, key, receiver) do
    case Map.fetch(map, key) do
      {:ok, {:accessor, getter, _setter}} when getter != nil -> call_getter(getter, receiver)
      {:ok, val} -> val
      :error -> :undefined
    end
  end

  defp get_own({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, _offsets, _vals, proto} when key == "__proto__" ->
        if proto, do: proto, else: :undefined

      {:shape, _shape_id, offsets, vals, _proto} ->
        cond do
          key == "length" and Map.has_key?(offsets, "constructor") and
            Map.has_key?(offsets, "push") and
              Map.has_key?(offsets, "pop") ->
            0

          true ->
            case Map.fetch(offsets, key) do
              {:ok, offset} -> elem(vals, offset)
              :error -> wrapped_shape_proto_property(offsets, vals, key)
            end
        end

      nil ->
        :undefined

      %{
        proxy_target() => target,
        proxy_handler() => handler
      } ->
        get_trap = get_own(handler, "get")

        if get_trap != :undefined do
          validate_proxy_get_invariant(
            target,
            key,
            Runtime.call_callback(get_trap, [target, key, {:obj, ref}])
          )
        else
          get_own(target, key)
        end

      {:qb_arr, _} = arr ->
        case Heap.get_regexp_result(ref) do
          %{^key => val} -> val
          _ -> array_own_property(ref, arr, key)
        end

      list when is_list(list) ->
        case Heap.get_regexp_result(ref) do
          %{^key => val} -> val
          _ -> array_own_property(ref, list, key)
        end

      %{date_ms() => _} = map ->
        case Map.get(map, key) do
          nil -> JSDate.proto_property(key)
          val -> val
        end

      %{typed_array() => true} = map ->
        case key do
          "length" -> TypedArray.element_count({:obj, ref})
          "byteLength" -> TypedArray.current_byte_length({:obj, ref})
          _ -> typed_array_property({:obj, ref}, map, key)
        end

      %{buffer() => _} = map ->
        case Map.get(map, key) do
          nil -> ArrayBuffer.proto_property(key)
          val -> val
        end

      map when is_map(map) and key == "length" ->
        if Map.has_key?(map, "constructor") and Map.has_key?(map, "push") and
             Map.has_key?(map, "pop") do
          0
        else
          case prototype_object_property(map, key) do
            :undefined ->
              case wrapped_proto_property(map, key) do
                :undefined -> get_map_property(map, key, {:obj, ref})
                val -> val
              end

            val ->
              val
          end
        end

      map when is_map(map) ->
        case prototype_object_property(map, key) do
          :undefined ->
            case wrapped_proto_property(map, key) do
              :undefined -> get_map_property(map, key, {:obj, ref})
              val -> val
            end

          val ->
            val
        end
    end
  end

  defp get_own({:qb_arr, arr}, "length"), do: :array.size(arr)

  defp get_own({:qb_arr, arr}, key) when is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} ->
        if idx < :array.size(arr), do: :array.get(idx, arr), else: :undefined

      :error ->
        :undefined
    end
  end

  defp get_own(list, "length") when is_list(list), do: length(list)

  defp get_own(list, key) when is_list(list) and is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> Enum.at(list, idx, :undefined)
      :error -> :undefined
    end
  end

  defp get_own(s, "length") when is_binary(s), do: string_length(s)
  defp get_own(s, key) when is_binary(s), do: JSString.proto_property(key)

  defp get_own(n, _) when is_number(n), do: :undefined
  defp get_own(true, _), do: :undefined
  defp get_own(false, _), do: :undefined
  defp get_own(nil, _), do: :undefined
  defp get_own(:undefined, _), do: :undefined

  defp get_own({:builtin, _name, map} = b, key) when is_map(map) do
    statics = Heap.get_ctor_statics(b)

    case Map.fetch(statics, key) do
      {:ok, :deleted} -> :undefined
      {:ok, val} -> val
      :error -> Map.get(map, key, :undefined)
    end
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

  defp get_own({:builtin, name, _}, "name"), do: name

  defp get_own({:builtin, name, _} = builtin, "length") do
    case Heap.get_ctor_statics(builtin) do
      %{"length" => :deleted} ->
        :undefined

      %{"length" => length} ->
        length

      _ ->
        case QuickBEAM.VM.Builtin.named_meta(name) do
          %QuickBEAM.VM.Builtin.Meta{length: length} -> length
          _ -> :undefined
        end
    end
  end

  defp get_own({:builtin, _, _} = b, key) do
    statics = Heap.get_ctor_statics(b)

    case Map.fetch(statics, key) do
      {:ok, :deleted} ->
        :undefined

      {:ok, val} ->
        val

      :error ->
        static_val =
          case Map.get(statics, :__module__) do
            mod when is_atom(mod) ->
              if function_exported?(mod, :static_property, 1),
                do: mod.static_property(key),
                else: :undefined

            _ ->
              :undefined
          end

        cond do
          static_val != :undefined -> static_val
          function_prototype_has_own?(key) -> :undefined
          true -> Function.proto_property(b, key)
        end
    end
  end

  defp get_own({:regexp, bytecode, _source}, "flags"), do: regexp_flags(bytecode)
  defp get_own({:regexp, _bytecode, source}, "source") when is_binary(source), do: source

  defp get_own({:regexp, _, _}, key), do: RegExp.proto_property(key)

  defp get_own(%QuickBEAM.VM.Function{} = f, "prototype") do
    Heap.get_or_create_prototype(f)
  end

  defp get_own(%QuickBEAM.VM.Function{is_strict_mode: true}, key)
       when key in ["caller", "arguments"] do
    JSThrow.type_error!(
      "'caller' and 'arguments' are restricted function properties and cannot be accessed in this context."
    )
  end

  defp get_own(%QuickBEAM.VM.Function{} = f, key) do
    case Map.get(Heap.get_ctor_statics(f), key, :not_found) do
      :not_found when key in ["length", "name"] -> Function.proto_property(f, key)
      :not_found -> :undefined
      :deleted -> :undefined
      val -> val
    end
  end

  defp get_own({:closure, _, %QuickBEAM.VM.Function{}} = c, "prototype") do
    case Map.get(Heap.get_ctor_statics(c), "prototype", :not_set) do
      :not_set -> Heap.get_or_create_prototype(c)
      {:accessor, getter, _} when getter != nil -> call_getter(getter, c)
      val -> val
    end
  end

  defp get_own({:closure, _, %QuickBEAM.VM.Function{is_strict_mode: true}}, key)
       when key in ["caller", "arguments"] do
    JSThrow.type_error!(
      "'caller' and 'arguments' are restricted function properties and cannot be accessed in this context."
    )
  end

  defp get_own({:closure, _, %QuickBEAM.VM.Function{} = f} = c, key) do
    case Map.get(Heap.get_ctor_statics(c), key, :not_found) do
      :not_found ->
        case Map.get(Heap.get_ctor_statics(f), key, :not_found) do
          :not_found when key in ["length", "name"] -> Function.proto_property(c, key)
          :not_found -> :undefined
          :deleted -> :undefined
          val -> val
        end

      :deleted ->
        :undefined

      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, c)

      val ->
        val
    end
  end

  defp get_own({:bigint, n}, "toString"),
    do: {:builtin, "toString", fn _, _ -> Integer.to_string(n) end}

  defp get_own({:bigint, n}, "valueOf"),
    do: {:builtin, "valueOf", fn _, _ -> {:bigint, n} end}

  defp get_own({:bigint, _}, "toLocaleString"),
    do: :undefined

  defp get_own({:symbol, desc}, "toString"),
    do: {:builtin, "toString", fn _, _ -> "Symbol(#{desc})" end}

  defp get_own({:symbol, desc, _}, "toString"),
    do: {:builtin, "toString", fn _, _ -> "Symbol(#{desc})" end}

  defp get_own({:symbol, _} = s, "valueOf"), do: {:builtin, "valueOf", fn _, _ -> s end}
  defp get_own({:symbol, _, _} = s, "valueOf"), do: {:builtin, "valueOf", fn _, _ -> s end}
  defp get_own({:symbol, desc}, "description"), do: desc
  defp get_own({:symbol, desc, _}, "description"), do: desc

  defp get_own({:bound, _, _, _, _} = b, key) do
    case Map.get(Heap.get_ctor_statics(b), key, :undefined) do
      :undefined -> Function.proto_property(b, key)
      {:accessor, getter, _} when getter != nil -> call_getter(getter, b)
      {:accessor, nil, _} -> :undefined
      val -> val
    end
  end

  defp get_own(_, _), do: :undefined

  defp typed_array_property(obj, map, key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> TypedArray.get_element(obj, idx)
      _ -> get_map_property(map, key, obj)
    end
  end

  defp validate_proxy_get_invariant({:obj, target_ref} = target, key, trap_result) do
    desc = Heap.get_prop_desc(target_ref, key)
    target_value = get_own(target, key)

    cond do
      match?(%{configurable: false, writable: false}, desc) and trap_result !== target_value ->
        JSThrow.type_error!("proxy get trap violates invariant")

      match?(%{configurable: false}, desc) and match?({:accessor, nil, _}, target_value) and
          trap_result != :undefined ->
        JSThrow.type_error!("proxy get trap violates invariant")

      true ->
        trap_result
    end
  end

  defp validate_proxy_get_invariant(_target, _key, trap_result), do: trap_result

  defp array_own_property(ref, array_data, "length") do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> get_own(array_data, "length")
    end
  end

  defp array_own_property(ref, array_data, key) do
    with {:ok, idx} <- PropertyKey.array_index(key),
         len when is_integer(len) <- virtual_array_length(ref),
         true <- idx >= len do
      :undefined
    else
      _ ->
        case Heap.get_array_prop(ref, key) do
          :undefined ->
            own_value = get_own(array_data, key)

            if own_value == :undefined and Heap.get_prop_desc(ref, key) == nil do
              get_from_prototype({:obj, ref}, key)
            else
              own_value
            end

          value ->
            value
        end
    end
  end

  # ── Prototype chain ──

  defp get_prototype_raw({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, _offsets, _vals, proto} ->
        case proto do
          {:obj, pref} ->
            case Heap.get_obj_raw(pref) do
              {:shape, _proto_shape_id, proto_offsets, proto_vals, _proto_next} ->
                case Map.fetch(proto_offsets, key) do
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

          nil ->
            get_default_object_prototype({:obj, ref}, key)

          _ ->
            get_from_prototype(proto, key)
        end

      map when is_map(map) and is_map_key(map, proto()) ->
        # For type-specialized objects (Map, Set, Date, etc.), check type methods first.
        type_result =
          cond do
            Map.has_key?(map, map_data()) and Map.has_key?(map, :weak) ->
              JSMap.weak_proto_property(key)

            Map.has_key?(map, map_data()) ->
              JSMap.proto_property(key)

            Map.has_key?(map, set_data()) and Map.has_key?(map, :weak) ->
              JSSet.weak_proto_property(key)

            Map.has_key?(map, set_data()) ->
              JSSet.proto_property(key)

            Map.has_key?(map, date_ms()) ->
              JSDate.proto_property(key)

            Map.has_key?(map, buffer()) and not Map.has_key?(map, typed_array()) ->
              ArrayBuffer.proto_property(key)

            true ->
              :undefined
          end

        if type_result != :undefined do
          type_result
        else
          proto = Map.get(map, :__internal_proto__, Map.get(map, proto()))

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
        end

      _ ->
        get_from_prototype({:obj, ref}, key)
    end
  end

  defp get_prototype_raw(value, key), do: get_from_prototype(value, key)

  defp explicit_undefined_own?({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, _vals, _proto} -> Map.has_key?(offsets, key)
      map when is_map(map) -> not Map.has_key?(map, proxy_target()) and Map.has_key?(map, key)
      _ -> false
    end
  end

  defp explicit_undefined_own?(_value, _key), do: false

  defp get_from_prototype({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      {:qb_arr, _} ->
        array_proto_property(key)

      list when is_list(list) ->
        array_proto_property(key)

      map when is_map(map) ->
        cond do
          Map.has_key?(map, map_data()) and Map.has_key?(map, :weak) ->
            JSMap.weak_proto_property(key)

          Map.has_key?(map, map_data()) ->
            JSMap.proto_property(key)

          Map.has_key?(map, set_data()) and Map.has_key?(map, :weak) ->
            JSSet.weak_proto_property(key)

          Map.has_key?(map, set_data()) ->
            JSSet.proto_property(key)

          Map.has_key?(map, :__internal_proto__) ->
            get(Map.get(map, :__internal_proto__), key)

          Map.has_key?(map, proto()) ->
            get(Map.get(map, proto()), key)

          true ->
            get_default_object_prototype({:obj, ref}, key)
        end

      _ ->
        :undefined
    end
  end

  defp get_from_prototype({:qb_arr, _}, "constructor") do
    Map.get(Runtime.global_bindings(), "Array", :undefined)
  end

  defp get_from_prototype({:qb_arr, _}, key), do: array_proto_property(key)

  defp get_from_prototype(list, "constructor") when is_list(list) do
    Map.get(Runtime.global_bindings(), "Array", :undefined)
  end

  defp get_from_prototype(list, key) when is_list(list), do: array_proto_property(key)

  defp get_from_prototype(s, key) when is_binary(s), do: JSString.proto_property(key)
  defp get_from_prototype(n, key) when is_number(n), do: Number.proto_property(key)
  defp get_from_prototype(true, key), do: Boolean.proto_property(key)
  defp get_from_prototype(false, key), do: Boolean.proto_property(key)

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, key) when key in ["length", "name"] do
    if Map.get(Heap.get_ctor_statics(f), key) == :deleted,
      do: fallback_to_function_proto(:undefined, f, key),
      else: Function.proto_property(f, key)
  end

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, key) do
    case Heap.get_parent_ctor(f) do
      nil -> fallback_to_function_proto(:undefined, f, key)
      parent -> fallback_to_function_proto(get(parent, key), f, key)
    end
  end

  defp get_from_prototype({:closure, _, %QuickBEAM.VM.Function{}} = c, key)
       when key in ["length", "name"] do
    if Map.get(Heap.get_ctor_statics(c), key) == :deleted,
      do: fallback_to_function_proto(:undefined, c, key),
      else: Function.proto_property(c, key)
  end

  defp get_from_prototype({:closure, _, %QuickBEAM.VM.Function{} = f} = c, key) do
    case Heap.get_parent_ctor(f) do
      nil -> fallback_to_function_proto(:undefined, c, key)
      parent -> fallback_to_function_proto(get(parent, key), c, key)
    end
  end

  defp get_from_prototype({:bound, _, _, _, _} = b, key),
    do: fallback_to_function_proto(Function.proto_property(b, key), b, key)

  defp get_from_prototype({:builtin, "Error", _}, _key),
    do: :undefined

  defp get_from_prototype({:builtin, "Array", _} = fun, key),
    do: fallback_to_function_proto(Array.static_property(key), fun, key)

  defp get_from_prototype({:builtin, "Object", _} = fun, key),
    do: fallback_to_function_proto(Object.static_property(key), fun, key)

  defp get_from_prototype({:builtin, "Map", _} = fun, key),
    do: fallback_to_function_proto(:undefined, fun, key)

  defp get_from_prototype({:builtin, "Set", _} = fun, key),
    do: fallback_to_function_proto(:undefined, fun, key)

  defp get_from_prototype({:builtin, "Number", _} = fun, key),
    do: fallback_to_function_proto(Number.static_property(key), fun, key)

  defp get_from_prototype({:builtin, "String", _} = fun, key),
    do: fallback_to_function_proto(JSString.static_property(key), fun, key)

  defp get_from_prototype({:builtin, name, _} = fun, key) when is_binary(name),
    do: fallback_to_function_proto(Function.proto_property(fun, key), fun, key)

  defp get_from_prototype(_, _), do: :undefined

  defp array_proto_property(key) do
    case Heap.get_array_proto() do
      {:obj, _} = proto ->
        case get(proto, key) do
          :undefined -> Array.proto_property(key)
          val -> val
        end

      _ ->
        Array.proto_property(key)
    end
  end

  defp get_default_object_prototype(obj, key) do
    proto = Heap.get_object_prototype() || Object.build_prototype()

    case proto do
      {:obj, _} = proto when proto != obj -> get(proto, key)
      _ -> :undefined
    end
  end

  defp fallback_to_function_proto(:undefined, fun, key) do
    case Heap.get_func_proto() do
      {:obj, _} = proto -> fallback_to_object_proto(get_own(proto, key), fun, key)
      _ -> fallback_to_object_proto(Function.proto_property(fun, key), fun, key)
    end
  end

  defp fallback_to_function_proto(val, _fun, _key), do: val

  defp fallback_to_object_proto(:undefined, fun, key), do: get_default_object_prototype(fun, key)
  defp fallback_to_object_proto(val, _fun, _key), do: val
end
