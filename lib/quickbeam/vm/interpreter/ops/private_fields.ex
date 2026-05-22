defmodule QuickBEAM.VM.Interpreter.Ops.PrivateFields do
  @moduledoc "Interpreter helpers for private fields and brands."

  alias QuickBEAM.VM.ObjectModel.Private

  def get(obj, key) do
    case Private.get_field(obj, key) do
      :missing -> {:throw, Private.brand_error()}
      value -> {:ok, value}
    end
  end

  def put(obj, key, value) do
    case Private.put_field!(obj, key, value) do
      :ok -> :ok
      :error -> {:throw, Private.brand_error()}
    end
  end

  def define(obj, key, value) do
    case Private.define_field!(obj, key, value) do
      :ok -> :ok
      :error -> {:throw, Private.brand_error()}
    end
  end

  def has?(obj, key), do: Private.has_field?(obj, key) or Private.has_brand?(obj, key)
  def symbol(name), do: Private.private_symbol(name)
end
