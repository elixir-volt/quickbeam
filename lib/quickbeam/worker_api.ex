defmodule QuickBEAM.WorkerAPI do
  @moduledoc false

  @worker_bootstrap """
  globalThis.self = globalThis;
  const __parentPid = Beam.callSync("__worker_parent");
  self.postMessage = function(data) {
    Beam.send(__parentPid, ["__worker_msg", Beam.self(), data]);
  };
  Object.defineProperty(self, "onmessage", {
    set(handler) { Beam.onMessage(msg => {
      if (Array.isArray(msg) && msg[0] === "__worker_msg") {
        handler({ data: msg[1] });
      }
    }); },
    configurable: true,
  });
  """

  def spawn_worker([script], parent_pid) do
    {:ok, child} =
      QuickBEAM.start(
        handlers: %{
          "__worker_parent" => fn [] -> parent_pid end
        }
      )

    send(parent_pid, {:worker_monitor, child})

    QuickBEAM.eval(child, @worker_bootstrap)

    Task.start(fn ->
      case QuickBEAM.eval(child, script) do
        {:ok, _} -> :ok
        {:error, err} -> send(parent_pid, {:worker_error_from_child, child, err})
      end
    end)

    child
  end

  def terminate_worker([worker_pid]) do
    Task.start(fn -> QuickBEAM.stop(worker_pid) end)
    nil
  end
end
