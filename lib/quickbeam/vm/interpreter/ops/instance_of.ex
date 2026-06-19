defmodule QuickBEAM.VM.Interpreter.Ops.InstanceOf do
  @moduledoc "Interpreter helper for JavaScript instanceof semantics."

  import QuickBEAM.VM.Heap.Keys, only: [date_ms: 0, proto: 0]
  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Heap, Invocation, Runtime, Value}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Semantics.Values

  def evaluate(obj, ctor) do
    has_instance = Get.get(ctor, {:symbol, "Symbol.hasInstance"})

    if not Value.nullish?(has_instance) and function_value?(has_instance) do
      has_instance
      |> Invocation.invoke_with_receiver([obj], Runtime.gas_budget(), ctor)
      |> Values.truthy?()
    else
      ordinary_instanceof(obj, ctor)
    end
  end

  defp ordinary_instanceof(obj, ctor) do
    unless function_value?(ctor) or is_object(ctor) do
      type_error!("Right-hand side of instanceof is not callable")
    end

    unless callable_ctor?(ctor) do
      type_error!("Right-hand side of instanceof is not callable")
    end

    if is_object(obj) or function_value?(obj) do
      if builtin_instance?(obj, ctor) do
        true
      else
        check_constructor_prototype(obj, ctor)
      end
    else
      false
    end
  end

  defp callable_ctor?({:builtin, _, map}) when is_map(map), do: false
  defp callable_ctor?({:obj, ref}), do: Get.get({:obj, ref}, "call") != :undefined
  defp callable_ctor?(_), do: true

  defp builtin_instance?({:obj, ref}, {:builtin, "Array", _}) do
    data = Heap.get_obj(ref)
    match?({:qb_arr, _}, data) or is_list(data)
  end

  defp builtin_instance?({:obj, ref}, {:builtin, "BigInt", _}) do
    match?(
      {:ok, _},
      QuickBEAM.VM.ObjectModel.WrappedPrimitive.value(Heap.get_obj(ref, %{}), :bigint)
    )
  end

  defp builtin_instance?({:obj, ref}, {:builtin, name, _}) when is_binary(name) do
    data = Heap.get_obj(ref, %{})

    QuickBEAM.VM.Runtime.TypedArray.instance_for_constructor?(data, name) or
      (name == "Date" and Map.has_key?(data, date_ms()))
  end

  defp builtin_instance?({:obj, _}, {:builtin, "Object", _}), do: true

  defp builtin_instance?(value, {:builtin, name, _}),
    do: function_value?(value) and name in ["Function", "Object"]

  defp builtin_instance?(_, _), do: false

  defp check_constructor_prototype(obj, ctor) do
    ctor_proto = Get.get(ctor, "prototype")

    case ctor_proto do
      {:obj, _} ->
        check_prototype_chain(obj, ctor_proto)

      _ when is_object(ctor) ->
        type_error!("Right-hand side of instanceof is not callable")

      _ ->
        type_error!(
          "Function has non-object prototype '#{Values.stringify(ctor_proto)}' in instanceof check"
        )
    end
  end

  defp check_prototype_chain(_, :undefined), do: false
  defp check_prototype_chain(_, nil), do: false

  defp check_prototype_chain({:obj, ref}, target) do
    proto_key = proto()

    case Heap.get_obj(ref, %{}) do
      %{^proto_key => ^target} -> true
      %{^proto_key => nil} -> false
      %{^proto_key => {:obj, _} = parent} -> check_prototype_chain(parent, target)
      _ -> false
    end
  end

  defp check_prototype_chain(_, _), do: false

  defp function_value?({:closure, _, _}), do: true
  defp function_value?(%QuickBEAM.VM.Function{}), do: true
  defp function_value?({:builtin, _, _}), do: true
  defp function_value?({:bound, _, _, _, _}), do: true
  defp function_value?(_), do: false

  defp type_error!(message), do: throw({:js_throw, Heap.make_error(message, "TypeError")})
end
