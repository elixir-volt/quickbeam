defmodule QuickBEAM.WorkerAPI do
  @moduledoc false

  @worker_bootstrap """
  globalThis.self = globalThis;
  self.postMessage = function(data) {
    Beam.call("__worker_post", data);
  };
  Object.defineProperty(self, "onmessage", {
    set(handler) {
      Beam.onMessage(msg => handler({ data: msg }));
    },
    configurable: true,
  });
  """

  @spec spawn_worker([String.t()], pid()) :: integer()
  def spawn_worker([script], parent_pid) do
    worker_id = System.unique_integer([:positive])

    {:ok, child} =
      QuickBEAM.start(
        handlers: %{
          "__worker_post" => fn [data] ->
            send(parent_pid, {:worker_msg, worker_id, data})
            nil
          end
        }
      )

    send(parent_pid, {:worker_register, worker_id, child})

    QuickBEAM.eval(child, @worker_bootstrap)

    Task.start(fn ->
      try do
        case QuickBEAM.eval(child, script) do
          {:ok, _} -> :ok
          {:error, err} -> send(parent_pid, {:worker_error, worker_id, err})
        end
      catch
        :exit, {:normal, _} -> :ok
        :exit, :normal -> :ok
      end
    end)

    worker_id
  end

  @spec post_to_child(list(), pid()) :: nil
  def post_to_child([worker_id, data], parent_pid) do
    send(parent_pid, {:worker_post_to_child, worker_id, data})
    nil
  end

  @spec terminate_worker([integer()], pid()) :: nil
  def terminate_worker([worker_id], parent_pid) do
    send(parent_pid, {:worker_terminate, worker_id})
    nil
  end
end
