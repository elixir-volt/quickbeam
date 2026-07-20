defmodule QuickBEAM.VM.Runtime.Memory do
  @moduledoc """
  Performs conservative logical memory accounting for VM allocations.

  Accounting is monotonic until garbage collection is implemented and provides
  controlled limit failures before the worker's process heap ceiling.
  """

  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.State

  @object_bytes 128
  @property_bytes 64
  @cell_bytes 32
  @promise_bytes 64

  @doc "Charges an exact number of logical bytes to an evaluation."
  @spec charge(State.t(), non_neg_integer()) :: State.t()
  def charge(%State{} = execution, bytes) when is_integer(bytes) and bytes >= 0 do
    used = execution.memory_used + bytes

    exceeded =
      execution.memory_exceeded or
        (execution.memory_limit != :infinity and used > execution.memory_limit)

    %{execution | memory_used: used, memory_exceeded: exceeded}
  end

  @doc "Charges allocation of one object value."
  def charge_object(execution, object), do: charge(execution, @object_bytes + estimate(object))

  @doc "Charges allocation of one property key and value."
  def charge_property(execution, key, value),
    do: charge(execution, @property_bytes + estimate(key) + estimate(value))

  @doc "Charges allocation of one captured mutable cell."
  def charge_cell(execution, value), do: charge(execution, @cell_bytes + estimate(value))

  @doc "Charges allocation of one Promise record."
  def charge_promise(execution), do: charge(execution, @promise_bytes)

  @doc "Returns the deterministic logical-size estimate for a VM value."
  @spec estimate(term()) :: non_neg_integer()
  def estimate(value) when value in [nil, true, false, :undefined], do: 8
  def estimate(value) when is_integer(value) or is_float(value), do: 16
  def estimate(value) when is_binary(value), do: 16 + byte_size(value)
  def estimate(value) when is_atom(value), do: 8
  def estimate(value) when is_pid(value) or is_reference(value) or is_function(value), do: 16
  def estimate(%QuickBEAM.VM.Runtime.Reference{}), do: 16
  def estimate(%QuickBEAM.VM.Runtime.Promise.Reference{}), do: 16
  def estimate(%QuickBEAM.VM.Program.Function{}), do: 16

  def estimate(%Object{} = object) do
    464 +
      estimate(object.prototype) +
      estimate(object.properties) +
      estimate(object.property_order) +
      estimate(object.callable) +
      estimate(object.internal)
  end

  def estimate({first, second}), do: 16 + estimate(first) + estimate(second)

  def estimate({first, second, third}),
    do: 16 + estimate(first) + estimate(second) + estimate(third)

  def estimate({first, second, third, fourth}),
    do: 16 + estimate(first) + estimate(second) + estimate(third) + estimate(fourth)

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
