defmodule QuickBEAM.WASM.Server do
  @moduledoc false

  use GenServer

  defstruct [:module_ref, :instance_ref]

  def start_link(opts) do
    {gen_opts, wasm_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, wasm_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    wasm_bytes = Keyword.fetch!(opts, :module)
    stack_size = Keyword.get(opts, :stack_size, 65_536)
    heap_size = Keyword.get(opts, :heap_size, 65_536)

    with {:ok, mod_ref} <- QuickBEAM.Native.wasm_compile(wasm_bytes),
         {:ok, inst_ref} <- QuickBEAM.Native.wasm_start(mod_ref, stack_size, heap_size) do
      {:ok, %__MODULE__{module_ref: mod_ref, instance_ref: inst_ref}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call, func_name, params}, _from, state) do
    {:reply, QuickBEAM.Native.wasm_call(state.instance_ref, func_name, params), state}
  end

  def handle_call(:memory_size, _from, state) do
    {:reply, QuickBEAM.Native.wasm_memory_size(state.instance_ref), state}
  end

  def handle_call({:memory_grow, delta}, _from, state) do
    {:reply, QuickBEAM.Native.wasm_memory_grow(state.instance_ref, delta), state}
  end

  def handle_call({:read_memory, offset, length}, _from, state) do
    {:reply, QuickBEAM.Native.wasm_read_memory(state.instance_ref, offset, length), state}
  end

  def handle_call({:write_memory, offset, data}, _from, state) do
    {:reply, QuickBEAM.Native.wasm_write_memory(state.instance_ref, offset, data), state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.instance_ref, do: QuickBEAM.Native.wasm_stop(state.instance_ref)
    :ok
  end
end
