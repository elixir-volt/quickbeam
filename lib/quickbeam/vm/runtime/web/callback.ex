defmodule QuickBEAM.VM.Runtime.Web.Callback do
  @moduledoc "Callback invocation helpers for Web API event listeners and user-provided handlers."

  alias QuickBEAM.VM.Invocation

  @doc "Invokes a JavaScript callback with optional arguments and receiver."
  def invoke(callback, args \\ [], receiver \\ :undefined) do
    Invocation.invoke_with_receiver(callback, args, receiver)
  end

  @doc "Invokes a callback and suppresses thrown Elixir or JavaScript errors."
  def safe_invoke(callback, args \\ [], receiver \\ :undefined) do
    invoke(callback, args, receiver)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
