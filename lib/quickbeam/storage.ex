defmodule QuickBEAM.Storage do
  @moduledoc false

  @table :quickbeam_local_storage

  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  @spec get_item([String.t()]) :: term() | nil
  def get_item([key]) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @spec set_item(list()) :: nil
  def set_item([key, value]) do
    :ets.insert(@table, {key, value})
    nil
  end

  @spec remove_item([String.t()]) :: nil
  def remove_item([key]) do
    :ets.delete(@table, key)
    nil
  end

  @spec clear(term()) :: nil
  def clear(_args) do
    :ets.delete_all_objects(@table)
    nil
  end

  @spec key([integer()]) :: String.t() | nil
  def key([index]) when is_integer(index) do
    keys = :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
    Enum.at(Enum.sort(keys), index)
  end

  def key(_), do: nil

  @spec length(term()) :: non_neg_integer()
  def length(_args) do
    :ets.info(@table, :size)
  end
end
