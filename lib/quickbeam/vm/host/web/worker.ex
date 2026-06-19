defmodule QuickBEAM.VM.Host.Web.Worker do
  @moduledoc "Worker constructor for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, object: 2]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.Callback
  alias QuickBEAM.VM.Host.Web.Worker.State
  alias QuickBEAM.VM.Host.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{"Worker" => WebAPIs.register("Worker", &build_worker/2)}
  end

  defp build_worker([script | _], _this) do
    script_str =
      case script do
        s when is_binary(s) -> s
        _ -> to_string(script)
      end

    parent_pid = self()
    worker_ref = make_ref()

    onmessage_ref = make_ref()
    onerror_ref = make_ref()
    listeners_ref = make_ref()

    State.init_callbacks(onmessage_ref, onerror_ref, listeners_ref)

    # Spawn the worker process
    worker_pid = spawn_worker(script_str, parent_pid, worker_ref)

    State.register_worker(worker_ref, worker_pid)

    # Register as a "message source" to be polled during drain_pending
    register_worker_source(worker_ref, onmessage_ref, listeners_ref)

    object heap: true do
      method "postMessage" do
        data = arg(args, 0, :undefined)

        case State.worker_pid(worker_ref) do
          pid when is_pid(pid) -> send(pid, {:parent_post, data})
          _ -> :ok
        end

        :undefined
      end

      method "terminate" do
        case State.worker_pid(worker_ref) do
          pid when is_pid(pid) ->
            Process.exit(pid, :kill)
            State.delete_worker(worker_ref)

          _ ->
            :ok
        end

        unregister_worker_source(worker_ref)
        :undefined
      end

      method "addEventListener" do
        [type, callback] = argv(args, ["message", nil])

        if to_string(type) == "message" do
          State.add_listener(listeners_ref, callback)
        end

        :undefined
      end

      method "removeEventListener" do
        [_type, callback] = argv(args, ["message", nil])
        State.remove_listener(listeners_ref, callback)
        :undefined
      end

      accessor "onmessage" do
        get do
          State.listener_callback(onmessage_ref)
        end

        set do
          State.put_listener_callback(onmessage_ref, arg(args, 0, nil))
          :undefined
        end
      end

      accessor "onerror" do
        get do
          State.error_callback(onerror_ref)
        end

        set do
          State.put_error_callback(onerror_ref, arg(args, 0, nil))
          :undefined
        end
      end
    end
  end

  # ── Worker message sources (polled during drain_pending) ──

  defp register_worker_source(worker_ref, onmessage_ref, listeners_ref),
    do: State.register_source(worker_ref, onmessage_ref, listeners_ref)

  defp unregister_worker_source(worker_ref), do: State.unregister_source(worker_ref)

  @doc "Drain all pending worker messages. Called from drain_pending loop."
  def drain_all_worker_messages do
    Enum.each(State.sources(), fn {worker_ref, onmessage_ref, listeners_ref} ->
      drain_worker_source(worker_ref, onmessage_ref, listeners_ref)
    end)
  end

  defp drain_worker_source(worker_ref, onmessage_ref, listeners_ref) do
    receive do
      {:worker_msg_to_parent, ^worker_ref, data} ->
        deliver_to_handlers(data, onmessage_ref, listeners_ref)
        drain_worker_source(worker_ref, onmessage_ref, listeners_ref)
    after
      0 -> :ok
    end
  end

  defp deliver_to_handlers(data, onmessage_ref, listeners_ref) do
    handler = State.listener_callback(onmessage_ref)
    listeners = State.listeners(listeners_ref)
    event = Heap.wrap(%{"type" => "message", "data" => data})

    if handler != nil and handler != :undefined do
      Callback.safe_invoke(handler, [event])
    end

    Enum.each(listeners, &Callback.safe_invoke(&1, [event]))
  end

  # ── Worker process ──

  defp spawn_worker(script, parent_pid, worker_ref) do
    spawn(fn ->
      QuickBEAM.VM.Heap.reset()

      {:ok, child_rt} =
        QuickBEAM.start(
          mode: :beam,
          handlers: %{
            "__worker_post" => fn [data] ->
              send(parent_pid, {:worker_msg_to_parent, worker_ref, data})
              nil
            end
          }
        )

      bootstrap = """
      globalThis.self = globalThis;
      self.postMessage = function(data) {
        Beam.call("__worker_post", data);
      };
      self.close = function() {};
      // Handle messages from parent via Beam.onMessage
      Beam.onMessage(function(data) {
        if (typeof self.onmessage === 'function') {
          self.onmessage({ data: data, type: 'message' });
        }
      });
      """

      QuickBEAM.eval(child_rt, bootstrap)

      # Run the worker script
      QuickBEAM.eval(child_rt, script)

      # Keep alive to handle parent postMessage
      worker_loop(child_rt)
    end)
  end

  defp worker_loop(child_rt) do
    receive do
      {:parent_post, data} ->
        # Deliver message to worker's onmessage handler
        # Store data as a global, then call onmessage
        store_and_deliver(child_rt, data)
        worker_loop(child_rt)

      :terminate ->
        QuickBEAM.stop(child_rt)
    after
      30_000 ->
        QuickBEAM.stop(child_rt)
    end
  end

  defp store_and_deliver(_child_rt, data) do
    alias QuickBEAM.VM.Host.BEAM
    BEAM.deliver_beam_message(data)
  end
end
