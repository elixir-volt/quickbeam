defmodule QuickBEAM.VM.Runtime.RegExpInstaller do
  @moduledoc "Installs the RegExp constructor, prototype methods, accessors, and symbol hooks."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors
  alias QuickBEAM.VM.Runtime.InstallerHelpers
  alias QuickBEAM.VM.Runtime.RegExp

  @accessors ~w(source flags hasIndices global ignoreCase multiline dotAll unicode unicodeSets sticky)
  @methods ~w(exec test toString)
  @symbol_methods [
    {:symbol, "Symbol.match"},
    {:symbol, "Symbol.matchAll"},
    {:symbol, "Symbol.replace"},
    {:symbol, "Symbol.search"},
    {:symbol, "Symbol.split"}
  ]

  @doc "Returns the global RegExp constructor binding."
  def constructor do
    ctor =
      ConstructorRegistry.register("RegExp", &Constructors.regexp/2,
        module: RegExp,
        auto_proto: true
      )

    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
    install_prototype_methods(ctor)
    install_prototype_accessors(ctor)
    install_symbol_properties(ctor)
    ctor
  end

  defp install_prototype_methods(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_methods(proto_ref, RegExp, @methods)
    end)
  end

  defp install_prototype_accessors(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_accessors_with(proto_ref, @accessors, &RegExp.proto_accessor/1)
    end)
  end

  defp install_symbol_properties(ctor) do
    InstallerHelpers.install_species(ctor)

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_methods(proto_ref, RegExp, @symbol_methods)
    end)
  end
end
