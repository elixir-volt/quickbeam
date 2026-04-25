defmodule QuickBEAM.VM.ObjectModel.Methods do
  @moduledoc "Method definition helpers: installs getters, setters, and regular methods on objects and classes."

  import Bitwise, only: [band: 2]

  alias QuickBEAM.VM.{Heap, Names}
  alias QuickBEAM.VM.ObjectModel.{Functions, Put}

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
      1 -> Put.put_getter(target, name, named_method, enumerable)
      2 -> Put.put_setter(target, name, named_method, enumerable)
      _ -> Put.put(target, name, named_method, enumerable)
    end

    target
  end

  def define_method(target, method, atom_idx, flags),
    do: define_method(target, method, Names.resolve_atom(Heap.get_atoms(), atom_idx), flags)

  def define_method_computed(target, method, field_name, flags) do
    method_type = band(flags, 3)
    enumerable = band(flags, 4) != 0

    named_method =
      Functions.rename(
        method,
        case method_type do
          1 -> "get " <> Functions.function_name(field_name)
          2 -> "set " <> Functions.function_name(field_name)
          _ -> Functions.function_name(field_name)
        end
      )

    Functions.put_home_object(named_method, target)

    case method_type do
      1 -> Put.put_getter(target, field_name, named_method, enumerable)
      2 -> Put.put_setter(target, field_name, named_method, enumerable)
      _ -> Put.put(target, field_name, named_method, enumerable)
    end

    target
  end

  def set_home_object(method, target), do: Functions.put_home_object(method, target)
end
