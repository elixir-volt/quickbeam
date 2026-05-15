defmodule QuickBEAM.VM.Runtime.CoreConstructorInstaller do
  @moduledoc "Installs small core constructors that do not need dedicated installer modules."

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Boolean
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors
  alias QuickBEAM.VM.Runtime.InstallerHelpers
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
      ConstructorRegistry.register("DataView", fn _, _ -> Runtime.new_object() end,
        auto_proto: true
      )

    install_plain_prototype(big_int)
    install_boolean_prototype(boolean)
    install_plain_prototype(symbol)
    install_plain_prototype(data_view)

    promise =
      ConstructorRegistry.register("Promise", PromiseBuiltins.constructor(),
        module: PromiseBuiltins,
        prototype: PromiseBuiltins.prototype()
      )

    install_promise_prototype(promise)
    InstallerHelpers.install_species(promise)

    %{
      "BigInt" => big_int,
      "Boolean" => boolean,
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

  defp install_promise_prototype(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref)
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
    end)
  end
end
