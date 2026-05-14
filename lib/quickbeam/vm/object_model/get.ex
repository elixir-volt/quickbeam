defmodule QuickBEAM.VM.ObjectModel.Get do
  @moduledoc "JS property resolution: own properties, prototype chain, getters."

  import Bitwise, only: [band: 2]
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Execution.RegexpState
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

  alias QuickBEAM.VM.ObjectModel.{PropertyKey, WrappedPrimitive}
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

  def get(value, {:symbol, "Symbol.hasInstance"} = sym_key),
    do: get_callable_symbol(value, sym_key)

  def get(value, {:symbol, "Symbol.hasInstance", _} = sym_key),
    do: get_callable_symbol(value, sym_key)

  def get(value, {:symbol, _} = sym_key), do: get_symbol_own(value, sym_key)
  def get(value, {:symbol, _, _} = sym_key), do: get_symbol_own(value, sym_key)

  def get(_, _), do: :undefined

  defp array_prototype_shape?(offsets) do
    Map.has_key?(offsets, "constructor") and Map.has_key?(offsets, "push") and
      Map.has_key?(offsets, "pop")
  end

  defp array_prototype_map?(map) do
    Map.has_key?(map, "constructor") and Map.has_key?(map, "push") and Map.has_key?(map, "pop")
  end

  defp array_prototype_length(ref) do
    stored_length = Heap.get_array_prop(ref, "length")

    case Heap.get_obj_raw(ref) do
      {:shape, _, offsets, _, _} ->
        if array_prototype_shape?(offsets),
          do:
            if(is_integer(stored_length),
              do: stored_length,
              else: array_prototype_index_length(Map.keys(offsets))
            )

      map when is_map(map) ->
        if array_prototype_map?(map),
          do:
            if(is_integer(stored_length),
              do: stored_length,
              else: array_prototype_index_length(Map.keys(map))
            )

      _ ->
        nil
    end
  end

  defp array_prototype_index_length(keys) do
    keys
    |> Enum.reduce(0, fn key, length ->
      case array_index_key(key) do
        index when is_integer(index) -> max(length, index + 1)
        nil -> length
      end
    end)
  end

  defp array_index_key(key) when is_integer(key) and key >= 0, do: key

  defp array_index_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 -> index
      _ -> nil
    end
  end

  defp array_index_key(_), do: nil

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

  defp get_callable_symbol(value, sym_key) do
    if QuickBEAM.VM.Builtin.callable?(value) do
      case get_own(value, sym_key) do
        :undefined -> fallback_to_function_proto(:undefined, value, sym_key)
        val -> val
      end
    else
      get_own(value, sym_key)
    end
  end

  defp get_symbol_own(value, sym_key) do
    case get_own(value, sym_key) do
      {:accessor, getter, _} when getter != nil -> call_getter(getter, value)
      {:accessor, nil, _} -> :undefined
      val -> val
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

  def regexp_flags(<<flags_byte::8, unicode_sets_byte::8, _::binary>>) do
    base =
      [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}]
      |> Enum.reduce("", fn {bit, ch}, acc ->
        if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
      end)

    if band(unicode_sets_byte, 1) != 0, do: base <> "v", else: base
  end

  def regexp_flags(<<flags_byte::8, _::binary>>) do
    [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}]
    |> Enum.reduce("", fn {bit, ch}, acc ->
      if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
    end)
  end

  def regexp_flags(_), do: ""

  @doc "Returns the JavaScript UTF-16 code-unit length of a string."
  def string_length(s), do: JSString.utf16_length(s)

  @doc "Returns the JavaScript `length` value for array-like, string, and function values."
  def length_of(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj_raw(ref) do
          {:shape, _, offsets, vals, _} ->
            if array_prototype_shape?(offsets) do
              array_prototype_length(ref) || 0
            else
              case Map.fetch(offsets, "length") do
                {:ok, off} ->
                  shape_value(elem(vals, off), {:obj, ref})

                :error ->
                  inherited_or_wrapped_length({:obj, ref}, wrapped_shape_length(offsets, vals))
              end
            end

          {:qb_arr, arr} ->
            array_prototype_length(ref) || virtual_array_length(ref) || :array.size(arr)

          list when is_list(list) ->
            array_prototype_length(ref) || virtual_array_length(ref) || length(list)

          %{typed_array() => true} ->
            obj = {:obj, ref}

            if TypedArray.out_of_bounds?(obj),
              do: 0,
              else: TypedArray.element_count(obj)

          map when is_map(map) ->
            if array_prototype_map?(map) do
              array_prototype_length(ref) || 0
            else
              case Map.fetch(map, "length") do
                {:ok, _} -> get_map_property(map, "length", {:obj, ref})
                :error -> inherited_or_wrapped_length({:obj, ref}, wrapped_map_length(map))
              end
            end

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
        callable_length_of(fun, fun.defined_arg_count)

      {:closure, _, %QuickBEAM.VM.Function{} = fun} = closure ->
        callable_length_of(closure, callable_length_of(fun, fun.defined_arg_count))

      {:bound, len, _, _, _} = bound ->
        callable_length_of(bound, len)

      {:builtin, name, _} = builtin ->
        default_length =
          case QuickBEAM.VM.Builtin.named_meta(name) do
            %QuickBEAM.VM.Builtin.Meta{length: length} -> length
            _ -> :undefined
          end

        callable_length_of(builtin, default_length)

      _ ->
        :undefined
    end
  end

  # ── Own property lookup ──

  defp callable_length_of(callable, default) do
    if Map.get(Heap.get_ctor_statics(callable), "length") == :deleted, do: 0, else: default
  end

  defp virtual_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> nil
    end
  end

  defp wrapped_shape_length(offsets, vals) do
    case Map.fetch(offsets, WrappedPrimitive.slot(:string)) do
      {:ok, off} -> string_length(elem(vals, off))
      :error -> :undefined
    end
  end

  defp wrapped_map_length(map) do
    case WrappedPrimitive.value(map, :string) do
      {:ok, value} -> string_length(value)
      :error -> :undefined
    end
  end

  defp wrapped_shape_proto_property(offsets, vals, key) do
    cond do
      Map.has_key?(offsets, WrappedPrimitive.slot(:number)) ->
        number_proto_property(key)

      Map.has_key?(offsets, WrappedPrimitive.slot(:string)) ->
        offset = Map.fetch!(offsets, WrappedPrimitive.slot(:string))
        wrapped_string_property(elem(vals, offset), key)

      Map.has_key?(offsets, WrappedPrimitive.slot(:boolean)) ->
        Boolean.proto_property(key)

      true ->
        :undefined
    end
  end

  defp number_proto_property(key) do
    case Runtime.global_class_proto("Number") do
      {:obj, ref} = proto ->
        if Heap.get_prop_desc(ref, key) == :deleted,
          do: get_default_object_prototype(proto, key),
          else: Number.proto_property(key)

      _ ->
        Number.proto_property(key)
    end
  end

  defp prototype_object_property(%{"constructor" => {:builtin, "Date", _}}, key),
    do: JSDate.proto_property(key)

  defp prototype_object_property(_map, _key), do: :undefined

  defp wrapped_string_property(string, "length") when is_binary(string), do: string_length(string)

  defp wrapped_string_property(string, key) when is_binary(string) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> JSString.utf16_code_unit_at(string, idx)
      :error -> string_proto_property(key)
    end
  end

  defp string_proto_property(key) do
    case Runtime.global_class_proto("String") do
      {:obj, ref} = proto ->
        if Heap.get_prop_desc(ref, key) == :deleted,
          do: get_default_object_prototype(proto, key),
          else: JSString.proto_property(key)

      _ ->
        JSString.proto_property(key)
    end
  end

  defp wrapped_proto_property(map, key) do
    case WrappedPrimitive.type(map) do
      :symbol ->
        {:ok, value} = WrappedPrimitive.value(map, :symbol)
        get(value, key)

      :number ->
        number_proto_property(key)

      :string ->
        {:ok, value} = WrappedPrimitive.value(map, :string)
        wrapped_string_property(value, key)

      :boolean ->
        Boolean.proto_property(key)

      :bigint ->
        {:ok, value} = WrappedPrimitive.value(map, :bigint)
        get_own(value, key)

      _ ->
        :undefined
    end
  end

  defp inherited_or_wrapped_length(obj, fallback) do
    case get(obj, "length") do
      :undefined -> fallback
      value -> value
    end
  end

  defp shape_value({:accessor, getter, _setter}, receiver) when getter != nil,
    do: call_getter(getter, receiver)

  defp shape_value({:accessor, nil, _setter}, _receiver), do: :undefined
  defp shape_value(value, _receiver), do: value

  defp get_wrapped_or_map_property(map, key, receiver) do
    if WrappedPrimitive.type(map) in [:string, :boolean] and Map.has_key?(map, key) do
      get_map_property(map, key, receiver)
    else
      case wrapped_proto_property(map, key) do
        :undefined -> get_map_property(map, key, receiver)
        val -> val
      end
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
        if key == "length" and Map.has_key?(offsets, "constructor") and
             Map.has_key?(offsets, "push") and Map.has_key?(offsets, "pop") do
          array_prototype_length(ref) || 0
        else
          case Map.fetch(offsets, key) do
            {:ok, offset} -> elem(vals, offset)
            :error -> wrapped_shape_proto_property(offsets, vals, key)
          end
        end

      nil ->
        :undefined

      %{proxy_target() => target, proxy_handler() => handler} = proxy ->
        if Map.get(proxy, "__proxy_revoked__") == true do
          JSThrow.type_error!("Cannot perform operation on a revoked proxy")
        end

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
        Map.get(map, key, :undefined)

      %{typed_array() => true} = map ->
        obj = {:obj, ref}

        case key do
          "length" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.element_count(obj)

          "byteLength" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.current_byte_length(obj)

          _ ->
            typed_array_property(obj, map, key)
        end

      %{buffer() => _} = map ->
        case Map.get(map, key) do
          nil -> ArrayBuffer.proto_property(key)
          val -> val
        end

      map when is_map(map) and key == "length" ->
        if Map.has_key?(map, "constructor") and Map.has_key?(map, "push") and
             Map.has_key?(map, "pop") do
          array_prototype_length(ref) || 0
        else
          case prototype_object_property(map, key) do
            :undefined -> get_wrapped_or_map_property(map, key, {:obj, ref})
            val -> val
          end
        end

      map when is_map(map) ->
        if Heap.get_prop_desc(ref, key) == :deleted do
          :undefined
        else
          case prototype_object_property(map, key) do
            :undefined -> get_wrapped_or_map_property(map, key, {:obj, ref})
            val -> val
          end
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
      {:ok, {:accessor, getter, _}} when getter != nil -> call_getter(getter, b)
      {:ok, {:accessor, nil, _}} -> :undefined
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

  defp get_own({:builtin, _name, props}, key) when is_map(props) do
    Map.get(props, key, :undefined)
  end

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

      {:ok, {:accessor, getter, _}} when getter != nil ->
        call_getter(getter, b)

      {:ok, {:accessor, nil, _}} ->
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
          true -> fallback_to_object_proto(Function.proto_property(b, key), b, key)
        end
    end
  end

  defp get_own({:regexp, bytecode, _source, ref}, "flags") do
    case RegexpState.fetch(ref, "flags") do
      {:ok, value} -> value
      :error -> regexp_flags(bytecode)
    end
  end

  defp get_own({:regexp, _bytecode, source, ref}, "source") when is_binary(source) do
    case RegexpState.fetch(ref, "source") do
      {:ok, value} -> value
      :error -> source
    end
  end

  defp get_own({:regexp, _, _, ref}, "lastIndex") do
    case RegexpState.fetch(ref, "lastIndex") do
      {:ok, value} -> value
      :error -> 0
    end
  end

  defp get_own({:regexp, bytecode, _source}, "flags"), do: regexp_flags(bytecode)
  defp get_own({:regexp, _bytecode, source}, "source") when is_binary(source), do: source
  defp get_own({:regexp, _, _}, "lastIndex"), do: 0

  defp get_own({:regexp, _, _, ref}, key) do
    case RegexpState.fetch(ref, key) do
      {:ok, value} -> value
      :error -> regexp_prototype_property(key)
    end
  end

  defp get_own({:regexp, _, _}, key), do: regexp_prototype_property(key)

  defp get_own(%QuickBEAM.VM.Function{} = f, "prototype") do
    case Map.get(Heap.get_ctor_statics(f), "prototype", :not_set) do
      :not_set -> Heap.get_or_create_prototype(f)
      {:accessor, getter, _} when getter != nil -> call_getter(getter, f)
      val -> val
    end
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

  defp regexp_prototype_property(key) do
    case Runtime.global_class_proto("RegExp") do
      {:obj, ref} = proto ->
        if Heap.get_prop_desc(ref, key) == :deleted do
          :undefined
        else
          case get(proto, key) do
            :undefined -> RegExp.proto_property(key)
            value -> value
          end
        end

      proto ->
        case get(proto, key) do
          :undefined -> RegExp.proto_property(key)
          value -> value
        end
    end
  end

  defp typed_array_property(obj, map, key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> TypedArray.get_element(obj, idx)
      :error -> get_map_property(map, key, obj)
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

          :null_proto ->
            :undefined

          _ ->
            get_from_prototype(proto, key)
        end

      map when is_map(map) and is_map_key(map, proto()) ->
        proto_result = direct_prototype_property(map, key)

        type_result =
          cond do
            proto_result != :undefined ->
              proto_result

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

            :null_proto ->
              :undefined

            _ ->
              get_from_prototype(proto, key)
          end
        end

      _ ->
        get_from_prototype({:obj, ref}, key)
    end
  end

  defp get_prototype_raw(value, key), do: get_from_prototype(value, key)

  defp direct_prototype_property(map, key) do
    case Map.get(map, :__internal_proto__, Map.get(map, proto())) do
      {:obj, proto_ref} = proto ->
        case Heap.get_obj(proto_ref, %{}) do
          proto_map when is_map(proto_map) -> Map.get(proto_map, key, :undefined)
          _ -> get(proto, key)
        end

      _ ->
        :undefined
    end
  end

  defp explicit_undefined_own?({:regexp, _, _, ref}, key) do
    RegexpState.has_property?(ref, key)
  end

  defp explicit_undefined_own?({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, _vals, _proto} -> Map.has_key?(offsets, key)
      map when is_map(map) -> not Map.has_key?(map, proxy_target()) and Map.has_key?(map, key)
      data when is_list(data) -> Heap.get_prop_desc(ref, key) != nil
      {:qb_arr, _} -> Heap.get_prop_desc(ref, key) != nil
      _ -> false
    end
  end

  defp explicit_undefined_own?(value, key) when is_tuple(value) or is_struct(value),
    do: Heap.get_ctor_prop_desc(value, key) != nil

  defp explicit_undefined_own?(_value, _key), do: false

  defp get_from_prototype({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      {:qb_arr, _} ->
        if Heap.get_array_prop(ref, "__arguments__") == true do
          get_default_object_prototype({:obj, ref}, key)
        else
          array_proto_property(key)
        end

      list when is_list(list) ->
        if Heap.get_array_prop(ref, "__arguments__") == true do
          get_default_object_prototype({:obj, ref}, key)
        else
          array_proto_property(key)
        end

      map when is_map(map) ->
        cond do
          Map.has_key?(map, proxy_target()) and
              QuickBEAM.VM.Builtin.callable?(Map.get(map, proxy_target())) ->
            fallback_to_function_proto(:undefined, Map.get(map, proxy_target()), key)

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

          Map.get(map, proto()) == :null_proto ->
            :undefined

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

  defp get_from_prototype(s, key) when is_binary(s),
    do: primitive_or_class_proto(string_proto_property(key), key, "String", s)

  defp get_from_prototype(n, key) when is_number(n),
    do: primitive_or_class_proto(Number.proto_property(key), key, "Number", n)

  defp get_from_prototype(n, key) when n in [:nan, :infinity, :neg_infinity],
    do: primitive_or_class_proto(Number.proto_property(key), key, "Number", n)

  defp get_from_prototype(true, key),
    do: primitive_or_class_proto(Boolean.proto_property(key), key, "Boolean", true)

  defp get_from_prototype(false, key),
    do: primitive_or_class_proto(Boolean.proto_property(key), key, "Boolean", false)

  defp get_from_prototype({:symbol, _, _}, key), do: primitive_class_proto(key, "Symbol")
  defp get_from_prototype({:symbol, _}, key), do: primitive_class_proto(key, "Symbol")
  defp get_from_prototype({:bigint, _}, key), do: primitive_class_proto(key, "BigInt")

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, "constructor"),
    do: function_kind_constructor(f)

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

  defp get_from_prototype({:closure, _, %QuickBEAM.VM.Function{} = f}, "constructor"),
    do: function_kind_constructor(f)

  defp get_from_prototype({:closure, _, %QuickBEAM.VM.Function{} = f} = c, key)
       when key in ["length", "name"] do
    if Map.get(Heap.get_ctor_statics(c), key) == :deleted or
         Map.get(Heap.get_ctor_statics(f), key) == :deleted,
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

  defp get_from_prototype({:builtin, name, callback} = fun, key)
       when is_binary(name) and is_function(callback),
       do: fallback_to_function_proto(Function.proto_property(fun, key), fun, key)

  defp get_from_prototype({:builtin, name, props}, key) when is_binary(name) and is_map(props),
    do: get_own(Heap.get_object_prototype(), key)

  defp get_from_prototype(_, _), do: :undefined

  defp primitive_or_class_proto(default_value, key, class_name, receiver) do
    case Runtime.global_class_proto(class_name) do
      {:obj, proto_ref} ->
        case raw_proto_property(proto_ref, key) do
          {:accessor, getter, _} when getter != nil ->
            call_getter(getter, receiver)

          {:accessor, nil, _} ->
            :undefined

          :undefined ->
            if(default_value == :undefined,
              do: get_own(Heap.get_object_prototype(), key),
              else: default_value
            )

          value ->
            value
        end

      _ ->
        if default_value == :undefined,
          do: get_own(Heap.get_object_prototype(), key),
          else: default_value
    end
  end

  defp raw_proto_property(ref, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, vals, _proto} ->
        case Map.fetch(offsets, key) do
          {:ok, offset} -> elem(vals, offset)
          :error -> :undefined
        end

      map when is_map(map) ->
        Map.get(map, key, :undefined)

      _ ->
        :undefined
    end
  end

  defp primitive_class_proto(key, class_name) do
    case Runtime.global_class_proto(class_name) do
      {:obj, _} = proto ->
        case get(proto, key) do
          :undefined -> get_own(Heap.get_object_prototype(), key)
          value -> value
        end

      _ ->
        get_own(Heap.get_object_prototype(), key)
    end
  end

  defp array_proto_property(key) do
    case Heap.get_array_proto() do
      {:obj, _} = proto ->
        case get(proto, key) do
          :undefined -> fallback_array_proto_property(proto, key)
          val -> val
        end

      _ ->
        Array.proto_property(key)
    end
  end

  defp fallback_array_proto_property(proto, key) do
    case Array.proto_property(key) do
      :undefined -> get_default_object_prototype(proto, key)
      val -> val
    end
  end

  defp get_default_object_prototype(obj, key) do
    proto = Heap.get_object_prototype() || Object.build_prototype()

    case proto do
      {:obj, _} = proto when proto != obj -> get(proto, key)
      _ -> :undefined
    end
  end

  defp function_kind_constructor(%QuickBEAM.VM.Function{func_kind: 1}),
    do:
      {:builtin, "GeneratorFunction",
       &QuickBEAM.VM.Runtime.Globals.Constructors.generator_function/2}

  defp function_kind_constructor(%QuickBEAM.VM.Function{func_kind: 2}),
    do: {:builtin, "AsyncFunction", &QuickBEAM.VM.Runtime.Globals.Constructors.async_function/2}

  defp function_kind_constructor(%QuickBEAM.VM.Function{func_kind: 3}),
    do:
      {:builtin, "AsyncGeneratorFunction",
       &QuickBEAM.VM.Runtime.Globals.Constructors.async_generator_function/2}

  defp function_kind_constructor(_),
    do: fallback_to_function_proto(:undefined, :undefined, "constructor")

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
