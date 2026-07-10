defmodule QuickBEAM.VM.Promise do
  @moduledoc false

  alias QuickBEAM.VM.{Execution, PromiseReference}

  @type state :: :pending | {:fulfilled, term()} | {:rejected, term()}

  @spec new(Execution.t()) :: {PromiseReference.t(), Execution.t()}
  def new(%Execution{} = execution) do
    id = execution.next_promise_id
    reference = %PromiseReference{id: id}

    execution = %{
      execution
      | next_promise_id: id + 1,
        promises: Map.put(execution.promises, id, :pending)
    }

    {reference, execution}
  end

  @spec state(Execution.t(), PromiseReference.t()) :: state()
  def state(%Execution{} = execution, %PromiseReference{id: id}),
    do: Map.fetch!(execution.promises, id)

  @spec settle(Execution.t(), PromiseReference.t(), {:ok, term()} | {:error, term()}) ::
          Execution.t()
  def settle(%Execution{} = execution, %PromiseReference{id: id}, result) do
    state =
      case result do
        {:ok, value} -> {:fulfilled, value}
        {:error, reason} -> {:rejected, reason}
      end

    case Map.fetch!(execution.promises, id) do
      :pending -> %{execution | promises: Map.put(execution.promises, id, state)}
      _settled -> execution
    end
  end
end
