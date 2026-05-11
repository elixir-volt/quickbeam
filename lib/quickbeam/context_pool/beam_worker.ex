defmodule QuickBEAM.ContextPool.BeamWorker do
  @moduledoc false

  use GenServer

  alias QuickBEAM.VM.Heap

  defstruct [:runtime, :mode]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def eval(worker, code, timeout, filename) do
    GenServer.call(worker, {:eval, code, timeout, filename}, :infinity)
  end

  def reset(worker) do
    GenServer.call(worker, :reset, :infinity)
  end

  @impl true
  def init(opts) do
    mode = Keyword.fetch!(opts, :mode)
    {:ok, runtime} = QuickBEAM.start(apis: false, mode: mode)
    Heap.reset()
    {:ok, %__MODULE__{runtime: runtime, mode: mode}}
  end

  @impl true
  def handle_call({:eval, code, timeout, filename}, _from, state) do
    opts = [mode: state.mode, timeout: timeout, filename: filename]
    {:reply, normalize_result(QuickBEAM.eval(state.runtime, code, opts)), state}
  end

  def handle_call(:reset, _from, state) do
    Heap.reset()
    result = QuickBEAM.reset(state.runtime)
    {:reply, result, state}
  end

  defp normalize_result({:error, %QuickBEAM.JS.Error{} = error}) do
    {:error, %{"message" => error.message, "name" => error.name, "stack" => error.stack}}
  end

  defp normalize_result(result), do: result

  @impl true
  def terminate(_reason, state) do
    if state.runtime, do: QuickBEAM.stop(state.runtime)
    :ok
  end
end
