defmodule QuickBEAM.VM.Runtime.Web.Worker do
  @moduledoc "Worker constructor for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.Runtime.WebAPIs

  @workers_key :qb_beam_workers

  def bindings do
    %{"Worker" => WebAPIs.register("Worker", &build_worker/2)}
  end

  defp build_worker([script | _], _this) do
    script_str = case script do
      s when is_binary(s) -> s
      _ -> to_string(script)
    end

    parent_pid = self()
    worker_ref = make_ref()

    onmessage_ref = make_ref()
    onerror_ref = make_ref()
    listeners_ref = make_ref()

    # Use Process.put directly to avoid Heap.put_obj converting lists to {:qb_arr, ...}
    Process.put(onmessage_ref, nil)
    Process.put(onerror_ref, nil)
    Process.put(listeners_ref, [])

    # Spawn the worker process
    worker_pid = spawn_worker(script_str, parent_pid, worker_ref)

    workers = Process.get(@workers_key, %{})
    Process.put(@workers_key, Map.put(workers, worker_ref, worker_pid))

    # Register as a "message source" to be polled during drain_pending
    register_worker_source(worker_ref, onmessage_ref, listeners_ref)

    onmessage_acc = {:accessor,
      {:builtin, "get onmessage", fn _, _ -> Process.get(onmessage_ref, nil) end},
      {:builtin, "set onmessage", fn [h | _], _ ->
         Process.put(onmessage_ref, h)
         :undefined
       end}}

    onerror_acc = {:accessor,
      {:builtin, "get onerror", fn _, _ -> Process.get(onerror_ref, nil) end},
      {:builtin, "set onerror", fn [h | _], _ ->
         Process.put(onerror_ref, h)
         :undefined
       end}}

    methods = build_methods do
      method "postMessage" do
        [data | _] = args ++ [:undefined]
        workers = Process.get(@workers_key, %{})
        case Map.get(workers, worker_ref) do
          pid when is_pid(pid) ->
            send(pid, {:parent_post, data})
          _ -> :ok
        end
        :undefined
      end

      method "terminate" do
        workers = Process.get(@workers_key, %{})
        case Map.get(workers, worker_ref) do
          pid when is_pid(pid) ->
            Process.exit(pid, :kill)
            Process.put(@workers_key, Map.delete(workers, worker_ref))
          _ -> :ok
        end
        unregister_worker_source(worker_ref)
        :undefined
      end

      method "addEventListener" do
        [type, callback | _] = args ++ ["message", nil]
        if to_string(type) == "message" do
          listeners = Process.get(listeners_ref, [])
          Process.put(listeners_ref, listeners ++ [callback])
        end
        :undefined
      end

      method "removeEventListener" do
        [_type, callback | _] = args ++ ["message", nil]
        listeners = Process.get(listeners_ref, [])
        Process.put(listeners_ref, Enum.reject(listeners, &(&1 == callback)))
        :undefined
      end
    end

    Heap.wrap(Map.merge(methods, %{
      "onmessage" => onmessage_acc,
      "onerror" => onerror_acc
    }))
  end

  # ── Worker message sources (polled during drain_pending) ──

  @sources_key :qb_worker_sources

  defp register_worker_source(worker_ref, onmessage_ref, listeners_ref) do
    sources = Process.get(@sources_key, [])
    Process.put(@sources_key, sources ++ [{worker_ref, onmessage_ref, listeners_ref}])
  end

  defp unregister_worker_source(worker_ref) do
    sources = Process.get(@sources_key, [])
    Process.put(@sources_key, Enum.reject(sources, fn {ref, _, _} -> ref == worker_ref end))
  end

  @doc "Drain all pending worker messages. Called from drain_pending loop."
  def drain_all_worker_messages do
    sources = Process.get(@sources_key, [])
    Enum.each(sources, fn {worker_ref, onmessage_ref, listeners_ref} ->
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
    handler = Process.get(onmessage_ref, nil)
    listeners = Process.get(listeners_ref, [])
    event = Heap.wrap(%{"type" => "message", "data" => data})

    if handler != nil and handler != :undefined do
      safe_invoke(handler, [event])
    end

    Enum.each(listeners, fn cb -> safe_invoke(cb, [event]) end)
  end

  defp safe_invoke(cb, args) do
    try do
      Invocation.invoke_with_receiver(cb, args, :undefined)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
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
    alias QuickBEAM.VM.Runtime.Web.BeamAPI
    BeamAPI.deliver_beam_message(data)
  end
end
