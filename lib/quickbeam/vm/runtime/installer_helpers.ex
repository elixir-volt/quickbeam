defmodule QuickBEAM.VM.Runtime.InstallerHelpers do
  @moduledoc "Reusable helpers for installing constructor/prototype metadata."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, PropertyDescriptor}

  @doc "Runs `fun` with a constructor's prototype object reference when present."
  def with_prototype(ctor, fun) when is_function(fun, 1) do
    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, proto_ref} -> fun.(proto_ref)
      _ -> :ok
    end
  end

  @doc "Sets a prototype object's parent to Object.prototype."
  def install_object_parent(proto_ref, parent \\ Heap.get_object_prototype()) do
    Heap.put_obj_key(proto_ref, "__proto__", parent)
  end

  @doc "Installs prototype methods using a runtime module's proto_property/1 callback."
  def install_methods(proto_ref, module, names, opts \\ []) do
    zero_length_names = Keyword.get(opts, :zero_length, [])

    for name <- names do
      method = module.proto_property(name)
      Heap.put_obj_key(proto_ref, name, method)
      install_zero_length(method, name in zero_length_names)
      Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.method())
    end
  end

  @doc "Installs methods using a custom method lookup function."
  def install_methods_with(proto_ref, names, lookup_fun) when is_function(lookup_fun, 1) do
    for name <- names do
      Heap.put_obj_key(proto_ref, name, lookup_fun.(name))
      Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.method())
    end
  end

  @doc "Installs a non-enumerable constructor link on a prototype object."
  def install_constructor_link(proto_ref, ctor) do
    InternalMethods.set({:obj, proto_ref}, "constructor", ctor)
    Heap.put_prop_desc(proto_ref, "constructor", PropertyDescriptor.method())
  end

  @doc "Installs a default Symbol.species accessor returning this."
  def install_species(ctor) do
    sym_species = {:symbol, "Symbol.species"}

    Heap.put_ctor_static(
      ctor,
      sym_species,
      {:accessor, {:builtin, "get [Symbol.species]", fn _args, this -> this end}, nil}
    )

    Heap.put_ctor_prop_desc(ctor, sym_species, PropertyDescriptor.accessor())
  end

  @doc "Installs Symbol.toStringTag on a prototype object."
  def install_to_string_tag(proto_ref, label) do
    sym_to_string_tag = {:symbol, "Symbol.toStringTag"}
    Heap.put_obj_key(proto_ref, sym_to_string_tag, label)
    Heap.put_prop_desc(proto_ref, sym_to_string_tag, PropertyDescriptor.hidden_readonly())
  end

  @doc "Installs Symbol.iterator using the runtime module's proto_property/1 callback."
  def install_symbol_iterator(proto_ref, module) do
    sym_iter = {:symbol, "Symbol.iterator"}
    Heap.put_obj_key(proto_ref, sym_iter, module.proto_property(sym_iter))
    Heap.put_prop_desc(proto_ref, sym_iter, PropertyDescriptor.method())
  end

  @doc "Installs accessors using a custom accessor lookup function."
  def install_accessors_with(proto_ref, names, lookup_fun) when is_function(lookup_fun, 1) do
    for name <- names do
      Heap.put_obj_key(proto_ref, name, lookup_fun.(name))
      Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.accessor())
    end
  end

  @doc "Installs a builtin accessor on a prototype object."
  def install_accessor(proto_ref, name, builtin_name, getter) when is_function(getter, 1) do
    Heap.put_obj_key(
      proto_ref,
      name,
      {:accessor, {:builtin, builtin_name, fn _args, this -> getter.(this) end}, nil}
    )

    Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.accessor())
  end

  @doc "Installs a hidden readonly constructor/function static."
  def install_hidden_static(ctor, name, value) do
    Heap.put_ctor_static(ctor, name, value)
    Heap.put_ctor_prop_desc(ctor, name, PropertyDescriptor.hidden_readonly())
  end

  defp install_zero_length(method, true) do
    Heap.put_ctor_static(method, "length", 0)
    Heap.put_ctor_prop_desc(method, "length", PropertyDescriptor.hidden_readonly())
  end

  defp install_zero_length(_method, false), do: :ok
end
