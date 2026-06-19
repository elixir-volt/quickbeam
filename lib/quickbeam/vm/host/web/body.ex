defmodule QuickBEAM.VM.Host.Web.Body do
  @moduledoc "Shared Fetch/Request/Response/Blob body conversion and consumption helpers."

  alias QuickBEAM.VM.{Heap, JSThrow, Promise}
  alias QuickBEAM.VM.ObjectModel.InternalMethods
  alias QuickBEAM.VM.Host.Web.BinaryData

  @doc "Creates a heap-backed body state record."
  def new(data, opts \\ []) do
    body_ref = make_ref()
    Heap.put_obj(body_ref, %{consumed: Keyword.get(opts, :consumed, false), data: data})
    body_ref
  end

  @doc "Returns the underlying body payload without consuming it."
  def data(body_ref) do
    body_ref
    |> Heap.get_obj(%{})
    |> body_data()
  end

  @doc "Returns true when the body state carries a non-null payload."
  def has_body?(body_ref) do
    case Heap.get_obj(body_ref, %{}) do
      %{data: data} -> not is_nil(data) and data != :undefined
      _ -> false
    end
  end

  @doc "Creates a fresh unconsumed body state with the same payload."
  def clone(body_ref) do
    case Heap.get_obj(body_ref, %{}) do
      %{consumed: true} -> JSThrow.type_error!("Body has already been consumed")
      %{data: data} -> new(data)
      _ -> new(nil)
    end
  end

  @doc "Consumes a body once and returns its payload or raises for unusable state."
  def consume_payload!(body_ref) do
    case Heap.get_obj(body_ref, %{}) do
      %{consumed: true} ->
        JSThrow.type_error!("Body has already been consumed")

      %{consumed: false, data: data} ->
        Heap.put_obj(body_ref, %{consumed: true, data: data})
        data

      _ ->
        nil
    end
  end

  @doc "Consumes a body once, marks the owner as bodyUsed, and invokes the callback with payload data."
  def consume(body_ref, owner, fun) when is_function(fun, 1) do
    case Heap.get_obj(body_ref, %{}) do
      %{consumed: true} ->
        "Body has already been consumed"
        |> Heap.make_error("TypeError")
        |> Promise.rejected()

      %{consumed: false} ->
        data = consume_payload!(body_ref)
        InternalMethods.set(owner, "bodyUsed", true)
        fun.(data)

      _ ->
        fun.(nil)
    end
  end

  @doc "Converts a body payload to text."
  def text(nil), do: ""
  def text(:undefined), do: ""
  def text({:bytes, data}) when is_binary(data), do: data
  def text(data) when is_binary(data), do: data
  def text(data), do: to_string(data)

  @doc "Resolves a body payload as text."
  def text_response(data), do: Promise.resolved(text(data))

  @doc "Converts a body payload to an ArrayBuffer."
  def array_buffer(data), do: data |> text() |> BinaryData.array_buffer()

  @doc "Resolves a body payload as an ArrayBuffer."
  def array_buffer_response(data), do: data |> array_buffer() |> Promise.resolved()

  @doc "Converts a body payload to a Uint8Array-style byte list object."
  def bytes(data) do
    data
    |> text()
    |> :binary.bin_to_list()
    |> Heap.wrap()
  end

  @doc "Resolves a body payload as bytes."
  def bytes_response(data), do: data |> bytes() |> Promise.resolved()

  @doc "Converts a body payload to a Uint8Array object."
  def uint8_array(data), do: data |> text() |> BinaryData.uint8_array()

  defp body_data(%{data: data}), do: data
  defp body_data(_), do: nil
end
