defmodule QuickBEAM.VM.Runtime.Web.Callback do
  @moduledoc false

  alias QuickBEAM.VM.Invocation

  def invoke(callback, args \\ [], receiver \\ :undefined) do
    Invocation.invoke_with_receiver(callback, args, receiver)
  end

  def safe_invoke(callback, args \\ [], receiver \\ :undefined) do
    invoke(callback, args, receiver)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
