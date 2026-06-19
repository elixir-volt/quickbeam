defmodule QuickBEAM.VM.Execution.RealmState do
  @moduledoc "Process-local association between realm intrinsics, realm globals, and functions."

  def put_global(realm_id, global) do
    Process.put(global_key(realm_id), global)
    :ok
  end

  def global(realm_id), do: Process.get(global_key(realm_id))

  def associate_intrinsics(function, intrinsics) do
    Process.put(intrinsics_key(function), intrinsics)
    :ok
  end

  def intrinsics(function), do: Process.get(intrinsics_key(function))

  def global_for(function) do
    case intrinsics(function) do
      %{realm_id: realm_id} -> global(realm_id)
      _ -> nil
    end
  end

  defp global_key(realm_id), do: {:qb_realm_global, realm_id}
  defp intrinsics_key(function), do: {:qb_intrinsics, function}
end
