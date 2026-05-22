defmodule QuickBEAM.VM.Runtime.Symbol do
  @moduledoc "JS `Symbol` built-in: constructor, global symbol registry (`Symbol.for`/`keyFor`), and well-known symbol constants."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{Heap, JSThrow}

  alias QuickBEAM.VM.ObjectModel.{PropertyDescriptor, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime.InstallerHelpers
  alias QuickBEAM.VM.Semantics.Values

  @well_known_symbol_names ~w(iterator toPrimitive hasInstance toStringTag asyncIterator asyncDispose dispose isConcatSpreadable species match matchAll replace search split unscopables)

  builtin_definition("Symbol",
    constructor: constructor(),
    length: 0,
    phase: :fundamental,
    after_install: &__MODULE__.install_builtin/2
  )

  def install_builtin(ctor, opts \\ []) do
    object_proto = Keyword.get(opts, :object_proto, Heap.get_object_prototype())

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref, object_proto)
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
      install_prototype_properties(proto_ref)
    end)

    for name <- static_property_names() do
      install_static_property(ctor, name)
    end
  end

  defp install_prototype_properties(proto_ref) do
    InstallerHelpers.install_methods(proto_ref, __MODULE__, ~w(toString valueOf))

    primitive = {:builtin, "[Symbol.toPrimitive]", fn _args, this -> symbol_value(this) end}
    Heap.put_obj_key(proto_ref, {:symbol, "Symbol.toPrimitive"}, primitive)

    Heap.put_prop_desc(
      proto_ref,
      {:symbol, "Symbol.toPrimitive"},
      PropertyDescriptor.hidden_readonly()
    )

    Heap.put_ctor_static(primitive, "length", 1)
    Heap.put_ctor_prop_desc(primitive, "length", PropertyDescriptor.hidden_readonly())

    Heap.put_obj_key(
      proto_ref,
      "description",
      {:accessor, {:builtin, "get description", fn _args, this -> symbol_description(this) end},
       nil}
    )

    Heap.put_prop_desc(proto_ref, "description", PropertyDescriptor.accessor())

    Heap.put_obj_key(proto_ref, {:symbol, "Symbol.toStringTag"}, "Symbol")

    Heap.put_prop_desc(
      proto_ref,
      {:symbol, "Symbol.toStringTag"},
      PropertyDescriptor.hidden_readonly()
    )
  end

  defp install_static_property(ctor, name) do
    value = unique_function(static_property(name))
    meta = static_property_meta(name) || QuickBEAM.VM.Builtin.meta(name)

    Heap.put_ctor_static(ctor, name, value)
    Heap.put_ctor_prop_desc(ctor, name, descriptor_from_meta(meta))

    case value do
      {:builtin, _, _} ->
        QuickBEAM.VM.Builtin.put_builtin_metadata(
          value,
          QuickBEAM.VM.Builtin.meta(name,
            length: QuickBEAM.VM.Builtin.length(meta),
            constructable: false
          )
        )

        Heap.put_ctor_static(value, "length", QuickBEAM.VM.Builtin.length(meta))

        Heap.put_ctor_prop_desc(value, "length", %{
          writable: false,
          enumerable: false,
          configurable: true
        })

      _ ->
        :ok
    end
  end

  defp unique_function({:builtin, name, cb}) when is_function(cb, 2) do
    token = make_ref()
    {:builtin, name, fn args, this -> {token, cb.(args, this)} |> elem(1) end}
  end

  defp unique_function(value), do: value

  defp descriptor_from_meta(%QuickBEAM.VM.Builtin.Meta{} = meta) do
    %{
      writable: meta.writable?,
      enumerable: meta.enumerable?,
      configurable: meta.configurable?
    }
  end

  def constructor do
    fn
      _args, {:obj, _} ->
        JSThrow.type_error!("Symbol is not a constructor")

      args, _this ->
        desc =
          case args do
            [] ->
              :undefined

            [:undefined | _] ->
              :undefined

            [s | _] when is_binary(s) ->
              s

            [{:symbol, _} | _] ->
              JSThrow.type_error!("Cannot convert a Symbol value to a string")

            [{:symbol, _, _} | _] ->
              JSThrow.type_error!("Cannot convert a Symbol value to a string")

            [value | _] ->
              QuickBEAM.VM.Semantics.Values.stringify(value)
          end

        {:symbol, desc, make_ref()}
    end
  end

  static_val("iterator", {:symbol, "Symbol.iterator"})
  static_val("toPrimitive", {:symbol, "Symbol.toPrimitive"})
  static_val("hasInstance", {:symbol, "Symbol.hasInstance"})
  static_val("toStringTag", {:symbol, "Symbol.toStringTag"})
  static_val("asyncIterator", {:symbol, "Symbol.asyncIterator"})
  static_val("asyncDispose", {:symbol, "Symbol.asyncDispose"})
  static_val("dispose", {:symbol, "Symbol.dispose"})
  static_val("isConcatSpreadable", {:symbol, "Symbol.isConcatSpreadable"})
  static_val("species", {:symbol, "Symbol.species"})
  static_val("match", {:symbol, "Symbol.match"})
  static_val("matchAll", {:symbol, "Symbol.matchAll"})
  static_val("replace", {:symbol, "Symbol.replace"})
  static_val("search", {:symbol, "Symbol.search"})
  static_val("split", {:symbol, "Symbol.split"})
  static_val("unscopables", {:symbol, "Symbol.unscopables"})

  proto "toString" do
    symbol_value(this) |> Values.stringify()
  end

  proto "valueOf" do
    symbol_value(this)
  end

  def well_known_symbol_names, do: @well_known_symbol_names

  def static_property_meta(name) when name in @well_known_symbol_names do
    QuickBEAM.VM.Builtin.meta(name,
      writable: false,
      enumerable: false,
      configurable: false
    )
  end

  defp symbol_value({:symbol, _} = symbol), do: symbol
  defp symbol_value({:symbol, _, _} = symbol), do: symbol

  defp symbol_value({:obj, ref}) do
    case Heap.get_obj(ref, %{}) |> WrappedPrimitive.value(:symbol) do
      {:ok, symbol} -> symbol
      :error -> JSThrow.type_error!("Symbol.prototype method called on incompatible receiver")
    end
  end

  defp symbol_value(_),
    do: JSThrow.type_error!("Symbol.prototype method called on incompatible receiver")

  defp symbol_description(this) do
    case symbol_value(this) do
      {:symbol, :undefined} -> :undefined
      {:symbol, :undefined, _} -> :undefined
      {:symbol, description} -> description
      {:symbol, description, _} -> description
    end
  end

  static "for", length: 1 do
    value = arg(args, 0, :undefined)

    key =
      case value do
        {:symbol, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a string")
        {:symbol, _, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a string")
        other -> QuickBEAM.VM.Semantics.Values.stringify(other)
      end

    case Heap.get_symbol(key) do
      nil ->
        sym = {:symbol, key}
        Heap.put_symbol(key, sym)
        sym

      existing ->
        existing
    end
  end

  static "keyFor", length: 1 do
    case arg(args, 0, :undefined) do
      {:symbol, key} = symbol ->
        if Heap.get_symbol(key) == symbol, do: key, else: :undefined

      {:symbol, _, _} ->
        :undefined

      _ ->
        JSThrow.type_error!("Symbol.keyFor requires a symbol")
    end
  end
end
