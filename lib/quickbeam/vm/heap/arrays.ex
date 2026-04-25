defmodule QuickBEAM.VM.Heap.Arrays do
  @moduledoc "Array storage operations for the JS object heap."

  def to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def to_list(list) when is_list(list), do: list

  def length({:qb_arr, arr}), do: :array.size(arr)
  def length(list) when is_list(list), do: Kernel.length(list)

  def get({:qb_arr, arr}, idx) when idx >= 0 do
    if idx < :array.size(arr), do: :array.get(idx, arr), else: :undefined
  end

  def get({:qb_arr, _}, _), do: :undefined
  def get(list, idx) when is_list(list) and idx >= 0, do: Enum.at(list, idx, :undefined)
  def get(_, _), do: :undefined

  def put({:qb_arr, arr}, idx, val), do: {:qb_arr, :array.set(idx, val, arr)}

  def put(list, idx, val) when is_list(list) and idx >= 0 and idx < Kernel.length(list),
    do: List.replace_at(list, idx, val)

  def put(list, idx, val) when is_list(list) and idx >= 0,
    do: list ++ List.duplicate(:undefined, idx - Kernel.length(list)) ++ [val]

  def array?({:qb_arr, _}), do: true
  def array?(list) when is_list(list), do: true
  def array?(_), do: false
end
