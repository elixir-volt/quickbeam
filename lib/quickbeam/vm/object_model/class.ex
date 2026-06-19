defmodule QuickBEAM.VM.ObjectModel.Class do
  @moduledoc "Class runtime support: `super` resolution, constructor dispatch, and `extends` prototype wiring."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.{Heap, JSThrow, Value}
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.Names
  alias QuickBEAM.VM.ObjectModel.{Functions, Get, Put}

  @doc "Returns the superclass/prototype target associated with a class, method, or constructor value."
  def get_super(func) do
    case func do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) -> Map.get(map, proto(), :undefined)
          _ -> :undefined
        end

      {:closure, _, %QuickBEAM.VM.Function{} = fun} ->
        Heap.get_parent_ctor(fun) || :undefined

      %QuickBEAM.VM.Function{} = fun ->
        Heap.get_parent_ctor(fun) || :undefined

      {:builtin, _, _} = builtin ->
        Map.get(Heap.get_ctor_statics(builtin), "__proto__", :undefined)

      _ ->
        :undefined
    end
  end

  @doc "Applies JavaScript constructor return rules by keeping object-like returns and otherwise preserving `this`."
  def coalesce_this_result(result, this_obj) do
    case result do
      {:obj, _} = obj -> obj
      %QuickBEAM.VM.Function{} = fun -> fun
      {:closure, _, %QuickBEAM.VM.Function{}} = closure -> closure
      {:builtin, _, _} = builtin -> builtin
      {:bound, _, _, _, _} = bound -> bound
      {:regexp, _, _} = regexp -> regexp
      {:regexp, _, _, _} = regexp -> regexp
      _ -> this_obj
    end
  end

  @doc "Extracts the underlying VM function from closure values."
  def raw_function({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: fun
  def raw_function(%QuickBEAM.VM.Function{} = fun), do: fun
  def raw_function(other), do: other

  def default_derived_constructor?(%QuickBEAM.VM.Function{
        is_derived_class_constructor: true,
        arg_count: 0,
        var_count: 1,
        instructions: instructions
      }) do
    match?(
      {{96, [0]}, {44, []}, {99, [0]}, {100, [0]}, {17, []}, {234, _}, {97, [0]}, {27, []},
       {36, [0]}, {14, []}, {97, [0]}, {40, []}},
      instructions
    )
  end

  def default_derived_constructor?(_), do: false

  def define_class(ctor_closure, parent_ctor, class_name \\ nil) do
    original_ctor = ctor_closure

    ctor_closure =
      if is_binary(class_name) and class_name != "" do
        Functions.rename(ctor_closure, class_name)
      else
        ctor_closure
      end

    validate_superclass_constructor!(parent_ctor)

    raw = raw_function(ctor_closure)
    proto_ref = make_ref()
    proto_map = %{"constructor" => ctor_closure}

    parent_proto =
      Heap.get_class_proto(parent_ctor) || inherited_constructor_prototype(parent_ctor)

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

    existing_statics = Heap.get_ctor_statics(ctor_closure)

    ctor_statics =
      if parent_ctor != :undefined do
        Map.merge(existing_statics, %{"prototype" => proto_obj, "__proto__" => parent_ctor})
      else
        Map.merge(existing_statics, %{"prototype" => proto_obj})
      end

    ctor_statics =
      case Heap.get_ctor_statics(original_ctor) do
        %{"name" => value} -> Map.put(ctor_statics, "name", value)
        _ -> ctor_statics
      end

    Heap.put_ctor_statics(ctor_closure, ctor_statics)

    Heap.put_ctor_prop_desc(ctor_closure, "prototype", %{
      writable: false,
      enumerable: false,
      configurable: false
    })

    if parent_ctor != :undefined do
      Heap.put_parent_ctor(raw, parent_ctor)
    else
      Heap.delete_parent_ctor(raw)
    end

    {proto_obj, ctor_closure}
  end

  defp validate_superclass_constructor!(parent_ctor) when parent_ctor in [:undefined, :null],
    do: :ok

  defp validate_superclass_constructor!(parent_ctor) do
    unless Invocation.constructor?(parent_ctor) do
      JSThrow.type_error!("Class extends value is not a constructor")
    end
  end

  @doc "Classifies an explicit constructor return value according to JavaScript class semantics."
  def check_ctor_return(val) do
    cond do
      val == :undefined -> {true, val}
      Value.object_like?(val) -> {false, val}
      true -> :error
    end
  end

  defp inherited_constructor_prototype(:undefined), do: nil
  defp inherited_constructor_prototype(:null), do: :null_proto

  defp inherited_constructor_prototype(parent_ctor) do
    case Get.get(parent_ctor, "prototype") do
      {:obj, _} = proto -> proto
      :null -> :null_proto
      :null_proto -> :null_proto
      _ -> JSThrow.type_error!("parent prototype must be an object or null")
    end
  end

  @doc "Reads a property through the `super` lookup path using `this` as the getter receiver."
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

  @doc "Writes a property through the `super` lookup path using `this` as the setter receiver."
  def put_super_value(proto_obj, this_obj, key, val) do
    case find_super_setter(proto_obj, key) do
      nil -> Put.put(this_obj, key, val)
      setter -> Invocation.invoke_with_receiver(setter, [val], this_obj)
    end

    :ok
  end

  @doc "Defines an unnamed class with a constructor name resolved from the atom table."
  def define_class_name(ctor_closure, atom_idx, atoms \\ Heap.get_atoms()) do
    define_class(ctor_closure, :undefined, Names.resolve_atom(atoms, atom_idx))
  end

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

  defp find_super_property({:closure, _, %QuickBEAM.VM.Function{} = fun} = ctor, key) do
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

  defp find_super_property(%QuickBEAM.VM.Function{} = fun, key) do
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
