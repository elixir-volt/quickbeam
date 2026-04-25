defmodule QuickBEAM.VM.ObjectModel.Class do
  @moduledoc "Class runtime support: `super` resolution, constructor dispatch, and `extends` prototype wiring."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.{Bytecode, Heap}
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.Names
  alias QuickBEAM.VM.ObjectModel.{Functions, Get, Put}

  def get_super(func) do
    case func do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) -> Map.get(map, proto(), :undefined)
          _ -> :undefined
        end

      {:closure, _, %Bytecode.Function{} = fun} ->
        Heap.get_parent_ctor(fun) || :undefined

      %Bytecode.Function{} = fun ->
        Heap.get_parent_ctor(fun) || :undefined

      {:builtin, _, _} = builtin ->
        Map.get(Heap.get_ctor_statics(builtin), "__proto__", :undefined)

      _ ->
        :undefined
    end
  end

  def coalesce_this_result(result, this_obj) do
    case result do
      {:obj, _} = obj -> obj
      %Bytecode.Function{} = fun -> fun
      {:closure, _, %Bytecode.Function{}} = closure -> closure
      _ -> this_obj
    end
  end

  def raw_function({:closure, _, %Bytecode.Function{} = fun}), do: fun
  def raw_function(%Bytecode.Function{} = fun), do: fun
  def raw_function(other), do: other

  def define_class(ctor_closure, parent_ctor, class_name \\ nil) do
    ctor_closure =
      if is_binary(class_name) and class_name != "" do
        Functions.rename(ctor_closure, class_name)
      else
        ctor_closure
      end

    raw = raw_function(ctor_closure)
    proto_ref = make_ref()
    proto_map = %{"constructor" => ctor_closure}
    parent_proto = Heap.get_class_proto(parent_ctor)
    base_proto = parent_proto || Heap.get_object_prototype()
    proto_map = if base_proto, do: Map.put(proto_map, proto(), base_proto), else: proto_map

    Heap.put_obj(proto_ref, proto_map)

    Heap.put_prop_desc(proto_ref, "constructor", %{
      writable: true,
      enumerable: false,
      configurable: true
    })

    proto_obj = {:obj, proto_ref}
    Heap.put_class_proto(raw, proto_obj)
    Heap.put_ctor_statics(ctor_closure, %{"prototype" => proto_obj})

    if parent_ctor != :undefined do
      Heap.put_parent_ctor(raw, parent_ctor)
    else
      Heap.delete_parent_ctor(raw)
    end

    {proto_obj, ctor_closure}
  end

  def check_ctor_return(val) do
    cond do
      val == :undefined -> {true, val}
      object_like?(val) -> {false, val}
      true -> :error
    end
  end

  def get_super_value(proto_obj, this_obj, key) do
    case find_super_property(proto_obj, key) do
      {:accessor, getter, _} when getter != nil ->
        Invocation.invoke_with_receiver(getter, [], this_obj)

      :undefined ->
        :undefined

      val ->
        val
    end
  end

  def put_super_value(proto_obj, this_obj, key, val) do
    case find_super_setter(proto_obj, key) do
      nil -> Put.put(this_obj, key, val)
      setter -> Invocation.invoke_with_receiver(setter, [val], this_obj)
    end

    :ok
  end

  def define_class_name(ctor_closure, atom_idx, atoms \\ Heap.get_atoms()) do
    define_class(ctor_closure, :undefined, Names.resolve_atom(atoms, atom_idx))
  end

  defp object_like?({:obj, _}), do: true
  defp object_like?(%Bytecode.Function{}), do: true
  defp object_like?({:closure, _, %Bytecode.Function{}}), do: true
  defp object_like?({:builtin, _, _}), do: true
  defp object_like?({:bound, _, _, _, _}), do: true
  defp object_like?(_), do: false

  defp find_super_setter(proto_obj, key) do
    case find_super_property(proto_obj, key) do
      {:accessor, _, setter} when setter != nil -> setter
      _ -> nil
    end
  end

  defp find_super_property({:obj, ref}, key) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, val} -> val
          :error -> find_super_property(Map.get(map, proto(), :undefined), key)
        end

      _ ->
        Get.get({:obj, ref}, key)
    end
  end

  defp find_super_property({:closure, _, %Bytecode.Function{} = fun} = ctor, key) do
    statics = Heap.get_ctor_statics(ctor)

    case Map.fetch(statics, key) do
      {:ok, val} ->
        val

      :error ->
        find_super_property(
          Heap.get_parent_ctor(fun) || Map.get(statics, "__proto__", :undefined),
          key
        )
    end
  end

  defp find_super_property(%Bytecode.Function{} = fun, key) do
    statics = Heap.get_ctor_statics(fun)

    case Map.fetch(statics, key) do
      {:ok, val} ->
        val

      :error ->
        find_super_property(
          Heap.get_parent_ctor(fun) || Map.get(statics, "__proto__", :undefined),
          key
        )
    end
  end

  defp find_super_property({:builtin, _, _} = ctor, key) do
    statics = Heap.get_ctor_statics(ctor)

    case Map.fetch(statics, key) do
      {:ok, val} -> val
      :error -> find_super_property(Map.get(statics, "__proto__", :undefined), key)
    end
  end

  defp find_super_property(value, key), do: Get.get(value, key)
end
