defmodule QuickBEAM.VM.Runtime.Errors do
  @moduledoc "JS Error constructors and prototype: `Error`, `TypeError`, `RangeError`, and the other standard error types."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 2]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Constructors
  alias QuickBEAM.VM.Stacktrace

  @error_types ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError)

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    error_proto_ref = make_ref()
    error_ctor = {:builtin, "Error", fn args, _this -> error_constructor("Error", args) end}

    error_tostring =
      {:builtin, "toString",
       fn _args, this ->
         name =
           case QuickBEAM.VM.ObjectModel.Get.get(this, "name") do
             nil -> "Error"
             :undefined -> "Error"
             n -> Runtime.stringify(n)
           end

         msg =
           case QuickBEAM.VM.ObjectModel.Get.get(this, "message") do
             nil -> ""
             :undefined -> ""
             m -> Runtime.stringify(m)
           end

         if msg == "", do: name, else: name <> ": " <> msg
       end}

    Heap.put_obj(
      error_proto_ref,
      object heap: false do
        prop("__proto__", Heap.get_object_prototype())
        prop("name", "Error")
        prop("message", "")
        prop("constructor", error_ctor)
        prop("toString", error_tostring)
      end
    )

    Heap.put_prop_desc(error_proto_ref, "name", PropertyDescriptor.method())
    Heap.put_prop_desc(error_proto_ref, "message", PropertyDescriptor.method())
    Heap.put_prop_desc(error_proto_ref, "constructor", PropertyDescriptor.method())
    Heap.put_prop_desc(error_proto_ref, "toString", PropertyDescriptor.method())

    Constructors.put_prototype(error_ctor, {:obj, error_proto_ref})
    Heap.put_ctor_prop_desc(error_ctor, "prototype", PropertyDescriptor.prototype())

    Heap.put_ctor_static(
      error_ctor,
      "isError",
      {:builtin, "isError",
       fn args, _ ->
         case arg(args, 0, :undefined) do
           {:obj, ref} -> Map.has_key?(Heap.get_obj(ref, %{}), "__error_name__")
           _ -> false
         end
       end}
    )

    Heap.put_ctor_prop_desc(error_ctor, "isError", PropertyDescriptor.method())

    Heap.put_ctor_static(
      error_ctor,
      "captureStackTrace",
      {:builtin, "captureStackTrace",
       fn
         [], _ ->
           JSThrow.type_error!("Cannot convert undefined to object")

         [obj | rest], _ ->
           filter_fun = arg(rest, 0, nil)

           case obj do
             {:obj, _} -> Stacktrace.attach_stack(obj, filter_fun)
             _ -> :ok
           end

           :undefined
       end}
    )

    Heap.put_ctor_static(error_ctor, "prepareStackTrace", :undefined)
    Heap.put_ctor_static(error_ctor, "stackTraceLimit", 10)

    derived =
      for name <- Enum.reject(@error_types, &(&1 == "Error")), into: %{} do
        proto_ref = make_ref()
        ctor = {:builtin, name, fn args, _this -> error_constructor(name, args) end}

        Heap.put_obj(
          proto_ref,
          object heap: false do
            prop("__proto__", {:obj, error_proto_ref})
            prop("name", name)
            prop("message", "")
            prop("constructor", ctor)
          end
        )

        Heap.put_prop_desc(proto_ref, "name", PropertyDescriptor.method())
        Heap.put_prop_desc(proto_ref, "message", PropertyDescriptor.method())
        Heap.put_prop_desc(proto_ref, "constructor", PropertyDescriptor.method())

        Constructors.put_prototype(ctor, {:obj, proto_ref})
        Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
        Heap.put_ctor_static(ctor, "__proto__", error_ctor)
        {name, ctor}
      end

    Map.put(derived, "Error", error_ctor)
  end

  defp error_constructor(name, args) do
    msg = arg(args, 0, :undefined)
    message = if msg == :undefined, do: "", else: Runtime.stringify(msg)
    error = Heap.make_error(message, name)
    maybe_install_cause(error, arg(args, 1, :undefined))
    Stacktrace.attach_stack(error)
  end

  defp maybe_install_cause({:obj, error_ref}, {:obj, options_ref}) do
    options = Heap.get_obj(options_ref, %{})

    if Map.has_key?(options, "cause") do
      Heap.put_obj_key(error_ref, "cause", Map.get(options, "cause"))
      Heap.put_prop_desc(error_ref, "cause", PropertyDescriptor.method())
    end
  end

  defp maybe_install_cause(_error, _options), do: :ok
end
