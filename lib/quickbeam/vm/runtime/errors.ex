defmodule QuickBEAM.VM.Runtime.Errors do
  @moduledoc "JS Error constructors and prototype: `Error`, `TypeError`, `RangeError`, and the other standard error types."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, build_methods: 1, object: 2]
  import QuickBEAM.VM.Heap.Keys, only: [key_order: 0]
  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.Builtin.Definition
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Semantics.Coercion
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, PropertyDescriptor}
  alias QuickBEAM.VM.Semantics.Iterators
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.ConstructorRegistry, as: Constructors
  alias QuickBEAM.VM.Stacktrace

  @error_types ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError AggregateError SuppressedError)

  @error_ecma %{
    "Error" => "20.5.1.1",
    "EvalError" => "20.5.6.1.1",
    "RangeError" => "20.5.6.1.1",
    "ReferenceError" => "20.5.6.1.1",
    "SyntaxError" => "20.5.6.1.1",
    "TypeError" => "20.5.6.1.1",
    "URIError" => "20.5.6.1.1",
    "AggregateError" => "20.5.7.1.1"
  }

  def builtin_definitions do
    Enum.map(@error_types, fn name ->
      %Definition{
        name: name,
        constructor: fn args, this -> construct_error(name, args, this) end,
        length: if(name == "AggregateError", do: 2, else: 1),
        phase: :fundamental,
        module: __MODULE__,
        auto_install?: false,
        ecma: Map.get(@error_ecma, name)
      }
    end)
  end

  def realm_bindings(object_proto) do
    error_ctor =
      install_error_definition("Error", object_proto, fn ctor, _opts ->
        install_error_builtin(ctor, object_proto)
      end)

    derived =
      @error_types
      |> Enum.reject(&(&1 == "Error"))
      |> Map.new(fn name ->
        ctor =
          install_error_definition(name, object_proto, fn ctor, _opts ->
            install_derived_error_builtin(ctor, name, error_ctor)
          end)

        {name, ctor}
      end)

    Map.put(derived, "Error", error_ctor)
  end

  defp install_error_definition(name, object_proto, after_install) do
    name
    |> error_definition()
    |> Map.put(:after_install, after_install)
    |> QuickBEAM.VM.Builtin.Installer.install(target: {:realm, object_proto: object_proto})
  end

  defp error_definition(name), do: Enum.find(builtin_definitions(), &(&1.name == name))

  defp install_error_builtin(ctor, object_proto) do
    Constructors.put_prototype(ctor, Heap.get_ctor_statics(ctor)["prototype"])
    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())

    with {:obj, proto_ref} <- Heap.get_class_proto(ctor) do
      Heap.put_obj_key(proto_ref, "__proto__", object_proto)
      Heap.put_obj_key(proto_ref, "name", "Error")
      Heap.put_obj_key(proto_ref, "message", "")
      Heap.put_obj_key(proto_ref, "toString", error_to_string_method())

      install_data_descriptors(proto_ref, ["name", "message", "constructor", "toString"])
    end

    install_error_statics(ctor)
  end

  defp install_derived_error_builtin(ctor, name, error_ctor) do
    Constructors.put_prototype(ctor, Heap.get_ctor_statics(ctor)["prototype"])
    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
    Heap.put_ctor_static(ctor, "__proto__", error_ctor)

    with {:obj, proto_ref} <- Heap.get_class_proto(ctor),
         {:obj, _} = error_proto <- Heap.get_class_proto(error_ctor) do
      Heap.put_obj_key(proto_ref, "__proto__", error_proto)
      Heap.put_obj_key(proto_ref, "name", name)
      Heap.put_obj_key(proto_ref, "message", "")

      install_data_descriptors(proto_ref, ["name", "message", "constructor"])
    end
  end

  defp install_data_descriptors(ref, keys) do
    Enum.each(keys, &Heap.put_prop_desc(ref, &1, PropertyDescriptor.method()))
  end

  defp install_error_statics(ctor) do
    Heap.put_ctor_static(ctor, "isError", error_is_error_method())
    Heap.put_ctor_prop_desc(ctor, "isError", PropertyDescriptor.method())
    Heap.put_ctor_static(ctor, "captureStackTrace", capture_stack_trace_method())
    Heap.put_ctor_prop_desc(ctor, "captureStackTrace", PropertyDescriptor.method())
    Heap.put_ctor_static(ctor, "prepareStackTrace", :undefined)
    Heap.put_ctor_static(ctor, "stackTraceLimit", 10)
  end

  defp error_prototype_methods do
    build_methods do
      @ecma "20.5.3.4"
      method "toString" do
        unless match?({:obj, _}, this) do
          JSThrow.type_error!("Error.prototype.toString called on non-object")
        end

        name =
          case InternalMethods.get(this, "name") do
            nil -> "Error"
            :undefined -> "Error"
            n -> stringify_error_slot(n)
          end

        msg =
          case InternalMethods.get(this, "message") do
            nil -> ""
            :undefined -> ""
            m -> stringify_error_slot(m)
          end

        cond do
          name == "" -> msg
          msg == "" -> name
          true -> name <> ": " <> msg
        end
      end
    end
  end

  defp error_to_string_method, do: Map.fetch!(error_prototype_methods(), "toString")

  defp error_is_error_method do
    {:builtin, "isError",
     fn args, _ ->
       case arg(args, 0, :undefined) do
         {:obj, ref} ->
           case Heap.get_obj(ref, %{}) do
             map when is_map(map) -> Map.has_key?(map, "__error_name__")
             _ -> false
           end

         _ ->
           false
       end
     end}
  end

  defp capture_stack_trace_method do
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
  end

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    error_proto_ref = make_ref()
    error_ctor = {:builtin, "Error", fn args, this -> construct_error("Error", args, this) end}

    error_tostring = error_to_string_method()

    Heap.put_obj(
      error_proto_ref,
      object heap: false, extends: Heap.get_object_prototype() do
        prop("name", "Error")
        prop("message", "")
        prop("constructor", error_ctor)
        prop("toString", error_tostring)
      end
    )

    install_data_descriptors(error_proto_ref, ["name", "message", "constructor", "toString"])

    Constructors.put_prototype(error_ctor, {:obj, error_proto_ref})
    install_function_parent(error_ctor)
    Heap.put_ctor_prop_desc(error_ctor, "prototype", PropertyDescriptor.prototype())

    Heap.put_ctor_static(
      error_ctor,
      "isError",
      {:builtin, "isError",
       fn args, _ ->
         case arg(args, 0, :undefined) do
           {:obj, ref} ->
             case Heap.get_obj(ref, %{}) do
               map when is_map(map) -> Map.has_key?(map, "__error_name__")
               _ -> false
             end

           _ ->
             false
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
        ctor = {:builtin, name, fn args, this -> construct_error(name, args, this) end}

        Heap.put_obj(
          proto_ref,
          object heap: false, extends: {:obj, error_proto_ref} do
            prop("name", name)
            prop("message", "")
            prop("constructor", ctor)
          end
        )

        install_data_descriptors(proto_ref, ["name", "message", "constructor"])

        Constructors.put_prototype(ctor, {:obj, proto_ref})
        Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
        Heap.put_ctor_static(ctor, "__proto__", error_ctor)
        {name, ctor}
      end

    Map.put(derived, "Error", error_ctor)
  end

  defp construct_error(name, args, this_obj)

  defp construct_error("AggregateError", args, this_obj),
    do: aggregate_error_constructor(args, this_obj)

  defp construct_error("SuppressedError", args, this_obj),
    do: suppressed_error_constructor(args, this_obj)

  defp construct_error(name, args, this_obj), do: error_constructor(name, args, this_obj)

  defp error_constructor(name, args, this_obj) do
    msg = arg(args, 0, :undefined)
    message = if msg == :undefined, do: "", else: stringify_error_slot(msg)
    error = make_error_object(message, name, this_obj)
    if msg == :undefined, do: delete_message(error)
    maybe_install_cause(error, arg(args, 1, :undefined))
    Stacktrace.attach_stack(error)
  end

  defp maybe_install_cause({:obj, error_ref}, {:obj, _} = options) do
    if InternalMethods.has_property(options, "cause") do
      Heap.put_obj_key(error_ref, "cause", InternalMethods.get(options, "cause"))
      Heap.put_prop_desc(error_ref, "cause", PropertyDescriptor.method())
    end
  end

  defp maybe_install_cause(_error, _options), do: :ok

  defp aggregate_error_constructor(args, this_obj) do
    errors = arg(args, 0, :undefined)
    message_arg = arg(args, 1, :undefined)
    options = arg(args, 2, :undefined)
    message = if message_arg == :undefined, do: "", else: stringify_error_slot(message_arg)
    error = make_error_object(message, "AggregateError", this_obj)
    if message_arg == :undefined, do: delete_message(error)

    with {:obj, ref} <- error do
      Heap.put_obj_key(ref, "errors", Heap.wrap(iterable_list(errors)))
      Heap.put_prop_desc(ref, "errors", PropertyDescriptor.method())
    end

    maybe_install_cause(error, options)
    Stacktrace.attach_stack(error)
  end

  defp suppressed_error_constructor(args, this_obj) do
    error_arg = arg(args, 0, :undefined)
    suppressed_arg = arg(args, 1, :undefined)
    message_arg = arg(args, 2, :undefined)
    message = if message_arg == :undefined, do: "", else: stringify_error_slot(message_arg)
    error = make_error_object(message, "SuppressedError", this_obj)
    if message_arg == :undefined, do: delete_message(error)

    with {:obj, ref} <- error do
      Heap.put_obj_key(ref, "error", error_arg)
      Heap.put_prop_desc(ref, "error", PropertyDescriptor.method())
      Heap.put_obj_key(ref, "suppressed", suppressed_arg)
      Heap.put_prop_desc(ref, "suppressed", PropertyDescriptor.method())
      Heap.put_obj_key(ref, key_order(), ["suppressed", "error", "message"])
    end

    Stacktrace.attach_stack(error)
  end

  defp iterable_list(errors) when is_nullish(errors),
    do: JSThrow.type_error!("object is not iterable")

  defp iterable_list({:obj, ref} = errors) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, arr} ->
        :array.to_list(arr)

      map when is_map(map) ->
        sym_iter = {:symbol, "Symbol.iterator"}
        iter_fn = InternalMethods.get(errors, sym_iter)

        cond do
          QuickBEAM.VM.Builtin.callable?(iter_fn) ->
            iter = Invocation.invoke_with_receiver(iter_fn, [], errors)
            unless match?({:obj, _}, iter), do: JSThrow.type_error!("iterator is not an object")
            next_fn = InternalMethods.get(iter, "next")

            unless QuickBEAM.VM.Builtin.callable?(next_fn),
              do: JSThrow.type_error!("iterator.next is not callable")

            collect_iterable(iter, next_fn, [])

          QuickBEAM.VM.Builtin.callable?(InternalMethods.get(errors, "next")) ->
            collect_iterable(errors, InternalMethods.get(errors, "next"), [])

          true ->
            JSThrow.type_error!("object is not iterable")
        end

      _ ->
        JSThrow.type_error!("object is not iterable")
    end
  end

  defp iterable_list(errors) do
    {iter, next_fn} = Iterators.for_of_start(errors)
    collect_iterable(iter, next_fn, [])
  end

  defp collect_iterable({:list_iter, [head | tail]}, next_fn, acc),
    do: collect_iterable({:list_iter, tail}, next_fn, [head | acc])

  defp collect_iterable({:list_iter, []}, _next_fn, acc), do: Enum.reverse(acc)

  defp collect_iterable(iter, next_fn, acc) do
    result = Invocation.invoke_with_receiver(next_fn, [], iter)
    unless match?({:obj, _}, result), do: JSThrow.type_error!("iterator result is not an object")

    if InternalMethods.get(result, "done") == true do
      Enum.reverse(acc)
    else
      collect_iterable(iter, next_fn, [InternalMethods.get(result, "value") | acc])
    end
  end

  defp delete_message({:obj, ref}) do
    Heap.put_obj(ref, Map.delete(Heap.get_obj(ref, %{}), "message"))
    Heap.delete_prop_desc(ref, "message")
  end

  defp stringify_error_slot({:symbol, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp stringify_error_slot({:symbol, _, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp stringify_error_slot({:obj, _} = value),
    do: value |> Coercion.to_primitive("string") |> stringify_error_slot()

  defp stringify_error_slot(value), do: Runtime.stringify(value)

  defp make_error_object(message, name, {:obj, ref} = this_obj) do
    map = Heap.get_obj(ref, %{})

    Heap.put_obj(
      ref,
      Map.merge(map, %{
        "message" => message,
        "name" => name,
        "stack" => "",
        "__error_name__" => name,
        {:symbol, "Symbol.toStringTag"} => "Error"
      })
    )

    for key <- ["message", "name", "stack"] do
      Heap.put_prop_desc(ref, key, PropertyDescriptor.method())
    end

    this_obj
  end

  defp make_error_object(message, name, _this_obj), do: Heap.make_error(message, name)

  defp install_function_parent(ctor) do
    case Heap.get_func_proto() do
      {:obj, function_proto_ref} = function_proto ->
        Heap.put_ctor_static(ctor, "__proto__", function_proto)

        case Heap.get_obj(function_proto_ref, %{}) do
          %{"constructor" => function_ctor} ->
            Heap.put_ctor_static(ctor, "constructor", function_ctor)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
