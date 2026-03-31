defmodule QuickBEAM.WASM do
  @moduledoc """
  WebAssembly runtime for the BEAM.

  Compile `.wasm` binaries and run them as supervised WASM instances,
  or use `disasm/1` to decode them into structured Elixir data.

  ## Quick start

      wasm = File.read!("add.wasm")
      {:ok, pid} = QuickBEAM.WASM.start(module: wasm)
      {:ok, 42} = QuickBEAM.WASM.call(pid, "add", [40, 2])
      QuickBEAM.WASM.stop(pid)

  ## Supervision

      children = [
        {QuickBEAM.WASM, name: :renderer, module: File.read!("priv/wasm/md.wasm")}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      QuickBEAM.WASM.call(:renderer, "render", [...])

  ## Disassembly

      {:ok, mod} = QuickBEAM.WASM.disasm(wasm_bytes)
      hd(mod.functions).opcodes
      # [{0, :local_get, 0}, {2, :local_get, 1}, {4, :i32_add}, {5, :end}]

  ## Options

    * `:module` — WASM binary (required)
    * `:name` — GenServer name registration
    * `:stack_size` — execution stack in bytes (default: 65536)
    * `:heap_size` — auxiliary heap in bytes (default: 65536)
  """

  @type instance :: GenServer.server()

  alias QuickBEAM.WASM.{Module, Parser}

  @doc false
  def child_spec(opts) do
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))
    %{id: id, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Start a WASM instance.

      {:ok, pid} = QuickBEAM.WASM.start(module: wasm_bytes)
      {:ok, 42} = QuickBEAM.WASM.call(pid, "add", [40, 2])
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    QuickBEAM.WASM.Server.start_link(opts)
  end

  @doc """
  Start a WASM instance linked to the calling process.

  Same as `start/1` — the instance is always linked. Use in supervision
  trees via `child_spec/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    QuickBEAM.WASM.Server.start_link(opts)
  end

  @doc """
  Call an exported WASM function by name.

      {:ok, 42} = QuickBEAM.WASM.call(pid, "add", [40, 2])
  """
  @spec call(instance(), String.t(), [integer()]) :: {:ok, integer()} | {:error, String.t()}
  def call(instance, func_name, params \\ []) do
    GenServer.call(instance, {:call, func_name, params}, :infinity)
  end

  @doc "Stop a WASM instance."
  @spec stop(instance()) :: :ok
  def stop(instance) do
    GenServer.stop(instance)
  end

  @doc """
  Get the current memory size of a WASM instance in bytes.
  """
  @spec memory_size(instance()) :: {:ok, non_neg_integer()}
  def memory_size(instance) do
    GenServer.call(instance, :memory_size, :infinity)
  end

  @doc """
  Grow the memory of a WASM instance by `delta` pages (64KB each).
  """
  @spec memory_grow(instance(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def memory_grow(instance, delta) do
    GenServer.call(instance, {:memory_grow, delta}, :infinity)
  end

  @doc """
  Read bytes from a WASM instance's linear memory.
  """
  @spec read_memory(instance(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, String.t()}
  def read_memory(instance, offset, length) do
    GenServer.call(instance, {:read_memory, offset, length}, :infinity)
  end

  @doc """
  Write bytes to a WASM instance's linear memory.
  """
  @spec write_memory(instance(), non_neg_integer(), binary()) :: :ok | {:error, String.t()}
  def write_memory(instance, offset, data) do
    GenServer.call(instance, {:write_memory, offset, data}, :infinity)
  end

  @doc """
  Compile a `.wasm` binary. Returns a NIF resource for internal use.
  """
  @doc false
  @spec compile(binary()) :: {:ok, reference()} | {:error, String.t()}
  def compile(wasm_bytes) when is_binary(wasm_bytes) do
    QuickBEAM.Native.wasm_compile(wasm_bytes)
  end

  @doc """
  Disassemble a `.wasm` binary into a `%QuickBEAM.WASM.Module{}` struct.

  Decodes all sections including function bodies with opcodes. Does not
  require a running instance.

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

      QuickBEAM.WASM.validate(File.read!("add.wasm"))  # => true
      QuickBEAM.WASM.validate("not wasm")               # => false
  """
  @spec validate(binary()) :: boolean()
  def validate(wasm_bytes) when is_binary(wasm_bytes) do
    Parser.validate(wasm_bytes)
  end

  @doc """
  List exports from a `.wasm` binary or a parsed module.
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
