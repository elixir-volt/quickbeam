defmodule QuickBEAM.VM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  alias QuickBEAM.VM.Bytecode
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.TypedArray

  def build_prototype do
    ref = make_ref()

    Heap.put_obj(
      ref,
      build_methods do
        method "toString" do
          "[object Object]"
        end

        method "valueOf" do
          this
        end

        method "hasOwnProperty" do
          has_own_property(args, this)
        end

        method "isPrototypeOf" do
          false
        end

        method "propertyIsEnumerable" do
          property_enumerable?(args, this)
        end
      end
    )

    proto = {:obj, ref}

    for key <- [
          "toString",
          "valueOf",
          "hasOwnProperty",
          "isPrototypeOf",
          "propertyIsEnumerable",
          "constructor"
        ] do
      Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true, writable: true})
    end

    Heap.put_object_prototype(proto)
    proto
  end

  defp has_own_property([key | _], {:obj, r}) do
    data = Heap.get_obj(r, %{})
    is_map(data) and Map.has_key?(data, key)
  end

  defp has_own_property(_, _), do: false

  defp property_enumerable?([key | _], {:obj, r}) do
    not match?(%{enumerable: false}, Heap.get_prop_desc(r, key))
  end

  defp property_enumerable?(_, _), do: false

  static "keys" do
    keys(args)
  end

  static "values" do
    values(args)
  end

  static "entries" do
    entries(args)
  end

  static "assign" do
    assign(args)
  end

  static "freeze" do
    case hd(args) do
      {:obj, ref} = obj ->
        Heap.freeze(ref)
        obj

      obj ->
        obj
    end
  end

  static "is" do
    [a, b | _] = args

    cond do
      is_number(a) and is_number(b) and a == 0 and b == 0 ->
        Values.neg_zero?(a) == Values.neg_zero?(b)

      is_number(a) and is_number(b) ->
        a === b

      a == :nan and b == :nan ->
        true

      true ->
        a === b
    end
  end

  static "create" do
    case args do
      [nil | _] -> Heap.wrap(%{})
      [proto | _] -> Heap.wrap(%{proto() => proto})
      _ -> Runtime.new_object()
    end
  end

  static "getPrototypeOf" do
    case args do
      [{:obj, ref} | _] ->
        Map.get(Heap.get_obj(ref, %{}), proto(), nil)

      [{:qb_arr, _} | _] ->
        func_proto()

      [val | _] when is_list(val) ->
        Heap.get_class_proto(Runtime.global_bindings()["Array"])

      [{:builtin, _, _} = b | _] ->
        case Map.get(Heap.get_ctor_statics(b), "__proto__") do
          nil -> func_proto()
          parent -> parent
        end

      [{:closure, _, _} = c | _] ->
        case Map.get(Heap.get_ctor_statics(c), "__proto__") do
          nil -> func_proto()
          parent -> parent
        end

      [%Bytecode.Function{} | _] ->
        func_proto()

      [val | _] when is_function(val) ->
        func_proto()

      _ ->
        nil
    end
  end

  defp func_proto do
    case Process.get(:qb_func_proto) do
      nil ->
        call_fn =
          {:builtin, "call",
           fn [this | args], _ ->
             Runtime.call_callback(this, args)
           end}

        apply_fn =
          {:builtin, "apply",
           fn [this, arg_array], _ ->
             args =
               case arg_array do
                 {:obj, r} -> Heap.obj_to_list(r)
                 _ -> []
               end

             Runtime.call_callback(this, args)
           end}

        bind_fn =
          {:builtin, "bind",
           fn [this | bound_args], func ->
             {:bound, "bound", func, this, bound_args}
           end}

        proto =
          build_object do
            val("call", call_fn)
            val("apply", apply_fn)
            val("bind", bind_fn)
            val("constructor", :undefined)
          end

        Process.put(:qb_func_proto, proto)
        proto

      existing ->
        existing
    end
  end

  static "defineProperty" do
    define_property(args)
  end

  static "defineProperties" do
    define_properties(args)
  end

  static "getOwnPropertyNames" do
    get_own_property_names(args)
  end

  static "getOwnPropertyDescriptor" do
    get_own_property_descriptor(args)
  end

  static "fromEntries" do
    from_entries(args)
  end

  static "getOwnPropertySymbols" do
    case args do
      [{:obj, ref} | _] ->
        data = Heap.get_obj(ref, %{})

        syms =
          if is_map(data), do: Enum.filter(Map.keys(data), &match?({:symbol, _, _}, &1)), else: []

        Heap.wrap(syms)

      _ ->
        Heap.wrap([])
    end
  end

  static "hasOwn" do
    case args do
      [{:obj, ref}, key | _] ->
        prop_name = if is_binary(key), do: key, else: Values.stringify(key)
        map = Heap.get_obj(ref, %{})
        is_map(map) and Map.has_key?(map, prop_name)

      _ ->
        false
    end
  end

  static "setPrototypeOf" do
    case args do
      [{:obj, ref} = obj, proto | _] ->
        map = Heap.get_obj(ref, %{})
        if is_map(map), do: Heap.put_obj(ref, Map.put(map, proto(), proto))
        obj

      [obj | _] ->
        obj

      _ ->
        :undefined
    end
  end

  defp from_entries([{:obj, ref} | _]) do
    entries =
      case Heap.obj_to_list(ref) do
        list when is_list(list) -> list
        _ -> []
      end

    result_ref = make_ref()

    map =
      Enum.reduce(entries, %{}, fn
        {:obj, eref}, acc ->
          case Heap.obj_to_list(eref) do
            [k, v | _] -> Map.put(acc, Runtime.stringify(k), v)
            _ -> acc
          end

        [k, v | _], acc ->
          Map.put(acc, Runtime.stringify(k), v)

        _, acc ->
          acc
      end)

    Heap.put_obj(result_ref, map)
    {:obj, result_ref}
  end

  defp from_entries(_), do: Runtime.new_object()

  defp keys([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    if is_list(data) or match?({:qb_arr, _}, data) do
      Heap.wrap(array_indices(data))
    else
      keys_from_map(ref, data)
    end
  end

  defp keys(_) do
    Heap.wrap([])
  end

  defp keys_from_map(_ref, {:qb_arr, arr}) do
    for i <- 0..(:array.size(arr) - 1), do: Integer.to_string(i)
  end

  defp keys_from_map(_ref, list) when is_list(list) do
    Heap.wrap(array_indices(list))
  end

  defp keys_from_map(ref, map) when is_map(map) do
    Heap.wrap(enumerable_keys(ref))
  end

  defp get_own_property_names([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    names =
      case data do
        {:qb_arr, arr} ->
          for(i <- 0..(:array.size(arr) - 1), do: Integer.to_string(i)) ++ ["length"]

        list when is_list(list) ->
          array_indices(list) ++ ["length"]

        map when is_map(map) ->
          Map.keys(map)
          |> Enum.filter(&is_binary/1)
          |> Enum.reject(fn k -> String.starts_with?(k, "__") and String.ends_with?(k, "__") end)

        _ ->
          []
      end

    Heap.wrap(names)
  end

  defp get_own_property_names(_) do
    Heap.wrap([])
  end

  defp enumerable_keys(ref) do
    data = Heap.get_obj(ref, %{})

    case data do
      list when is_list(list) ->
        array_indices(list)

      map when is_map(map) ->
        raw =
          case Map.get(map, key_order()) do
            order when is_list(order) -> Enum.reverse(order)
            _ -> Map.keys(map)
          end

        Runtime.sort_numeric_keys(raw)
        |> Enum.filter(fn k ->
          not String.starts_with?(k, "__") and
            Map.has_key?(map, k) and
            not match?(%{enumerable: false}, Heap.get_prop_desc(ref, k))
        end)

      _ ->
        []
    end
  end

  defp values([{:obj, ref} | _]) do
    map = Heap.get_obj(ref, %{})
    Heap.wrap(Enum.map(enumerable_keys(ref), fn k -> Map.get(map, k) end))
  end

  defp values([map | _]) when is_map(map), do: Map.values(map)
  defp values(_), do: []

  defp entries([{:obj, ref} | _]) do
    map = Heap.get_obj(ref, %{})
    pairs = Enum.map(enumerable_keys(ref), fn k -> Heap.wrap([k, Map.get(map, k)]) end)
    Heap.wrap(pairs)
  end

  defp entries([map | _]) when is_map(map) do
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end

  defp entries(_), do: []

  defp assign([target | sources]) do
    Enum.reduce(sources, target, fn
      {:obj, ref}, {:obj, tref} ->
        src_map = Heap.get_obj(ref, %{})
        tgt_map = Heap.get_obj(tref, %{})
        Heap.put_obj(tref, Map.merge(tgt_map, src_map))
        {:obj, tref}

      map, {:obj, tref} when is_map(map) ->
        tgt_map = Heap.get_obj(tref, %{})
        Heap.put_obj(tref, Map.merge(tgt_map, map))
        {:obj, tref}

      _, acc ->
        acc
    end)
  end

  defp define_property([{:obj, ref} = obj, key, {:obj, desc_ref} | _]) do
    desc = Heap.get_obj(desc_ref, %{})
    prop_name = if is_binary(key), do: key, else: Values.stringify(key)
    existing = Heap.get_obj(ref, %{})

    if is_list(existing) or match?({:qb_arr, _}, existing) do
      case Integer.parse(prop_name) do
        {idx, ""} when idx >= 0 ->
          writable = Map.get(desc, "writable", true)
          enumerable = Map.get(desc, "enumerable", true)
          configurable = Map.get(desc, "configurable", true)

          Heap.put_prop_desc(ref, prop_name, %{
            writable: writable,
            enumerable: enumerable,
            configurable: configurable
          })

          if Map.has_key?(desc, "value") do
            Heap.array_set(ref, idx, Map.get(desc, "value"))
          end

          throw({:early_return, obj})

        _ ->
          :ok
      end
    end

    if is_map(existing) and Map.get(existing, typed_array()) do
      case Integer.parse(prop_name) do
        {idx, ""} when idx >= 0 ->
          val = Map.get(desc, "value")
          if val != nil, do: TypedArray.set_element(obj, idx, val)
          throw({:early_return, obj})

        _ ->
          :ok
      end
    end

    getter = Map.get(desc, "get")
    setter = Map.get(desc, "set")

    if getter != nil or setter != nil do
      existing_desc = Map.get(existing, prop_name)

      {old_get, old_set} =
        case existing_desc do
          {:accessor, g, s} -> {g, s}
          _ -> {nil, nil}
        end

      new_get = if getter != nil, do: getter, else: old_get
      new_set = if setter != nil, do: setter, else: old_set
      Heap.put_obj(ref, Map.put(existing, prop_name, {:accessor, new_get, new_set}))
    else
      val = Map.get(desc, "value", Map.get(existing, prop_name, :undefined))
      Heap.put_obj(ref, Map.put(existing, prop_name, val))
    end

    writable = Map.get(desc, "writable", true)
    enumerable = Map.get(desc, "enumerable", true)
    configurable = Map.get(desc, "configurable", true)

    Heap.put_prop_desc(ref, prop_name, %{
      writable: writable,
      enumerable: enumerable,
      configurable: configurable
    })

    obj
  catch
    {:early_return, val} -> val
  end

  defp define_property([{:builtin, _, _} = b, key, {:obj, desc_ref} | _]) do
    desc = Heap.get_obj(desc_ref, %{})
    prop_key = if is_binary(key), do: key, else: key

    getter = Map.get(desc, "get")
    setter = Map.get(desc, "set")

    if getter != nil or setter != nil do
      Heap.put_ctor_static(b, prop_key, {:accessor, getter, setter})
    else
      val = Map.get(desc, "value", :undefined)
      Heap.put_ctor_static(b, prop_key, val)
    end

    b
  end

  defp define_property([obj | _]), do: obj

  defp define_properties([obj, {:obj, props_ref} | _]) do
    props = Heap.get_obj(props_ref, %{})

    if is_map(props) do
      for {key, desc} <- props, is_binary(key) do
        define_property([obj, key, desc])
      end
    end

    obj
  end

  defp define_properties([obj | _]), do: obj

  defp get_own_property_descriptor([{:obj, ref}, key | _]) do
    prop_name = if is_binary(key), do: key, else: Values.stringify(key)
    data = Heap.get_obj(ref, %{})

    cond do
      is_list(data) or match?({:qb_arr, _}, data) ->
        case Integer.parse(prop_name) do
          {idx, ""} when idx >= 0 ->
            val = Heap.array_get(ref, idx)

            if val == :undefined and Heap.get_prop_desc(ref, prop_name) == nil do
              :undefined
            else
              data_desc =
                Heap.get_prop_desc(ref, prop_name) ||
                  %{writable: true, enumerable: true, configurable: true}

              data_descriptor_obj(val, data_desc)
            end

          _ ->
            :undefined
        end

      is_map(data) and Map.get(data, typed_array()) ->
        case Integer.parse(prop_name) do
          {idx, ""} when idx >= 0 ->
            val = TypedArray.get_element({:obj, ref}, idx)

            if val == :undefined do
              :undefined
            else
              immutable = TypedArray.immutable?({:obj, ref})
              desc_ref = make_ref()

              Heap.put_obj(desc_ref, %{
                "value" => val,
                "writable" => not immutable,
                "enumerable" => true,
                "configurable" => not immutable
              })

              {:obj, desc_ref}
            end

          _ ->
            :undefined
        end

      is_map(data) ->
        case Map.get(data, prop_name) do
          nil ->
            :undefined

          {:accessor, getter, setter} ->
            desc = Heap.get_prop_desc(ref, prop_name) || %{enumerable: true, configurable: true}
            desc_ref = make_ref()

            Heap.put_obj(desc_ref, %{
              "get" => getter || :undefined,
              "set" => setter || :undefined,
              "enumerable" => desc.enumerable,
              "configurable" => desc.configurable
            })

            {:obj, desc_ref}

          val ->
            data_desc =
              Heap.get_prop_desc(ref, prop_name) ||
                %{writable: true, enumerable: true, configurable: true}

            data_descriptor_obj(val, data_desc)
        end

      true ->
        :undefined
    end
  end

  defp get_own_property_descriptor([{:builtin, _, _} = b, key | _]) do
    prop_key = if is_binary(key), do: key, else: key
    statics = Heap.get_ctor_statics(b)

    case Map.get(statics, prop_key) do
      {:accessor, getter, setter} ->
        desc_ref = make_ref()

        Heap.put_obj(desc_ref, %{
          "get" => getter || :undefined,
          "set" => setter || :undefined,
          "enumerable" => false,
          "configurable" => true
        })

        {:obj, desc_ref}

      nil ->
        :undefined

      val ->
        data_descriptor_obj(val, %{writable: true, enumerable: true, configurable: true})
    end
  end

  defp get_own_property_descriptor(_), do: :undefined

  defp data_descriptor_obj(val, desc) do
    desc_ref = make_ref()

    Heap.put_obj(desc_ref, %{
      "value" => val,
      "writable" => desc.writable,
      "enumerable" => desc.enumerable,
      "configurable" => desc.configurable
    })

    {:obj, desc_ref}
  end

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
  end
end
