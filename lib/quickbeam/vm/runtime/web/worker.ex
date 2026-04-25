defmodule QuickBEAM.VM.Runtime.Web.Worker do
  @moduledoc "Worker constructor for BEAM mode — runs in a separate QuickBEAM instance."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.Runtime.WebAPIs

  @workers_key :qb_beam_workers

  def bindings do
    %{"Worker" => WebAPIs.register("Worker", &build_worker/2)}
  end

  defp build_worker([script | _], _this) do
    parent_pid = self()
    worker_ref = make_ref()

    # Refs for message handlers
    onmessage_ref = make_ref()
    onerror_ref = make_ref()
    listeners_ref = make_ref()

    Heap.put_obj(onmessage_ref, nil)
    Heap.put_obj(onerror_ref, nil)
    Heap.put_obj(listeners_ref, [])

    script_str = case script do
      s when is_binary(s) -> s
      _ -> to_string(script)
    end

    worker_pid = spawn_worker(script_str, parent_pid, worker_ref, onmessage_ref, onerror_ref, listeners_ref)

    workers = Process.get(@workers_key, %{})
    Process.put(@workers_key, Map.put(workers, worker_ref, worker_pid))

    onmessage_acc = {:accessor,
      {:builtin, "get onmessage", fn _, _ -> Heap.get_obj(onmessage_ref, nil) end},
      {:builtin, "set onmessage", fn [h | _], _ ->
         Heap.put_obj(onmessage_ref, h)
         :undefined
       end}}

    onerror_acc = {:accessor,
      {:builtin, "get onerror", fn _, _ -> Heap.get_obj(onerror_ref, nil) end},
      {:builtin, "set onerror", fn [h | _], _ ->
         Heap.put_obj(onerror_ref, h)
         :undefined
       end}}

    methods = build_methods do
      method "postMessage" do
        [data | _] = args ++ [:undefined]
        workers = Process.get(@workers_key, %{})
        case Map.get(workers, worker_ref) do
          pid when is_pid(pid) ->
            send(pid, {:parent_message, data})
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
        :undefined
      end

      method "addEventListener" do
        [type, callback | _] = args ++ ["message", nil]
        if to_string(type) == "message" do
          listeners = Heap.get_obj(listeners_ref, [])
          Heap.put_obj(listeners_ref, listeners ++ [callback])
        end
        :undefined
      end

      method "removeEventListener" do
        [_type, callback | _] = args ++ ["message", nil]
        listeners = Heap.get_obj(listeners_ref, [])
        Heap.put_obj(listeners_ref, Enum.reject(listeners, &(&1 == callback)))
        :undefined
      end
    end

    Heap.wrap(Map.merge(methods, %{
      "onmessage" => onmessage_acc,
      "onerror" => onerror_acc
    }))
  end

  defp spawn_worker(script, parent_pid, worker_ref, onmessage_ref, onerror_ref, listeners_ref) do
    spawn(fn ->
      worker_self = self()

      # Bootstrap: create a child QuickBEAM VM
      {:ok, child_rt} =
        QuickBEAM.start(
          mode: :beam,
          handlers: %{
            "__worker_post" => fn [data] ->
              send(parent_pid, {:worker_msg, worker_ref, data})
              nil
            end
          }
        )

      # Install self.postMessage and self.onmessage in child
      bootstrap = """
      globalThis.self = globalThis;
      self.postMessage = function(data) {
        Beam.call("__worker_post", data);
      };
      self.close = function() {};
      Object.defineProperty(self, "onmessage", {
        set(handler) {
          Beam.onMessage(msg => {
            if (msg && msg.__worker_msg) {
              handler({ data: msg.data, type: "message" });
            }
          });
        },
        get() { return null; },
        configurable: true,
      });
      """

      QuickBEAM.eval(child_rt, bootstrap)

      # Run the worker script
      case QuickBEAM.eval(child_rt, script) do
        {:ok, _} -> :ok
        {:error, err} ->
          send(parent_pid, {:worker_error, worker_ref, err})
      end

      # Keep alive to receive postMessage from parent
      worker_loop(child_rt, parent_pid, worker_ref)
    end)
  end

  defp worker_loop(child_rt, parent_pid, worker_ref) do
    receive do
      {:parent_message, data} ->
        QuickBEAM.eval(child_rt, "typeof self.onmessage === 'function' && self.onmessage({data: #{Jason.encode!(to_json_safe(data))}, type: 'message'})")
        worker_loop(child_rt, parent_pid, worker_ref)

      :terminate ->
        QuickBEAM.stop(child_rt)
    after
      30_000 ->
        QuickBEAM.stop(child_rt)
    end
  end

  defp to_json_safe(val) when is_map(val) do
    Map.new(val, fn {k, v} -> {k, to_json_safe(v)} end)
  end
  defp to_json_safe(val) when is_list(val), do: Enum.map(val, &to_json_safe/1)
  defp to_json_safe(nil), do: nil
  defp to_json_safe(true), do: true
  defp to_json_safe(false), do: false
  defp to_json_safe(val) when is_binary(val), do: val
  defp to_json_safe(val) when is_number(val), do: val
  defp to_json_safe(_), do: nil

  # Handle incoming worker messages on the parent side
  # Called by the scheduler to deliver {:worker_msg, ref, data} to parent JS
  def deliver_message(worker_ref, data, onmessage_ref, onerror_ref, listeners_ref) do
    handler = Heap.get_obj(onmessage_ref, nil)
    listeners = Heap.get_obj(listeners_ref, [])

    event = Heap.wrap(%{"type" => "message", "data" => data})

    if handler != nil and handler != :undefined do
      try do
        Invocation.invoke_with_receiver(handler, [event], :undefined)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    Enum.each(listeners, fn cb ->
      try do
        Invocation.invoke_with_receiver(cb, [event], :undefined)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  end
end
