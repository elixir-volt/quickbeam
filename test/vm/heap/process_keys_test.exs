defmodule QuickBEAM.VM.Heap.ProcessKeysTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Execution.IteratorState
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Heap.ProcessKeys
  alias QuickBEAM.VM.Host.Web.Worker.State, as: WorkerState

  test "owned? classifies heap process dictionary keys" do
    assert ProcessKeys.owned?(1)
    refute ProcessKeys.owned?(make_ref())
    assert ProcessKeys.owned?(:qb_ctx)
    assert ProcessKeys.owned?({:qb_prop_desc, 1, "a"})
    assert ProcessKeys.owned?({:qb_iterator_state, make_ref()})
    assert ProcessKeys.owned?({:qb_worker_listeners, make_ref()})

    refute ProcessKeys.owned?(0)
    refute ProcessKeys.owned?(:not_quickbeam)
    refute ProcessKeys.owned?(QuickBEAM.VM.Heap)
    refute ProcessKeys.owned?({"qb_not_an_atom", 1})
  end

  test "Heap.reset removes reference-backed VM state stored under owned keys" do
    iterator_ref = IteratorState.new({[1, 2], 0})
    onmessage_ref = make_ref()
    onerror_ref = make_ref()
    listeners_ref = make_ref()

    WorkerState.init_callbacks(onmessage_ref, onerror_ref, listeners_ref)
    WorkerState.put_listener_callback(onmessage_ref, :callback)
    WorkerState.put_error_callback(onerror_ref, :error_callback)
    WorkerState.add_listener(listeners_ref, :listener)

    assert Process.get({:qb_iterator_state, iterator_ref}) == {[1, 2], 0}
    assert Process.get({:qb_worker_onmessage, onmessage_ref}) == :callback
    assert Process.get({:qb_worker_onerror, onerror_ref}) == :error_callback
    assert Process.get({:qb_worker_listeners, listeners_ref}) == [:listener]

    assert Heap.reset() == :ok

    refute Process.get({:qb_iterator_state, iterator_ref})
    refute Process.get({:qb_worker_onmessage, onmessage_ref})
    refute Process.get({:qb_worker_onerror, onerror_ref})
    refute Process.get({:qb_worker_listeners, listeners_ref})
  end

  test "Heap.snapshot and restore include reference-backed VM state" do
    iterator_ref = IteratorState.new({[:original], 0})
    listeners_ref = make_ref()
    WorkerState.init_callbacks(make_ref(), make_ref(), listeners_ref)
    WorkerState.add_listener(listeners_ref, :original)

    snapshot = Heap.snapshot()

    IteratorState.put(iterator_ref, {[:changed], 1})
    WorkerState.add_listener(listeners_ref, :changed)

    assert Heap.restore(snapshot) == :ok
    assert IteratorState.get(iterator_ref, nil) == {[:original], 0}
    assert WorkerState.listeners(listeners_ref) == [:original]
  end

  test "Heap.reset removes registered heap keys only" do
    heap_ref = make_ref()
    external_ref = make_ref()

    Process.put(:qb_ctx, :ctx)
    Process.put({:qb_prop_desc, 1, "a"}, :desc)
    Process.put(123, :object)
    Process.put(heap_ref, %{"heap" => true})
    Process.put(external_ref, true)
    Process.put(:not_quickbeam, :keep)

    assert Heap.reset() == :ok

    refute Process.get(:qb_ctx)
    refute Process.get({:qb_prop_desc, 1, "a"})
    refute Process.get(123)
    assert Process.get(heap_ref) == %{"heap" => true}
    assert Process.get(external_ref) == true
    assert Process.get(:not_quickbeam) == :keep
  after
    Process.delete(:not_quickbeam)
  end
end
