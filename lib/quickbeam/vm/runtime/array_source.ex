defmodule QuickBEAM.VM.Runtime.ArraySource do
  @moduledoc "Indexed array-like source access for Array and iterator helpers."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, OwnProperty}
  alias QuickBEAM.VM.Runtime

  @max_safe_integer 9_007_199_254_740_991

  def new({:obj, _} = obj), do: {:object, obj}
  def new({:qb_arr, arr}), do: {:qb_arr, arr}
  def new({:tuple, tuple}), do: {:tuple, tuple}
  def new(list) when is_list(list), do: {:list, list}
  def new(value), do: {:value, value}

  def length(value), do: value |> new() |> source_length()

  def get(value, index), do: value |> new() |> source_get(index)

  defp source_length({:object, obj}), do: object_length(obj)
  defp source_length({:qb_arr, arr}), do: :array.size(arr)
  defp source_length({:tuple, tuple}), do: tuple_size(tuple)
  defp source_length({:list, list}), do: Kernel.length(list)
  defp source_length({:value, value}), do: to_length(Get.get(value, "length"))

  defp source_get({:object, value}, index) do
    key = Integer.to_string(index)
    current = Get.get(value, key)

    if current == :undefined and not OwnProperty.present?(value, key) do
      case InternalMethods.get_prototype_of(value) do
        {:obj, _} = proto -> Get.get(proto, key)
        _ -> current
      end
    else
      current
    end
  end

  defp source_get({:qb_arr, arr}, index), do: array_value_at(arr, index)
  defp source_get({:tuple, tuple}, index), do: tuple_value_at(tuple, index)
  defp source_get({:list, list}, index), do: list |> List.to_tuple() |> tuple_value_at(index)
  defp source_get({:value, value}, index), do: Get.get(value, Integer.to_string(index))

  defp object_length({:obj, ref}) do
    if Heap.get_array_prop(ref, "__arguments__") == true do
      to_length(Get.get({:obj, ref}, "length"))
    else
      case Heap.get_obj(ref) do
        {:qb_arr, _arr} ->
          to_length(Get.length_of({:obj, ref}))

        list when is_list(list) ->
          to_length(Get.length_of({:obj, ref}))

        _ ->
          array_like_object_length({:obj, ref})
      end
    end
  end

  defp array_like_object_length(obj) do
    length = to_length(Get.get(obj, "length"))

    if length == 0 and not OwnProperty.present?(obj, "length") do
      case InternalMethods.get_prototype_of(obj) do
        {:obj, _} = proto -> max(length, to_length(Get.get(proto, "length")))
        _ -> length
      end
    else
      length
    end
  end

  defp array_value_at(arr, index) when is_integer(index) and index >= 0 do
    if index < :array.size(arr), do: :array.get(index, arr), else: :undefined
  end

  defp array_value_at(_arr, _index), do: :undefined

  defp tuple_value_at(tuple, index)
       when is_integer(index) and index >= 0 and index < tuple_size(tuple),
       do: :erlang.element(index + 1, tuple)

  defp tuple_value_at(_tuple, _index), do: :undefined

  defp to_length(value) do
    case Runtime.to_number(value) do
      :infinity -> @max_safe_integer
      :neg_infinity -> 0
      :nan -> 0
      number when is_number(number) -> min(max(trunc(number), 0), @max_safe_integer)
      _ -> 0
    end
  end
end
