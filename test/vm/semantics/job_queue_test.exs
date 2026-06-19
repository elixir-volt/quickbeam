defmodule QuickBEAM.VM.Semantics.JobQueueTest do
  use ExUnit.Case, async: true

  import QuickBEAM.VM.Heap.Keys, only: [promise_state: 0, promise_value: 0]

  alias QuickBEAM.VM.{Heap, JobQueue, Promise}

  setup do
    Heap.reset()
    :ok
  end

  test "drains fire-and-forget microtasks" do
    parent = self()

    JobQueue.enqueue_promise_reaction(
      nil,
      {:builtin, "record",
       fn [value | _], _ ->
         send(parent, {:job_value, value})
         :undefined
       end},
      42
    )

    assert :ok = JobQueue.drain_microtasks()
    assert_receive {:job_value, 42}
  end

  test "settles promise reaction children" do
    {:obj, child_ref} = Promise.pending()

    JobQueue.enqueue_promise_reaction(
      child_ref,
      {:builtin, "double", fn [value | _], _ -> value * 2 end},
      21
    )

    assert :ok = JobQueue.drain_microtasks()
    assert %{promise_state() => :resolved, promise_value() => 42} = Heap.get_obj(child_ref)
  end

  test "uses callback invocation semantics for thrown JavaScript callbacks" do
    {:obj, child_ref} = Promise.pending()
    error = Heap.make_error("boom", "TypeError")

    JobQueue.enqueue_promise_reaction(
      child_ref,
      {:builtin, "thrower", fn _, _ -> throw({:js_throw, error}) end},
      13
    )

    assert :ok = JobQueue.drain_microtasks()
    assert %{promise_state() => :resolved, promise_value() => 13} = Heap.get_obj(child_ref)
  end
end
