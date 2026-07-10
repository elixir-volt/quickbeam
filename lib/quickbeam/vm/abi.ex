defmodule QuickBEAM.VM.ABI do
  @moduledoc """
  Build fingerprint and generated metadata for the vendored QuickJS bytecode ABI.

  QuickJS bytecode is private to one engine build. These values are generated
  from the same vendored C sources used by the native library so header changes
  cannot silently leave a hand-maintained decoder table behind.
  """

  alias QuickBEAM.VM.ABIGenerator

  @decoder_format_version 1
  @c_src_dir Application.app_dir(:quickbeam, "priv/c_src")
  @quickjs_path Path.join(@c_src_dir, "quickjs.c")
  @opcode_path Path.join(@c_src_dir, "quickjs-opcode.h")
  @atom_path Path.join(@c_src_dir, "quickjs-atom.h")

  @external_resource @quickjs_path
  @external_resource @opcode_path
  @external_resource @atom_path

  @quickjs_source File.read!(@quickjs_path)
  @opcode_source File.read!(@opcode_path)
  @atom_source File.read!(@atom_path)

  @bytecode_version ABIGenerator.version!(@quickjs_source)
  @tags ABIGenerator.tags!(@quickjs_source)
  @opcodes ABIGenerator.opcodes!(@opcode_source)
  @atoms ABIGenerator.atoms!(@atom_source)
  @fingerprint ABIGenerator.fingerprint(
                 @bytecode_version,
                 @decoder_format_version,
                 [@quickjs_source, @opcode_source, @atom_source]
               )

  @doc "Returns QuickBEAM's decoded-program format version."
  def decoder_format_version, do: @decoder_format_version

  @doc "Returns the bytecode version from the vendored QuickJS source."
  def bytecode_version, do: @bytecode_version

  @doc "Returns a fingerprint for the exact vendored QuickJS bytecode ABI."
  def fingerprint, do: @fingerprint

  @doc false
  def tags, do: @tags

  @doc false
  def opcodes, do: @opcodes

  @doc false
  def predefined_atoms, do: @atoms
end
