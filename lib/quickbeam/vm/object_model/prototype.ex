defmodule QuickBEAM.VM.ObjectModel.Prototype do
  @moduledoc "Shared JavaScript prototype access and chain helpers."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0, proxy_target: 0]

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Execution.PrototypeState
  alias QuickBEAM.VM.Runtime.FunctionKinds
  alias QuickBEAM.VM.ObjectModel.{ProxyPrototype, Semantics}
  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.Heap

  def get({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, _} -> array_like_prototype(ref)
      data when is_list(data) -> array_like_prototype(ref)
      map when is_map(map) and is_map_key(map, proxy_target()) -> ProxyPrototype.get(map, &get/1)
      map when is_map(map) -> object_map_prototype(ref, map)
      _ -> nil
    end
  end

  def get({:qb_arr, _}), do: Heap.get_func_proto()
  def get(value) when is_list(value), do: QuickBEAM.VM.Runtime.global_class_proto("Array")
  def get({:builtin, _, _} = callable), do: callable_prototype(callable)
  def get({:regexp, _, _}), do: QuickBEAM.VM.Runtime.global_class_proto("RegExp")

  def get({:regexp, _, _, ref}) do
    case RegexpState.fetch(ref, proto()) do
      {:ok, :undefined} -> QuickBEAM.VM.Runtime.global_class_proto("RegExp")
      {:ok, stored_proto} -> stored_proto
      :error -> QuickBEAM.VM.Runtime.global_class_proto("RegExp")
    end
  end

  def get({:closure, _, %QuickBEAM.VM.Function{} = function} = callable),
    do: function_kind_prototype(function, callable)

  def get({:bound, _, _, _, _} = callable), do: callable_prototype(callable)
  def get(%QuickBEAM.VM.Function{} = function), do: function_kind_prototype(function, function)
  def get(value) when is_function(value), do: Heap.get_func_proto()

  def get(value) when is_integer(value) or is_float(value),
    do: QuickBEAM.VM.Runtime.global_class_proto("Number")

  def get(value) when value in [:nan, :infinity, :neg_infinity],
    do: QuickBEAM.VM.Runtime.global_class_proto("Number")

  def get(value) when is_binary(value), do: QuickBEAM.VM.Runtime.global_class_proto("String")
  def get(value) when is_boolean(value), do: QuickBEAM.VM.Runtime.global_class_proto("Boolean")
  def get({:symbol, _}), do: QuickBEAM.VM.Runtime.global_class_proto("Symbol")
  def get({:symbol, _, _}), do: QuickBEAM.VM.Runtime.global_class_proto("Symbol")
  def get({:bigint, _}), do: QuickBEAM.VM.Runtime.global_class_proto("BigInt")
  def get(_), do: nil

  def set({:obj, ref}, new_proto) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, _} -> Heap.put_array_prop(ref, "__proto__", new_proto)
      data when is_list(data) -> Heap.put_array_prop(ref, "__proto__", new_proto)
      map when is_map(map) -> Heap.put_obj(ref, Map.put(map, proto(), new_proto))
      _ -> :ok
    end
  end

  def set(_, _), do: :ok

  def chain_contains?(value, target_ref),
    do: chain_contains?(get(value), target_ref, MapSet.new())

  def ordinary_chain_contains?({:obj, ref}, target_ref),
    do: ordinary_chain_contains?({:obj, ref}, target_ref, MapSet.new())

  def ordinary_chain_contains?(_, _target_ref), do: false

  defp ordinary_chain_contains?({:obj, ref}, target_ref, _seen) when ref == target_ref, do: true

  defp ordinary_chain_contains?({:obj, ref}, target_ref, seen) do
    if MapSet.member?(seen, ref) do
      false
    else
      case Heap.get_obj(ref, %{}) do
        map when is_map(map) and is_map_key(map, proxy_target()) ->
          false

        _ ->
          ordinary_chain_contains?(get({:obj, ref}), target_ref, MapSet.put(seen, ref))
      end
    end
  end

  defp ordinary_chain_contains?(_, _target_ref, _seen), do: false

  defp chain_contains?({:obj, ref}, target_ref, _seen) when ref == target_ref, do: true

  defp chain_contains?({:obj, ref} = object, target_ref, seen) do
    if MapSet.member?(seen, ref) do
      false
    else
      chain_contains?(get(object), target_ref, MapSet.put(seen, ref))
    end
  end

  defp chain_contains?(_, _target_ref, _seen), do: false

  defp array_like_prototype(ref) do
    if Heap.get_array_prop(ref, "__arguments__") == true do
      Heap.get_object_prototype()
    else
      Heap.get_array_proto(ref)
    end
  end

  defp object_map_prototype(ref, map) do
    if Heap.get_object_prototype() == {:obj, ref} do
      nil
    else
      case object_map_prototype_value(ref, map) do
        :null_proto -> nil
        proto -> proto
      end
    end
  end

  defp object_map_prototype_value(ref, map) do
    cond do
      Map.has_key?(map, :__internal_proto__) -> Map.get(map, :__internal_proto__)
      Semantics.array_prototype_object?(map) -> Heap.get_object_prototype()
      Heap.get_prop_desc(ref, proto()) -> Heap.get_object_prototype()
      true -> Map.get(map, proto(), Heap.get_object_prototype())
    end
  end

  defp function_kind_prototype(%QuickBEAM.VM.Function{func_kind: 1}, _callable) do
    generator_function_prototype()
  end

  defp function_kind_prototype(%QuickBEAM.VM.Function{func_kind: kind}, _callable)
       when kind in [2, 3] do
    {name, constructor} = FunctionKinds.constructor(kind)
    cached_function_kind_prototype({:qb_function_kind_prototype, name}, name, constructor)
  end

  defp function_kind_prototype(_function, callable), do: callable_prototype(callable)

  defp cached_function_kind_prototype(key, name, constructor) do
    PrototypeState.cached(key, fn ->
      ctor = QuickBEAM.VM.Builtin.builtin(name, constructor, length: 1, constructable: true)

      prototype_value = function_kind_instance_prototype(name)

      proto_properties = %{
        "constructor" => ctor,
        {:symbol, "Symbol.toStringTag"} => name,
        proto() => Heap.get_func_proto()
      }

      proto_properties =
        if prototype_value == :undefined,
          do: proto_properties,
          else: Map.put(proto_properties, "prototype", prototype_value)

      proto_obj = Heap.wrap(proto_properties)

      Heap.put_ctor_static(ctor, "prototype", proto_obj)
      Heap.put_ctor_static(ctor, "__proto__", QuickBEAM.VM.Runtime.global_constructor("Function"))

      Heap.put_prop_desc(ctor, "prototype", %{
        writable: false,
        enumerable: false,
        configurable: false
      })

      with {:obj, ref} <- proto_obj do
        Heap.put_prop_desc(ref, "constructor", %{
          writable: false,
          enumerable: false,
          configurable: true
        })

        Heap.put_prop_desc(ref, {:symbol, "Symbol.toStringTag"}, %{
          writable: false,
          enumerable: false,
          configurable: true
        })

        if prototype_value != :undefined do
          Heap.put_prop_desc(ref, "prototype", %{
            writable: false,
            enumerable: false,
            configurable: true
          })
        end
      end

      link_function_kind_instance_prototype(name, prototype_value, proto_obj)

      proto_obj
    end)
  end

  defp function_kind_instance_prototype("AsyncGeneratorFunction"),
    do: Heap.get_or_create_async_generator_prototype_object()

  defp function_kind_instance_prototype(_), do: :undefined

  defp link_function_kind_instance_prototype("AsyncGeneratorFunction", {:obj, ref}, proto_obj) do
    Heap.put_obj_key(ref, Heap.get_obj(ref, %{}), "constructor", proto_obj)

    Heap.put_prop_desc(ref, "constructor", %{
      writable: false,
      enumerable: false,
      configurable: true
    })
  end

  defp link_function_kind_instance_prototype(_, _, _), do: :ok

  defp generator_prototype_object do
    PrototypeState.cached(:qb_generator_prototype_object, fn ->
      Heap.get_or_create_generator_prototype_object()
    end)
  end

  defp generator_function_prototype do
    PrototypeState.cached(:qb_generator_function_prototype, fn ->
      generator_proto = generator_prototype_object()

      constructor = elem(FunctionKinds.constructor(1), 1)

      ctor =
        QuickBEAM.VM.Builtin.builtin("GeneratorFunction", constructor,
          length: 1,
          constructable: true
        )

      proto =
        Heap.wrap(%{
          "constructor" => ctor,
          "prototype" => generator_proto,
          {:symbol, "Symbol.toStringTag"} => "GeneratorFunction",
          proto() => Heap.get_func_proto()
        })

      Heap.put_ctor_static(ctor, "prototype", proto)

      with {:obj, ref} <- proto do
        Heap.put_prop_desc(ref, "constructor", %{
          writable: false,
          enumerable: false,
          configurable: true
        })

        Heap.put_prop_desc(ref, "prototype", %{
          writable: false,
          enumerable: false,
          configurable: true
        })

        Heap.put_prop_desc(ref, {:symbol, "Symbol.toStringTag"}, %{
          writable: false,
          enumerable: false,
          configurable: true
        })
      end

      with {:obj, generator_ref} <- generator_proto do
        Heap.put_obj_key(generator_ref, Heap.get_obj(generator_ref, %{}), "constructor", proto)

        Heap.put_prop_desc(generator_ref, "constructor", %{
          writable: false,
          enumerable: false,
          configurable: true
        })
      end

      Heap.put_prop_desc(ctor, "prototype", %{
        writable: false,
        enumerable: false,
        configurable: false
      })

      proto
    end)
  end

  defp callable_prototype({:builtin, _, _} = callable) do
    if Builtin.callable?(callable) do
      callable_static_prototype(callable)
    else
      Heap.get_object_prototype()
    end
  end

  defp callable_prototype(callable), do: callable_static_prototype(callable)

  defp callable_static_prototype(callable) do
    case Map.get(Heap.get_ctor_statics(callable), "__proto__") do
      nil -> Heap.get_func_proto()
      parent -> parent
    end
  end
end
