defmodule QuickBEAM.VM.ObjectModel.Methods do
  @moduledoc "Method definition helpers: installs getters, setters, and regular methods on objects and classes."

  import Bitwise, only: [band: 2]

  alias QuickBEAM.VM.Execution.DefinitionState
  alias QuickBEAM.VM.{Heap, Names}
  alias QuickBEAM.VM.ObjectModel.{Functions, PropertyDescriptor, Put}

  @doc "Defines a named method, getter, or setter on a target object."
  def define_method(target, method, name, flags) when is_binary(name) do
    method_type = band(flags, 3)
    enumerable = band(flags, 4) != 0

    named_method =
      Functions.rename(
        method,
        case method_type do
          1 -> "get " <> name
          2 -> "set " <> name
          _ -> name
        end
      )

    Functions.put_home_object(named_method, target)

    case method_type do
      1 -> put_getter(target, name, named_method, enumerable)
      2 -> put_setter(target, name, named_method, enumerable)
      _ -> put_method(target, name, named_method, enumerable)
    end

    target
  end

  def define_method(target, method, {:tagged_int, _} = key, flags),
    do: define_method(target, method, QuickBEAM.VM.ObjectModel.PropertyKey.normalize(key), flags)

  def define_method(target, method, atom_idx, flags),
    do: define_method(target, method, Names.resolve_atom(Heap.get_atoms(), atom_idx), flags)

  @doc "Defines a computed-name method, getter, or setter on a target object."
  def define_method_computed(target, method, field_name, flags) do
    method_type = band(flags, 3)
    enumerable = band(flags, 4) != 0

    property_key = QuickBEAM.VM.ObjectModel.PropertyKey.normalize(field_name)

    named_method =
      Functions.rename(
        method,
        case method_type do
          1 -> "get " <> Functions.function_name(property_key)
          2 -> "set " <> Functions.function_name(property_key)
          _ -> Functions.function_name(property_key)
        end
      )

    Functions.put_home_object(named_method, target)

    case method_type do
      1 -> put_getter(target, property_key, named_method, enumerable)
      2 -> put_setter(target, property_key, named_method, enumerable)
      _ -> put_method(target, property_key, named_method, enumerable)
    end

    target
  end

  defp put_getter(target, key, method, enumerable) do
    Put.put_getter(target, key, method, enumerable)
    put_callable_method_descriptor(target, key, enumerable)
  end

  defp put_setter(target, key, method, enumerable) do
    Put.put_setter(target, key, method, enumerable)
    put_callable_method_descriptor(target, key, enumerable)
  end

  defp put_method(target, key, method, enumerable) do
    DefinitionState.with_static_method_definition(target, fn ->
      Put.put(target, key, method, enumerable)
    end)

    put_callable_method_descriptor(target, key, enumerable)
  end

  defp put_callable_method_descriptor(target, key, enumerable) do
    unless match?({:obj, _}, target) do
      Heap.put_ctor_prop_desc(
        target,
        key,
        if(enumerable,
          do: PropertyDescriptor.enumerable_data(),
          else: PropertyDescriptor.method()
        )
      )
    end
  end

  @doc "Records the home object used by a method for `super` lookups."
  def set_home_object(method, target), do: Functions.put_home_object(method, target)
end
