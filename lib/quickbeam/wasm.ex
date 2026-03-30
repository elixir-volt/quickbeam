defmodule QuickBEAM.WASM do
  @moduledoc """
  WebAssembly binary parser and disassembler.

  Decodes `.wasm` binaries into structured Elixir data — types, imports,
  exports, function bodies with decoded opcodes, memories, tables, globals,
  and data segments. No runtime needed.

  ## Disassembly

  Opcodes use the same `{offset, name, ...operands}` tuple format as
  `QuickBEAM.Bytecode`:

      {:ok, mod} = QuickBEAM.WASM.disasm(wasm_bytes)
      [func | _] = mod.functions
      func.opcodes
      # [{0, :local_get, 0}, {2, :local_get, 1}, {4, :i32_add}, {5, :end}]

  ## Validation

      QuickBEAM.WASM.validate(wasm_bytes)  # => true | false

  ## Introspection

      QuickBEAM.WASM.exports(wasm_bytes)
      # [%{name: "add", kind: :func, index: 0}, ...]

      QuickBEAM.WASM.imports(wasm_bytes)
      # [%{module: "env", name: "log", kind: :func, type_idx: 1}]
  """

  alias QuickBEAM.WASM.{Module, Parser}

  @doc """
  Disassemble a `.wasm` binary into a `%QuickBEAM.WASM.Module{}` struct.

  Decodes all sections including function bodies with opcodes. Does not
  require a running runtime.

      {:ok, mod} = QuickBEAM.WASM.disasm(File.read!("add.wasm"))
      hd(mod.functions).opcodes
      # [{0, :local_get, 0}, {2, :local_get, 1}, {4, :i32_add}, {5, :end}]
  """
  @spec disasm(binary()) :: {:ok, Module.t()} | {:error, String.t()}
  def disasm(wasm_bytes) when is_binary(wasm_bytes) do
    Parser.parse(wasm_bytes)
  end

  @doc """
  Validate a `.wasm` binary (structural validation).

  Returns `true` if the binary can be successfully parsed as a WASM module,
  `false` otherwise.

      QuickBEAM.WASM.validate(File.read!("add.wasm"))  # => true
      QuickBEAM.WASM.validate("not wasm")               # => false
  """
  @spec validate(binary()) :: boolean()
  def validate(wasm_bytes) when is_binary(wasm_bytes) do
    Parser.validate(wasm_bytes)
  end

  @doc """
  List exports from a `.wasm` binary or a parsed module.

      QuickBEAM.WASM.exports(wasm_bytes)
      # [%{name: "add", kind: :func, index: 0},
      #  %{name: "memory", kind: :memory, index: 0}]
  """
  @spec exports(binary() | Module.t()) :: [Module.export_desc()] | {:error, String.t()}
  def exports(%Module{} = mod), do: mod.exports

  def exports(wasm_bytes) when is_binary(wasm_bytes) do
    case disasm(wasm_bytes) do
      {:ok, mod} -> mod.exports
      {:error, _} = err -> err
    end
  end

  @doc """
  List imports from a `.wasm` binary or a parsed module.

      QuickBEAM.WASM.imports(wasm_bytes)
      # [%{module: "env", name: "log", kind: :func, type_idx: 1}]
  """
  @spec imports(binary() | Module.t()) :: [Module.import_desc()] | {:error, String.t()}
  def imports(%Module{} = mod), do: mod.imports

  def imports(wasm_bytes) when is_binary(wasm_bytes) do
    case disasm(wasm_bytes) do
      {:ok, mod} -> mod.imports
      {:error, _} = err -> err
    end
  end
end
