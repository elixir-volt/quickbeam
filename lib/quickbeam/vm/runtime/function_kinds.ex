defmodule QuickBEAM.VM.Runtime.FunctionKinds do
  @moduledoc "Names and constructor callbacks for non-ordinary function kinds."

  alias QuickBEAM.VM.Runtime.ConstructorCallbacks

  def constructor(1), do: {"GeneratorFunction", &ConstructorCallbacks.generator_function/2}
  def constructor(2), do: {"AsyncFunction", &ConstructorCallbacks.async_function/2}

  def constructor(3),
    do: {"AsyncGeneratorFunction", &ConstructorCallbacks.async_generator_function/2}

  def constructor(%QuickBEAM.VM.Function{func_kind: kind}), do: constructor(kind)
  def constructor(_), do: nil
end
