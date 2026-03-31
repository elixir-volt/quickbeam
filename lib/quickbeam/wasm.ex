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
  Compile a `.wasm` binary into a loaded WASM module.

  The module can be passed to `start/2` to create an instance.
  Modules can be compiled once and started many times.

      {:ok, module} = QuickBEAM.WASM.compile(File.read!("add.wasm"))
  """
  @spec compile(binary()) :: {:ok, reference()} | {:error, String.t()}
  def compile(wasm_bytes) when is_binary(wasm_bytes) do
    QuickBEAM.Native.wasm_compile(wasm_bytes)
  end

  @doc """
  Start a WASM instance from a compiled module.

  Returns a resource that can be passed to `call/3`, `read_memory/3`, etc.

  ## Options

    * `:stack_size` — execution stack in bytes (default: 65536)
    * `:heap_size` — auxiliary heap in bytes (default: 65536)

  ## Examples

      {:ok, mod} = QuickBEAM.WASM.compile(wasm_bytes)
      {:ok, inst} = QuickBEAM.WASM.start(mod)
      {:ok, 42} = QuickBEAM.WASM.call(inst, "add", [40, 2])
      QuickBEAM.WASM.stop(inst)
  """
  @spec start(reference(), keyword()) :: {:ok, reference()} | {:error, String.t()}
  def start(module, opts \\ []) do
    stack_size = Keyword.get(opts, :stack_size, 65_536)
    heap_size = Keyword.get(opts, :heap_size, 65_536)
    QuickBEAM.Native.wasm_start(module, stack_size, heap_size)
  end

  @doc """
  Stop a WASM instance and free its resources.
  """
  @spec stop(reference()) :: :ok
  def stop(instance) do
    QuickBEAM.Native.wasm_stop(instance)
  end

  @doc """
  Call an exported WASM function by name.

  Parameters and return values are i32 integers.

      {:ok, mod} = QuickBEAM.WASM.compile(wasm_bytes)
      {:ok, inst} = QuickBEAM.WASM.start(mod)
      {:ok, 42} = QuickBEAM.WASM.call(inst, "add", [40, 2])
  """
  @spec call(reference(), String.t(), [integer()]) :: {:ok, integer()} | {:error, String.t()}
  def call(instance, func_name, params \\ []) do
    QuickBEAM.Native.wasm_call(instance, func_name, params)
  end

  @doc """
  Get the current memory size of a WASM instance in bytes.
  """
  @spec memory_size(reference()) :: {:ok, non_neg_integer()}
  def memory_size(instance) do
    QuickBEAM.Native.wasm_memory_size(instance)
  end

  @doc """
  Grow the memory of a WASM instance by `delta` pages (64KB each).

  Returns `{:ok, previous_page_count}` on success.
  """
  @spec memory_grow(reference(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def memory_grow(instance, delta) do
    QuickBEAM.Native.wasm_memory_grow(instance, delta)
  end

  @doc """
  Read bytes from a WASM instance's linear memory.

      {:ok, data} = QuickBEAM.WASM.read_memory(instance, 0, 5)
  """
  @spec read_memory(reference(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, String.t()}
  def read_memory(instance, offset, length) do
    QuickBEAM.Native.wasm_read_memory(instance, offset, length)
  end

  @doc """
  Write bytes to a WASM instance's linear memory.

      :ok = QuickBEAM.WASM.write_memory(instance, 0, "hello")
  """
  @spec write_memory(reference(), non_neg_integer(), binary()) :: :ok | {:error, String.t()}
  def write_memory(instance, offset, data) do
    QuickBEAM.Native.wasm_write_memory(instance, offset, data)
  end

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
