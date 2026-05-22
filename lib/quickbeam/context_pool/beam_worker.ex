defmodule QuickBEAM.ContextPool.BEAMWorker do
  @moduledoc false

  use GenServer

  alias QuickBEAM.VM.Heap

  defstruct [:runtime, :mode, snapshots: %{}]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def eval(worker, code, timeout, filename) do
    GenServer.call(worker, {:eval, code, timeout, filename}, :infinity)
  end

  def eval_restore(worker, name, code, timeout, filename) do
    GenServer.call(worker, {:eval_restore, name, code, timeout, filename}, :infinity)
  end

  def reset(worker) do
    GenServer.call(worker, :reset, :infinity)
  end

  def snapshot(worker, name) do
    GenServer.call(worker, {:snapshot, name}, :infinity)
  end

  def restore(worker, name) do
    GenServer.call(worker, {:restore, name}, :infinity)
  end

  @impl true
  def init(opts) do
    mode = Keyword.fetch!(opts, :mode)
    {:ok, runtime} = QuickBEAM.start(apis: false, mode: mode)
    Heap.reset()
    {:ok, %__MODULE__{runtime: runtime, mode: mode, snapshots: %{}}}
  end

  @impl true
  def handle_call({:eval, code, timeout, filename}, _from, state) do
    {:reply, eval_code(state, code, timeout, filename), state}
  end

  def handle_call({:eval_restore, name, code, timeout, filename}, _from, state) do
    result =
      with :ok <- restore_snapshot(state, name) do
        eval_code(state, code, timeout, filename)
      end

    {:reply, result, state}
  end

  def handle_call(:reset, _from, state) do
    Heap.reset()
    result = QuickBEAM.reset(state.runtime)
    {:reply, result, state}
  end

  def handle_call({:snapshot, name}, _from, state) do
    {:reply, :ok, %{state | snapshots: Map.put(state.snapshots, name, Heap.snapshot())}}
  end

  def handle_call({:restore, name}, _from, state) do
    {:reply, restore_snapshot(state, name), state}
  end

  defp eval_code(state, code, timeout, filename) do
    opts = [mode: state.mode, timeout: timeout, filename: filename]
    normalize_result(QuickBEAM.eval(state.runtime, code, opts))
  end

  defp restore_snapshot(state, name) do
    case Map.fetch(state.snapshots, name) do
      {:ok, snapshot} -> Heap.restore(snapshot)
      :error -> {:error, :snapshot_not_found}
    end
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
