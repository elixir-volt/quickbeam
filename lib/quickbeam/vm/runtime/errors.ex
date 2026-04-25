defmodule QuickBEAM.VM.Runtime.Errors do
  @moduledoc "JS Error constructors and prototype: `Error`, `TypeError`, `RangeError`, and the other standard error types."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Stacktrace

  @error_types ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError)

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
      build_methods do
        val("name", "Error")
        val("message", "")
        val("constructor", error_ctor)
        val("toString", error_tostring)
      end
    )

    Heap.put_class_proto(error_ctor, {:obj, error_proto_ref})
    Heap.put_ctor_static(error_ctor, "prototype", {:obj, error_proto_ref})

    Heap.put_ctor_static(
      error_ctor,
      "captureStackTrace",
      {:builtin, "captureStackTrace",
       fn
         [], _ ->
           JSThrow.type_error!("Cannot convert undefined to object")

         [obj | rest], _ ->
           filter_fun = List.first(rest)

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
          build_methods do
            val("__proto__", {:obj, error_proto_ref})
            val("name", name)
            val("message", "")
            val("constructor", ctor)
          end
        )

        Heap.put_class_proto(ctor, {:obj, proto_ref})
        Heap.put_ctor_static(ctor, "prototype", {:obj, proto_ref})
        Heap.put_ctor_static(ctor, "__proto__", error_ctor)
        {name, ctor}
      end

    Map.put(derived, "Error", error_ctor)
  end

  defp error_constructor(name, args) do
    msg = List.first(args, "")
    error = Heap.make_error(Runtime.stringify(msg), name)
    Stacktrace.attach_stack(error)
  end
end
