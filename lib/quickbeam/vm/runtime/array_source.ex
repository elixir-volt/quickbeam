defmodule QuickBEAM.VM.Runtime.ArraySource do
  @moduledoc "Indexed array-like source access for Array and iterator helpers."

  import QuickBEAM.VM.Heap.Keys, only: [typed_array: 0]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods}
  alias QuickBEAM.VM.Runtime

  @max_safe_integer 9_007_199_254_740_991

  def new({:obj, _} = obj), do: {:object, obj}
  def new({:qb_arr, arr}), do: {:qb_arr, arr}
  def new({:tuple, tuple}), do: {:tuple, tuple}
  def new(list) when is_list(list), do: {:list, list}
  def new(value), do: {:value, value}

  def length(value), do: value |> new() |> source_length()

  def get(value, index), do: value |> new() |> source_get(index)

  def to_list(value) do
    source = new(value)
    len = source_length(source)

    if len == 0 do
      []
    else
      for index <- 0..(len - 1), do: source_get(source, index)
    end
  end

  defp source_length({:object, obj}), do: object_length(obj)
  defp source_length({:qb_arr, arr}), do: :array.size(arr)
  defp source_length({:tuple, tuple}), do: tuple_size(tuple)
  defp source_length({:list, list}), do: Kernel.length(list)
  defp source_length({:value, value}), do: to_length(InternalMethods.get(value, "length"))

  defp source_get({:object, value}, index) do
    key = Integer.to_string(index)
    current = InternalMethods.get(value, key)

    if current == :undefined and not InternalMethods.own_property_present?(value, key) do
      case InternalMethods.get_prototype_of(value) do
        {:obj, _} = proto -> InternalMethods.get(proto, key)
        _ -> current
      end
    else
      current
    end
  end

  defp source_get({:qb_arr, arr}, index), do: array_value_at(arr, index)
  defp source_get({:tuple, tuple}, index), do: tuple_value_at(tuple, index)
  defp source_get({:list, list}, index), do: list |> List.to_tuple() |> tuple_value_at(index)

  defp source_get({:value, value}, index),
    do: InternalMethods.get(value, Integer.to_string(index))

  defp object_length({:obj, ref}) do
    if Heap.get_array_prop(ref, "__arguments__") == true do
      to_length(InternalMethods.get({:obj, ref}, "length"))
    else
      case Heap.get_obj(ref) do
        {:qb_arr, _arr} ->
          to_length(Get.length_of({:obj, ref}))

        %{typed_array() => true} ->
          if QuickBEAM.VM.Runtime.TypedArray.out_of_bounds?({:obj, ref}) do
            0
          else
            QuickBEAM.VM.Runtime.TypedArray.element_count({:obj, ref})
          end

        list when is_list(list) ->
          to_length(Get.length_of({:obj, ref}))

        _ ->
          array_like_object_length({:obj, ref})
      end
    end
  end

  defp array_like_object_length(obj) do
    length = to_length(InternalMethods.get(obj, "length"))

    if length == 0 and not InternalMethods.own_property_present?(obj, "length") do
      case InternalMethods.get_prototype_of(obj) do
        {:obj, _} = proto -> max(length, to_length(InternalMethods.get(proto, "length")))
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
