defmodule QuickBEAM.VM.Runtime.DataView do
  @moduledoc "Minimal DataView constructor and prototype accessors."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys, only: [buffer: 0]

  alias QuickBEAM.VM.{Heap, JSThrow, Runtime}

  @slot "__data_view__"

  def constructor(args, this \\ nil) do
    buffer_obj = List.first(args) || :undefined
    buffer_ref = require_array_buffer!(buffer_obj)
    buffer_map = Heap.get_obj(buffer_ref, %{})

    buffer_len = byte_size(Map.get(buffer_map, buffer(), <<>>))
    offset = to_index(args |> Enum.at(1, 0))
    view_len = data_view_length(args, buffer_len, offset)

    if Map.get(buffer_map, "__detached__") do
      JSThrow.type_error!("ArrayBuffer is detached")
    end

    cond do
      offset > buffer_len -> JSThrow.range_error!("DataView byteOffset out of range")
      offset + view_len > buffer_len -> JSThrow.range_error!("DataView byteLength out of range")
      true -> :ok
    end

    obj = if match?({:obj, _}, this), do: this, else: Runtime.new_object()
    {:obj, ref} = obj

    Heap.put_obj(
      ref,
      Map.merge(Heap.get_obj(ref, %{}), %{
        @slot => true,
        "__viewed_buffer__" => buffer_obj,
        "__byteOffset__" => offset,
        "__byteLength__" => view_len
      })
    )

    obj
  end

  def accessor("buffer"),
    do: {:accessor, {:builtin, "get buffer", fn _, this -> view_field!(this, "buffer") end}, nil}

  def accessor("byteLength"),
    do:
      {:accessor, {:builtin, "get byteLength", fn _, this -> view_field!(this, "byteLength") end},
       nil}

  def accessor("byteOffset"),
    do:
      {:accessor, {:builtin, "get byteOffset", fn _, this -> view_field!(this, "byteOffset") end},
       nil}

  defp require_array_buffer!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, buffer()) -> ref
      _ -> JSThrow.type_error!("DataView buffer must be an ArrayBuffer")
    end
  end

  defp require_array_buffer!(_), do: JSThrow.type_error!("DataView buffer must be an ArrayBuffer")

  defp data_view_length(args, buffer_len, offset) do
    case Enum.fetch(args, 2) do
      {:ok, :undefined} -> buffer_len - offset
      {:ok, value} -> to_index(value)
      :error -> buffer_len - offset
    end
  end

  defp to_index(value) do
    index = Runtime.to_int(value)
    if index < 0, do: JSThrow.range_error!("DataView index out of range"), else: index
  end

  defp view_field!({:obj, ref}, field) do
    case Heap.get_obj(ref, %{}) do
      %{@slot => true} = view ->
        if field in ["byteLength", "byteOffset"] do
          assert_view_buffer_attached!(view)
        end

        case field do
          "buffer" -> Map.get(view, "__viewed_buffer__")
          "byteLength" -> Map.get(view, "__byteLength__")
          "byteOffset" -> Map.get(view, "__byteOffset__")
        end

      _ ->
        JSThrow.type_error!("DataView method called on incompatible receiver")
    end
  end

  defp view_field!(_, _field),
    do: JSThrow.type_error!("DataView method called on incompatible receiver")

  defp assert_view_buffer_attached!(%{"__viewed_buffer__" => {:obj, buffer_ref}}) do
    case Heap.get_obj(buffer_ref, %{}) do
      %{"__detached__" => true} -> JSThrow.type_error!("ArrayBuffer is detached")
      _ -> :ok
    end
  end

  defp assert_view_buffer_attached!(_), do: :ok
end
