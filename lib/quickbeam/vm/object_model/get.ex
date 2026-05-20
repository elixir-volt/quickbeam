defmodule QuickBEAM.VM.ObjectModel.Get do
  @moduledoc """
  JavaScript property resolution: own properties, prototype chain, and getters.

  Spec:
  - ECMA-262 §7.3.2 Get
  - ECMA-262 §10.1.8 [[Get]]
  - ECMA-262 §10.1.8.1 OrdinaryGet
  - ECMA-262 §10.4 built-in exotic object internal methods where represented by VM values
  """

  import Bitwise, only: [band: 2]
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.Interpreter.Closures
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

  alias QuickBEAM.VM.ObjectModel.{
    OwnProperty,
    PropertyKey,
    Prototype,
    Semantics,
    WrappedPrimitive
  }

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

  def get({:obj, _} = value, {:symbol, _, _} = sym_key),
    do: get_symbol(value, PropertyKey.normalize(sym_key))

  def get({:regexp, _, _, _} = value, {:symbol, _} = sym_key), do: get_symbol(value, sym_key)

  def get({:regexp, _, _, _} = value, {:symbol, _, _} = sym_key),
    do: get_symbol(value, PropertyKey.normalize(sym_key))

  def get({:regexp, _, _} = value, {:symbol, _} = sym_key), do: get_symbol(value, sym_key)

  def get({:regexp, _, _} = value, {:symbol, _, _} = sym_key),
    do: get_symbol(value, PropertyKey.normalize(sym_key))

  def get(value, {:symbol, "Symbol.hasInstance"} = sym_key),
    do: get_callable_symbol(value, sym_key)

  def get(value, {:symbol, "Symbol.hasInstance", _} = sym_key),
    do: get_callable_symbol(value, PropertyKey.normalize(sym_key))

  def get(value, {:symbol, _} = sym_key) do
    if QuickBEAM.VM.Builtin.callable?(value),
      do: get_callable_symbol(value, sym_key),
      else: get_symbol(value, sym_key)
  end

  def get(value, {:symbol, _, _} = sym_key),
    do: get(value, PropertyKey.normalize(sym_key))

  def get(_, _), do: :undefined

  defp array_prototype_raw?(raw) do
    keys = if Heap.shape?(raw), do: Heap.shape_offsets(raw), else: raw

    is_map(keys) and Map.has_key?(keys, "constructor") and Map.has_key?(keys, "push") and
      Map.has_key?(keys, "pop")
  end

  defp raw_keys(raw) when is_map(raw), do: Map.keys(raw)
  defp raw_keys(raw), do: raw |> Heap.shape_offsets() |> Map.keys()

  defp array_prototype_length(ref) do
    stored_length = Heap.get_array_prop(ref, "length")

    raw = Heap.get_obj_raw(ref)

    if array_prototype_raw?(raw) do
      if is_integer(stored_length),
        do: stored_length,
        else: array_prototype_index_length(raw_keys(raw))
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

  defp array_index_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, index} -> index
      :error -> nil
    end
  end

  defp function_prototype_has_own?(key) do
    case Heap.get_func_proto() do
      {:obj, ref} ->
        match?({:ok, _}, Heap.raw_fetch(Heap.get_obj_raw(ref), key))

      _ ->
        false
    end
  end

  defp get_callable_symbol(value, sym_key) do
    if QuickBEAM.VM.Builtin.callable?(value) do
      case get_own(value, sym_key) do
        :undefined ->
          fallback_to_function_proto(get_from_prototype(value, sym_key), value, sym_key)

        {:accessor, getter, _} when getter != nil ->
          call_getter(getter, value)

        {:accessor, nil, _} ->
          :undefined

        val ->
          val
      end
    else
      get_own(value, sym_key)
    end
  end

  defp get_symbol(value, sym_key) do
    case get_own(value, sym_key) do
      :undefined ->
        if explicit_undefined_own?(value, sym_key) do
          :undefined
        else
          case get_prototype_raw(value, sym_key) do
            {:accessor, getter, _} when getter != nil -> call_getter(getter, value)
            {:accessor, nil, _} -> :undefined
            val -> val
          end
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

  def regexp_flags(bytecode) when is_binary(bytecode) do
    case regexp_header_bytes(bytecode) do
      {flags_byte, unicode_sets_byte} ->
        base =
          [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}, {64, "d"}]
          |> Enum.reduce("", fn {bit, ch}, acc ->
            if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
          end)

        if band(unicode_sets_byte, 1) != 0, do: base <> "v", else: base

      :error ->
        ""
    end
  end

  def regexp_flags(_), do: ""

  defp regexp_header_bytes(bytecode) do
    case regexp_latin1_bytes(bytecode, 2, []) do
      [flags_byte, unicode_sets_byte] -> {flags_byte, unicode_sets_byte}
      [flags_byte] -> {flags_byte, 0}
      _ -> :error
    end
  end

  defp regexp_latin1_bytes(_bytecode, 0, acc), do: Enum.reverse(acc)
  defp regexp_latin1_bytes(<<>>, _count, acc), do: Enum.reverse(acc)

  defp regexp_latin1_bytes(<<cp::utf8, rest::binary>>, count, acc) when cp <= 0xFF,
    do: regexp_latin1_bytes(rest, count - 1, [cp | acc])

  defp regexp_latin1_bytes(<<byte, rest::binary>>, count, acc),
    do: regexp_latin1_bytes(rest, count - 1, [byte | acc])

  @doc "Returns the JavaScript UTF-16 code-unit length of a string."
  def string_length(s), do: JSString.utf16_length(s)

  @doc "Returns the JavaScript `length` value for array-like, string, and function values."
  def length_of(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj_raw(ref) do
          {:qb_arr, arr} ->
            array_prototype_length(ref) || virtual_array_length(ref) || :array.size(arr)

          list when is_list(list) ->
            array_prototype_length(ref) || virtual_array_length(ref) || length(list)

          raw when is_tuple(raw) ->
            if array_prototype_raw?(raw) do
              array_prototype_length(ref) || 0
            else
              case Heap.raw_fetch(raw, "length") do
                {:ok, value} ->
                  shape_value(value, {:obj, ref})

                :error ->
                  inherited_or_wrapped_length({:obj, ref}, wrapped_raw_length(raw))
              end
            end

          %{typed_array() => true} ->
            obj = {:obj, ref}

            if TypedArray.out_of_bounds?(obj),
              do: 0,
              else: TypedArray.element_count(obj)

          map when is_map(map) ->
            if array_prototype_raw?(map) do
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
    case Map.get(Heap.get_ctor_statics(callable), "length", :not_found) do
      :deleted -> 0
      :not_found -> default
      value -> value
    end
  end

  defp virtual_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> nil
    end
  end

  defp wrapped_raw_length(raw) do
    case Heap.raw_fetch(raw, WrappedPrimitive.slot(:string)) do
      {:ok, value} when is_binary(value) -> string_length(value)
      _ -> :undefined
    end
  end

  defp wrapped_map_length(map) do
    case WrappedPrimitive.value(map, :string) do
      {:ok, value} -> string_length(value)
      :error -> :undefined
    end
  end

  defp wrapped_raw_proto_property(raw, key) do
    cond do
      match?({:ok, _}, Heap.raw_fetch(raw, WrappedPrimitive.slot(:number))) ->
        number_proto_property(key)

      match?({:ok, _}, Heap.raw_fetch(raw, WrappedPrimitive.slot(:string))) ->
        {:ok, string} = Heap.raw_fetch(raw, WrappedPrimitive.slot(:string))
        wrapped_string_property(string, key)

      match?({:ok, _}, Heap.raw_fetch(raw, WrappedPrimitive.slot(:boolean))) ->
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

  defp date_proto_property(map, key) do
    case Map.get(map, proto()) do
      {:obj, _} = proto ->
        case get(proto, key) do
          :undefined -> JSDate.proto_property(key)
          val -> val
        end

      _ ->
        JSDate.proto_property(key)
    end
  end

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
        get(value, key)

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
    if WrappedPrimitive.type(map) in [:string, :number, :boolean] and Map.has_key?(map, key) do
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
      nil ->
        :undefined

      %{proxy_target() => target, proxy_handler() => handler} = proxy ->
        if Map.get(proxy, "__proxy_revoked__") == true do
          JSThrow.type_error!("Cannot perform operation on a revoked proxy")
        end

        get_trap = get(handler, "get")

        cond do
          get_trap in [nil, :undefined] ->
            get(target, key)

          not QuickBEAM.VM.Builtin.callable?(get_trap) ->
            JSThrow.type_error!("proxy get trap is not callable")

          true ->
            validate_proxy_get_invariant(
              target,
              key,
              Invocation.invoke_callback_or_throw(get_trap, [target, key, {:obj, ref}], handler)
            )
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

      raw when is_tuple(raw) ->
        cond do
          Heap.shape?(raw) and key == "__proto__" ->
            Heap.shape_proto(raw) || :undefined

          Heap.shape?(raw) and key == "length" and array_prototype_raw?(raw) ->
            array_prototype_length(ref) || 0

          Heap.shape?(raw) ->
            case Heap.raw_fetch(raw, key) do
              {:ok, value} -> value
              :error -> wrapped_raw_proto_property(raw, key)
            end

          true ->
            :undefined
        end

      %{date_ms() => _} = map ->
        case get_map_property(map, key, {:obj, ref}) do
          :undefined -> date_proto_property(map, key)
          val -> val
        end

      %{typed_array() => true} = map ->
        obj = {:obj, ref}

        case key do
          "length" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.element_count(obj)

          "byteLength" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.current_byte_length(obj)

          "byteOffset" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: Map.get(map, "byteOffset", 0)

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
        cond do
          Heap.get_prop_desc(ref, key) == :deleted ->
            :undefined

          key == "__proto__" and Map.has_key?(map, :__internal_proto__) and Map.has_key?(map, key) ->
            get_map_property(map, key, {:obj, ref})

          true ->
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

  defp get_own(s, key) when is_binary(s) do
    case PropertyKey.array_index(key) do
      {:ok, index} when index < 4_294_967_295 -> JSString.utf16_code_unit_at(s, index)
      _ -> JSString.proto_property(key)
    end
  end

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

  defp get_own({:builtin, _name, props}, key) when is_map(props) do
    Map.get(props, key, :undefined)
  end

  defp get_own({:builtin, _, _} = builtin, key) do
    case QuickBEAM.VM.Runtime.Constructors.static_property(builtin, key) do
      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, builtin)

      {:accessor, nil, _} ->
        :undefined

      :undefined ->
        if function_prototype_has_own?(key),
          do: :undefined,
          else: fallback_to_object_proto(Function.proto_property(builtin, key), builtin, key)

      value ->
        value
    end
  end

  defp get_own({:regexp, _, _, ref} = regexp, "flags") do
    case RegexpState.fetch(ref, "flags") do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> regexp_instance_property(regexp, "flags")
    end
  end

  defp get_own({:regexp, _bytecode, source, ref} = regexp, "source") when is_binary(source) do
    case RegexpState.fetch(ref, "source") do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> regexp_instance_property(regexp, "source")
    end
  end

  defp get_own({:regexp, _, _, ref} = regexp, "lastIndex") do
    case RegexpState.fetch(ref, "lastIndex") do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> 0
    end
  end

  defp get_own({:regexp, _, _} = regexp, "flags"), do: regexp_instance_property(regexp, "flags")

  defp get_own({:regexp, _bytecode, source} = regexp, "source") when is_binary(source),
    do: regexp_instance_property(regexp, "source")

  defp get_own({:regexp, _, _}, "lastIndex"), do: 0

  defp get_own({:regexp, _, _, ref} = regexp, key) do
    case RegexpState.fetch(ref, key) do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> regexp_instance_property(regexp, key)
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
      :not_found when key in ["length", "name", "caller", "arguments"] ->
        Function.proto_property(f, key)

      :not_found ->
        :undefined

      :deleted ->
        :undefined

      val ->
        val
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
          :not_found when key in ["length", "name", "caller", "arguments"] ->
            Function.proto_property(c, key)

          :not_found ->
            :undefined

          :deleted ->
            :undefined

          val ->
            val
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
    do: {:builtin, "toString", fn _, _ -> symbol_to_string(desc) end}

  defp get_own({:symbol, desc, _}, "toString"),
    do: {:builtin, "toString", fn _, _ -> symbol_to_string(desc) end}

  defp get_own({:symbol, _} = s, "valueOf"), do: {:builtin, "valueOf", fn _, _ -> s end}
  defp get_own({:symbol, _, _} = s, "valueOf"), do: {:builtin, "valueOf", fn _, _ -> s end}
  defp get_own({:symbol, :undefined}, "description"), do: :undefined
  defp get_own({:symbol, :undefined, _}, "description"), do: :undefined
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

  defp regexp_state_value({:accessor, getter, _}, receiver) when getter != nil,
    do: call_getter(getter, receiver)

  defp regexp_state_value({:accessor, nil, _}, _receiver), do: :undefined
  defp regexp_state_value(value, _receiver), do: value

  defp symbol_to_string(:undefined), do: "Symbol()"
  defp symbol_to_string(desc), do: "Symbol(#{desc})"

  defp regexp_instance_property(_regexp, key)
       when key in [
              "source",
              "flags",
              "hasIndices",
              "global",
              "ignoreCase",
              "multiline",
              "dotAll",
              "unicode",
              "unicodeSets",
              "sticky"
            ] do
    RegExp.proto_accessor(key)
  end

  defp regexp_instance_property({:regexp, _, _, ref}, key) do
    case RegexpState.fetch(ref, proto()) do
      {:ok, instance_proto} ->
        case get(instance_proto, key) do
          :undefined -> regexp_prototype_property(key)
          value -> value
        end

      :error ->
        regexp_prototype_property(key)
    end
  end

  defp regexp_prototype_property(key) do
    case active_regexp_prototype() do
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

  defp active_regexp_prototype do
    case QuickBEAM.VM.GlobalEnvironment.current() do
      %{"RegExp" => ctor} -> get(ctor, "prototype")
      _ -> Runtime.global_class_proto("RegExp")
    end
  end

  defp typed_array_property(obj, map, key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} ->
        if Map.has_key?(map, key_order()) do
          case Map.fetch(map, key) do
            {:ok, value} -> value
            :error -> TypedArray.get_element(obj, idx)
          end
        else
          TypedArray.get_element(obj, idx)
        end

      :error ->
        get_map_property(map, key, obj)
    end
  end

  defp validate_proxy_get_invariant({:obj, target_ref} = target, key, trap_result) do
    desc = Heap.get_prop_desc(target_ref, key)
    target_value = get_own(target, key)

    cond do
      match?(%{configurable: false, writable: false}, desc) and
          not Semantics.same_value?(trap_result, target_value) ->
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
        case mapped_argument_value(ref, key) do
          {:mapped, value} ->
            value

          :not_mapped ->
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
  end

  defp mapped_argument_value(ref, key) do
    with {:ok, idx} <- PropertyKey.array_index(key),
         false <- deleted_argument?(ref, idx),
         mapped when is_map(mapped) <- Heap.get_array_prop(ref, "__mapped_arguments__"),
         {:cell, _} = cell <- Map.get(mapped, idx) do
      {:mapped, Closures.read_cell(cell)}
    else
      _ -> :not_mapped
    end
  end

  defp deleted_argument?(ref, idx) do
    case Heap.get_array_prop(ref, "__deleted_args__") do
      %MapSet{} = deleted -> MapSet.member?(deleted, idx)
      _ -> false
    end
  end

  # ── Prototype chain ──

  defp get_prototype_raw({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      raw when is_tuple(raw) ->
        if Heap.shape?(raw) do
          case Heap.shape_proto(raw) do
            {:obj, _pref} = proto ->
              case prototype_property_lookup_with_receiver(proto, key, {:obj, ref}) do
                {:found, value} -> value
                :not_found -> get_default_object_prototype({:obj, ref}, key)
              end

            nil ->
              get_default_object_prototype({:obj, ref}, key)

            :null_proto ->
              :undefined

            proto ->
              get_from_prototype(proto, key)
          end
        else
          get_from_prototype({:obj, ref}, key)
        end

      map when is_map(map) and is_map_key(map, proto()) ->
        proto = Map.get(map, :__internal_proto__, Map.get(map, proto()))

        proto_result =
          case proto do
            {:obj, _} -> prototype_property_lookup_with_receiver(proto, key, {:obj, ref})
            _ -> :not_found
          end

        type_result =
          cond do
            match?({:found, _}, proto_result) ->
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

        case type_result do
          {:found, value} ->
            value

          value when value != :undefined ->
            value

          _ ->
            case proto do
              {:obj, _pref} = proto ->
                prototype_property_with_receiver(proto, key, {:obj, ref})

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

  defp explicit_undefined_own?({:regexp, _, _, ref}, key) do
    RegexpState.has_property?(ref, key)
  end

  defp explicit_undefined_own?({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:qb_arr, _} ->
        Heap.get_prop_desc(ref, key) != nil

      data when is_list(data) ->
        Heap.get_prop_desc(ref, key) != nil

      raw when is_tuple(raw) ->
        Heap.shape?(raw) and match?({:ok, _}, Heap.raw_fetch(raw, key))

      %{typed_array() => true} ->
        match?({:ok, _}, PropertyKey.array_index(key)) or
          Map.has_key?(Heap.get_obj(ref, %{}), key)

      map when is_map(map) ->
        not Map.has_key?(map, proxy_target()) and Map.has_key?(map, key)

      _ ->
        false
    end
  end

  defp explicit_undefined_own?(value, key) when is_tuple(value) or is_struct(value),
    do: Heap.get_ctor_prop_desc(value, key) != nil

  defp explicit_undefined_own?(_value, _key), do: false

  defp get_from_prototype({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      {:qb_arr, _} ->
        if Heap.get_array_prop(ref, "__arguments__") == true do
          arguments_proto_property({:obj, ref}, key)
        else
          array_proto_property({:obj, ref}, key)
        end

      list when is_list(list) ->
        if Heap.get_array_prop(ref, "__arguments__") == true do
          arguments_proto_property({:obj, ref}, key)
        else
          array_proto_property({:obj, ref}, key)
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
            prototype_property_with_receiver(Map.get(map, :__internal_proto__), key, {:obj, ref})

          Map.get(map, proto()) == :null_proto ->
            :undefined

          Map.has_key?(map, proto()) ->
            prototype_property_with_receiver(Map.get(map, proto()), key, {:obj, ref})

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

  defp get_from_prototype({:bigint, _} = receiver, key),
    do: primitive_or_class_proto(:undefined, key, "BigInt", receiver)

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, "constructor"),
    do: function_kind_constructor(f)

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, {:symbol, "Symbol.toStringTag"} = key),
    do: function_kind_to_string_tag(f, key)

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

  defp get_from_prototype(
         {:closure, _, %QuickBEAM.VM.Function{}} = closure,
         {:symbol, "Symbol.toStringTag"} = key
       ),
       do: function_kind_to_string_tag(closure, key)

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
      parent -> fallback_to_function_proto(get_parent_static_property(parent, key, c), c, key)
    end
  end

  defp get_from_prototype({:bound, _, _, _, _} = b, key),
    do: fallback_to_function_proto(Function.proto_property(b, key), b, key)

  defp get_from_prototype({:builtin, "Error", _}, _key),
    do: :undefined

  defp get_from_prototype({:builtin, name, callback} = fun, key)
       when is_binary(name) and is_function(callback),
       do: fallback_to_function_proto(Function.proto_property(fun, key), fun, key)

  defp get_from_prototype({:builtin, name, props}, key) when is_binary(name) and is_map(props),
    do: get_own(Heap.get_object_prototype(), key)

  defp get_from_prototype(_, _), do: :undefined

  defp primitive_or_class_proto(default_value, key, class_name, receiver) do
    case active_class_proto(class_name) do
      {:obj, _} = proto ->
        case prototype_property_with_receiver(proto, key, receiver) do
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

  defp prototype_property_with_receiver(target, key, receiver) do
    case prototype_property_lookup_with_receiver(target, key, receiver) do
      {:found, value} -> value
      :not_found -> :undefined
    end
  end

  defp prototype_property_lookup_with_receiver(nil, _key, _receiver), do: :not_found

  defp prototype_property_lookup_with_receiver({:obj, ref} = target, key, receiver) do
    case raw_own_property(Heap.get_obj_raw(ref), key) do
      {:ok, {:accessor, getter, _}} when getter != nil ->
        {:found, call_getter(getter, receiver)}

      {:ok, {:accessor, nil, _}} ->
        {:found, :undefined}

      {:ok, value} ->
        {:found, value}

      :error ->
        case descriptor_property_with_receiver(target, key, receiver) do
          :not_found ->
            prototype_property_lookup_with_receiver(Prototype.get(target), key, receiver)

          found ->
            found
        end
    end
  end

  defp prototype_property_lookup_with_receiver(target, key, receiver) do
    case descriptor_property_with_receiver(target, key, receiver) do
      :not_found -> prototype_property_lookup_with_receiver(Prototype.get(target), key, receiver)
      found -> found
    end
  end

  defp descriptor_property_with_receiver(target, key, receiver) do
    case OwnProperty.descriptor(target, key) do
      {:obj, _} = desc ->
        getter = get(desc, "get")

        cond do
          getter != :undefined and getter != nil -> {:found, call_getter(getter, receiver)}
          get(desc, "value") != :undefined -> {:found, get(desc, "value")}
          true -> {:found, :undefined}
        end

      :undefined ->
        :not_found

      _ ->
        :not_found
    end
  end

  defp raw_own_property(raw, key) when is_map(raw), do: Map.fetch(raw, key)

  defp raw_own_property(raw, key) do
    if Heap.shape?(raw), do: Heap.raw_fetch(raw, key), else: :error
  end

  defp active_class_proto(class_name) do
    case QuickBEAM.VM.GlobalEnvironment.current() do
      %{^class_name => ctor} -> get(ctor, "prototype")
      _ -> Runtime.global_class_proto(class_name)
    end
  end

  defp primitive_class_proto(key, class_name) do
    case active_class_proto(class_name) do
      {:obj, _} = proto ->
        case get(proto, key) do
          :undefined -> get_own(Heap.get_object_prototype(), key)
          value -> value
        end

      _ ->
        get_own(Heap.get_object_prototype(), key)
    end
  end

  defp arguments_proto_property(obj, {:symbol, "Symbol.iterator"}) do
    case array_proto_property(obj, {:symbol, "Symbol.iterator"}) do
      :undefined -> get_default_object_prototype(obj, {:symbol, "Symbol.iterator"})
      val -> val
    end
  end

  defp arguments_proto_property(obj, key), do: get_default_object_prototype(obj, key)

  defp array_proto_property({:obj, ref}, key) do
    case Heap.get_array_proto(ref) do
      {:obj, _} = proto ->
        case get(proto, key) do
          :undefined -> receiver_array_proto_fallback(proto, key)
          val -> val
        end

      _ ->
        Array.proto_property(key)
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

  defp receiver_array_proto_fallback(proto, key) do
    if proto == Heap.get_array_proto() do
      fallback_array_proto_property(proto, key)
    else
      :undefined
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

  defp function_kind_constructor(%QuickBEAM.VM.Function{func_kind: 1} = fun) do
    function_kind_constructor(
      "GeneratorFunction",
      &QuickBEAM.VM.Runtime.Globals.Constructors.generator_function/2,
      fun
    )
  end

  defp function_kind_constructor(%QuickBEAM.VM.Function{func_kind: 2} = fun) do
    function_kind_constructor(
      "AsyncFunction",
      &QuickBEAM.VM.Runtime.Globals.Constructors.async_function/2,
      fun
    )
  end

  defp function_kind_constructor(%QuickBEAM.VM.Function{func_kind: 3} = fun) do
    function_kind_constructor(
      "AsyncGeneratorFunction",
      &QuickBEAM.VM.Runtime.Globals.Constructors.async_generator_function/2,
      fun
    )
  end

  defp function_kind_constructor(_),
    do: fallback_to_function_proto(:undefined, :undefined, "constructor")

  defp function_kind_constructor(name, callback, fun) do
    ctor = {:builtin, name, callback}
    Heap.put_ctor_static(ctor, "prototype", function_kind_constructor_prototype(name, ctor, fun))
    ctor
  end

  defp function_kind_constructor_prototype(name, ctor, fun) do
    key = {:qb_function_kind_constructor_prototype, name}

    case Process.get(key) do
      {:obj, _} = proto ->
        proto

      _ ->
        proto =
          case QuickBEAM.VM.ObjectModel.Prototype.get(fun) do
            {:obj, _} = existing ->
              existing

            _ ->
              Heap.wrap(%{
                "constructor" => ctor,
                {:symbol, "Symbol.toStringTag"} => name,
                "__proto__" => Heap.get_func_proto()
              })
          end

        Process.put(key, proto)
        proto
    end
  end

  defp function_kind_to_string_tag(callable, key) do
    case QuickBEAM.VM.ObjectModel.Prototype.get(callable) do
      {:obj, _} = proto -> get(proto, key)
      _ -> fallback_to_function_proto(:undefined, callable, key)
    end
  end

  defp get_parent_static_property(nil, _key, _receiver), do: :undefined
  defp get_parent_static_property(:undefined, _key, _receiver), do: :undefined

  defp get_parent_static_property(parent, key, receiver) do
    case Map.fetch(Heap.get_ctor_statics(parent), key) do
      {:ok, {:accessor, getter, _}} when getter != nil ->
        call_getter(getter, receiver)

      {:ok, {:accessor, nil, _}} ->
        :undefined

      {:ok, :deleted} ->
        :undefined

      {:ok, val} ->
        val

      :error ->
        case get_own(parent, key) do
          {:accessor, getter, _} when getter != nil -> call_getter(getter, receiver)
          {:accessor, nil, _} -> :undefined
          :undefined -> get_parent_static_property(next_static_parent(parent), key, receiver)
          val -> val
        end
    end
  end

  defp next_static_parent({:closure, _, %QuickBEAM.VM.Function{} = fun}),
    do: Heap.get_parent_ctor(fun)

  defp next_static_parent(%QuickBEAM.VM.Function{} = fun), do: Heap.get_parent_ctor(fun)

  defp next_static_parent({:builtin, _, _} = builtin),
    do: Map.get(Heap.get_ctor_statics(builtin), "__proto__")

  defp next_static_parent(_), do: nil

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
