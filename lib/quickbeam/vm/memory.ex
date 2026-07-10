defmodule QuickBEAM.VM.Memory do
  @moduledoc false

  alias QuickBEAM.VM.Execution

  @object_bytes 128
  @property_bytes 64
  @cell_bytes 32
  @promise_bytes 64

  @spec charge(Execution.t(), non_neg_integer()) :: Execution.t()
  def charge(%Execution{} = execution, bytes) when is_integer(bytes) and bytes >= 0 do
    used = execution.memory_used + bytes

    exceeded =
      execution.memory_exceeded or
        (execution.memory_limit != :infinity and used > execution.memory_limit)

    %{execution | memory_used: used, memory_exceeded: exceeded}
  end

  def charge_object(execution, object), do: charge(execution, @object_bytes + estimate(object))

  def charge_property(execution, key, value),
    do: charge(execution, @property_bytes + estimate(key) + estimate(value))

  def charge_cell(execution, value), do: charge(execution, @cell_bytes + estimate(value))
  def charge_promise(execution), do: charge(execution, @promise_bytes)

  @spec estimate(term()) :: non_neg_integer()
  def estimate(value) when value in [nil, true, false, :undefined], do: 8
  def estimate(value) when is_integer(value) or is_float(value), do: 16
  def estimate(value) when is_binary(value), do: 16 + byte_size(value)
  def estimate(value) when is_atom(value), do: 8
  def estimate(value) when is_pid(value) or is_reference(value) or is_function(value), do: 16
  def estimate(%QuickBEAM.VM.Reference{}), do: 16
  def estimate(%QuickBEAM.VM.PromiseReference{}), do: 16
  def estimate(%QuickBEAM.VM.Function{}), do: 16

  def estimate(value) when is_tuple(value) do
    16 + Enum.reduce(Tuple.to_list(value), 0, &(estimate(&1) + &2))
  end

  def estimate(value) when is_list(value) do
    Enum.reduce(value, 0, &(16 + estimate(&1) + &2))
  end

  def estimate(%_module{} = value), do: 32 + estimate(Map.from_struct(value))

  def estimate(value) when is_map(value) do
    Enum.reduce(value, 32, fn {key, child}, total ->
      total + 32 + estimate(key) + estimate(child)
    end)
  end

  def estimate(_value), do: 32
end
