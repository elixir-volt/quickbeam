defmodule QuickBEAM.VM.Runtime.CoreConstructorInstaller do
  @moduledoc "Installs small core constructors that do not need dedicated installer modules."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime.Boolean
  alias QuickBEAM.VM.Runtime.DataView
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors
  alias QuickBEAM.VM.Runtime.InstallerHelpers
  alias QuickBEAM.VM.Runtime.Iterator
  alias QuickBEAM.VM.Runtime.PromiseBuiltins
  alias QuickBEAM.VM.Runtime.Symbol

  @doc "Returns global bindings for small core constructors."
  def bindings do
    big_int = ConstructorRegistry.register("BigInt", &Constructors.bigint/2, auto_proto: true)

    boolean =
      ConstructorRegistry.register("Boolean", Boolean.constructor(),
        module: Boolean,
        auto_proto: true
      )

    symbol =
      ConstructorRegistry.register("Symbol", Symbol.constructor(),
        module: Symbol,
        auto_proto: true
      )

    data_view =
      ConstructorRegistry.register("DataView", &DataView.constructor/2, auto_proto: true)

    Heap.put_ctor_static(data_view, "length", 1)
    Heap.put_ctor_prop_desc(data_view, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(data_view, "prototype", PropertyDescriptor.prototype())

    install_plain_prototype(big_int)
    install_boolean_prototype(boolean)
    install_plain_prototype(symbol)
    install_data_view_prototype(data_view)

    promise =
      ConstructorRegistry.register("Promise", PromiseBuiltins.constructor(),
        module: PromiseBuiltins,
        prototype: PromiseBuiltins.prototype()
      )

    Heap.put_ctor_prop_desc(promise, "prototype", PropertyDescriptor.prototype())
    install_promise_prototype(promise)
    InstallerHelpers.install_species(promise)

    iterator =
      ConstructorRegistry.register("Iterator", Iterator.constructor(),
        module: Iterator,
        auto_proto: true,
        prototype_parent: Heap.get_object_prototype()
      )

    install_iterator(iterator)

    %{
      "BigInt" => big_int,
      "Boolean" => boolean,
      "Iterator" => iterator,
      "Promise" => promise,
      "Symbol" => symbol,
      "DataView" => data_view
    }
  end

  defp install_plain_prototype(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref)
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
    end)
  end

  defp install_boolean_prototype(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref)
      InstallerHelpers.install_methods(proto_ref, Boolean, ~w(toString valueOf))
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
    end)
  end

  defp install_data_view_prototype(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref)
      InstallerHelpers.install_constructor_link(proto_ref, ctor)

      for name <- ~w(buffer byteLength byteOffset) do
        Heap.put_obj_key(proto_ref, name, DataView.accessor(name))
        Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.accessor())
      end

      InstallerHelpers.install_methods(proto_ref, DataView, DataView.proto_property_names())
      InstallerHelpers.install_to_string_tag(proto_ref, "DataView")
    end)
  end

  defp install_iterator(ctor) do
    for name <- ~w(concat from zip zipKeyed) do
      Heap.put_ctor_static(ctor, name, Iterator.static_property(name))
      Heap.put_ctor_prop_desc(ctor, name, PropertyDescriptor.method())
    end

    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      Heap.put_obj_key(proto_ref, "constructor", Iterator.proto_property("constructor"))
      Heap.put_prop_desc(proto_ref, "constructor", PropertyDescriptor.accessor())

      InstallerHelpers.install_methods(
        proto_ref,
        Iterator,
        ~w(drop filter flatMap forEach map reduce some take toArray every find)
      )

      InstallerHelpers.install_symbol_iterator(proto_ref, Iterator)
      Heap.put_obj_key(proto_ref, {:symbol, "Symbol.dispose"}, Iterator.proto_property({:symbol, "Symbol.dispose"}))
      Heap.put_prop_desc(proto_ref, {:symbol, "Symbol.dispose"}, PropertyDescriptor.method())
      Heap.put_obj_key(proto_ref, {:symbol, "Symbol.toStringTag"}, Iterator.proto_property({:symbol, "Symbol.toStringTag"}))
      Heap.put_prop_desc(proto_ref, {:symbol, "Symbol.toStringTag"}, PropertyDescriptor.accessor())
    end)
  end

  defp install_promise_prototype(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref)

      for name <- ~w(then catch finally) do
        Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.method())
      end

      InstallerHelpers.install_to_string_tag(proto_ref, "Promise")
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
    end)
  end
end
