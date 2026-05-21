defmodule QuickBEAM.VM.Runtime.BigInt do
  @moduledoc "JavaScript `BigInt` constructor installation metadata."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Runtime.InstallerHelpers

  builtin_definition("BigInt",
    constructor: &QuickBEAM.VM.Runtime.Globals.Constructors.bigint/2,
    length: 1,
    phase: :fundamental,
    constructable: false,
    after_install: &__MODULE__.install_builtin/1
  )

  def install_builtin(ctor) do
    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref)
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
      InstallerHelpers.install_to_string_tag(proto_ref, "BigInt")
    end)
  end
end
