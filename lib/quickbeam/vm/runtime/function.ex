defmodule QuickBEAM.VM.Runtime.Function do
  @moduledoc "JS `Function` prototype: `call`, `apply`, `bind`, and property access for name/length/fileName."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{Builtin, Heap, Invocation}
  alias QuickBEAM.VM.Execution.Trace
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor, Put, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Host.Test262

  builtin_definition("Function",
    constructor: &QuickBEAM.VM.Runtime.Globals.Constructors.function/2,
    length: 1,
    phase: :core,
    prototype_parent: nil,
    after_install: &__MODULE__.install_builtin/1
  )

  def install_builtin(ctor) do
    ConstructorRegistry.put_prototype(ctor, prototype())

    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, _} = proto -> Put.put(proto, "constructor", ctor)
      _ -> :ok
    end

    Heap.put_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
  end

  @doc "Builds the JavaScript prototype object for this runtime builtin."
  def prototype do
    has_instance =
      {:builtin, "[Symbol.hasInstance]",
       fn args, this ->
         obj = Builtin.arg(args, 0, :undefined)
         ordinary_has_instance(this, obj)
       end}

    proto =
      Heap.wrap(%{
        "length" => 0,
        "name" => "",
        "call" => {:builtin, "call", fn args, this -> fn_call(this, args, this) end},
        "apply" => {:builtin, "apply", fn args, this -> fn_apply(this, args, this) end},
        "bind" =>
          {:builtin, "bind",
           fn args, this ->
             unless Builtin.callable?(this),
               do:
                 throw(
                   {:js_throw, Heap.make_error("Bind must be called on a function", "TypeError")}
                 )

             fn_bind(this, args, this)
           end},
        "toString" =>
          {:builtin, "toString",
           fn _args, this ->
             unless Builtin.callable?(this),
               do: throw({:js_throw, Heap.make_error("not a function", "TypeError")})

             case this do
               {:obj, _} -> "function () { [native code] }"
               _ -> elem(proto_property(this, "toString"), 2).([], this)
             end
           end},
        {:symbol, "Symbol.hasInstance"} => has_instance
      })

    {:obj, ref} = proto

    for name <- ~w(call apply bind toString) do
      Heap.put_prop_desc(ref, name, PropertyDescriptor.method())
    end

    for name <- ~w(length name) do
      Heap.put_prop_desc(ref, name, PropertyDescriptor.hidden_readonly())
    end

    Heap.put_prop_desc(ref, {:symbol, "Symbol.hasInstance"}, PropertyDescriptor.prototype())

    case Heap.get_object_prototype() do
      {:obj, _} = obj_proto ->
        map = Heap.get_obj(ref, %{})
        Heap.put_obj(ref, Map.put(map, "__proto__", obj_proto))

      _ ->
        :ok
    end

    Heap.put_func_proto(proto)
    proto
  end

  defp ordinary_has_instance({:bound, _, _, target, _}, obj),
    do: ordinary_has_instance(target, obj)

  defp ordinary_has_instance(callable, obj) do
    cond do
      not Builtin.callable?(callable) ->
        false

      not object_like?(obj) ->
        false

      typed_array_builtin_instance?(obj, callable) ->
        true

      true ->
        prototype = Get.get(callable, "prototype")

        unless object_like?(prototype),
          do: QuickBEAM.VM.JSThrow.type_error!("Function has non-object prototype")

        prototype_chain_contains?(obj, prototype, MapSet.new())
    end
  end

  defp prototype_chain_contains?(obj, prototype, seen) do
    case object_get_prototype_of(obj) do
      nil ->
        false

      ^prototype ->
        true

      {:obj, ref} = next ->
        if MapSet.member?(seen, ref),
          do: false,
          else: prototype_chain_contains?(next, prototype, MapSet.put(seen, ref))

      next when is_tuple(next) or is_struct(next) ->
        prototype_chain_contains?(next, prototype, seen)

      _ ->
        false
    end
  end

  defp object_get_prototype_of(obj) do
    QuickBEAM.VM.Runtime.Object.static_property("getPrototypeOf")
    |> Invocation.invoke_callback_or_throw([obj])
  end

  defp object_like?({:obj, _}), do: true
  defp object_like?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp object_like?({:builtin, _, _}), do: true
  defp object_like?({:regexp, _, _}), do: true
  defp object_like?({:regexp, _, _, _}), do: true
  defp object_like?({:bound, _, _, _, _}), do: true
  defp object_like?(%QuickBEAM.VM.Function{}), do: true
  defp object_like?(_), do: false

  defp typed_array_builtin_instance?({:obj, ref}, {:builtin, constructor_name, _})
       when is_binary(constructor_name) do
    case Heap.get_obj(ref, %{}) do
      %{"__typed_array__" => true, "__type__" => type} ->
        typed_array_constructor_type(constructor_name) == type

      _ ->
        false
    end
  end

  defp typed_array_builtin_instance?(_, _), do: false

  defp typed_array_constructor_type("Uint8Array"), do: :uint8
  defp typed_array_constructor_type("Int8Array"), do: :int8
  defp typed_array_constructor_type("Uint16Array"), do: :uint16
  defp typed_array_constructor_type("Int16Array"), do: :int16
  defp typed_array_constructor_type("Uint32Array"), do: :uint32
  defp typed_array_constructor_type("Int32Array"), do: :int32
  defp typed_array_constructor_type("Float16Array"), do: :float16
  defp typed_array_constructor_type("Float32Array"), do: :float32
  defp typed_array_constructor_type("Float64Array"), do: :float64
  defp typed_array_constructor_type("Uint8ClampedArray"), do: :uint8_clamped
  defp typed_array_constructor_type("BigUint64Array"), do: :biguint64
  defp typed_array_constructor_type("BigInt64Array"), do: :bigint64
  defp typed_array_constructor_type(_), do: nil

  # ── Function prototype ──

  @doc "Returns a prototype property value for the given JavaScript property key."
  def proto_property(fun, "call") do
    {:builtin, "call", fn args, this -> fn_call(fun, args, this) end}
  end

  def proto_property(fun, "apply") do
    {:builtin, "apply", fn args, this -> fn_apply(fun, args, this) end}
  end

  def proto_property(fun, "bind") do
    {:builtin, "bind", fn args, this -> fn_bind(fun, args, this) end}
  end

  def proto_property(%QuickBEAM.VM.Function{} = f, "name"), do: f.name || ""
  def proto_property(%QuickBEAM.VM.Function{} = f, "length"), do: f.defined_arg_count
  def proto_property(%QuickBEAM.VM.Function{} = f, "fileName"), do: f.filename || ""
  def proto_property(%QuickBEAM.VM.Function{} = f, "lineNumber"), do: f.line_num
  def proto_property(%QuickBEAM.VM.Function{} = f, "columnNumber"), do: f.col_num

  def proto_property({:closure, _, %QuickBEAM.VM.Function{} = f}, "name"),
    do: f.name || ""

  def proto_property({:closure, _, %QuickBEAM.VM.Function{} = f}, "length"),
    do: f.defined_arg_count

  def proto_property({:closure, _, %QuickBEAM.VM.Function{} = f}, "fileName"),
    do: f.filename || ""

  def proto_property({:closure, _, %QuickBEAM.VM.Function{} = f}, "lineNumber"), do: f.line_num
  def proto_property({:closure, _, %QuickBEAM.VM.Function{} = f}, "columnNumber"), do: f.col_num

  def proto_property({:bound, _, inner, _, _}, key)
      when key not in ["length", "name", "caller", "arguments"],
      do: proto_property(inner, key)

  def proto_property({:bound, len, _, _, _}, "length"), do: len
  def proto_property(_fun, "length"), do: 0
  def proto_property({:bound, _, {:builtin, name, _}, _, _}, "name"), do: name
  def proto_property(_fun, "name"), do: ""

  def proto_property(fun, "toString") do
    {:builtin, "toString",
     fn _, _ ->
       case fun do
         {:closure, _, %QuickBEAM.VM.Function{source: src}} when is_binary(src) and src != "" ->
           src

         %QuickBEAM.VM.Function{source: src} when is_binary(src) and src != "" ->
           src

         {:builtin, name, _} ->
           "function #{name}() { [native code] }"

         {:bound, _, _, _, _} ->
           "function () { [native code] }"

         _ ->
           "function () { [native code] }"
       end
     end}
  end

  def proto_property(fun, "caller") do
    if strict_function?(fun) or bound_function?(fun) or strict_active_caller?(fun) do
      throw(
        {:js_throw,
         Heap.make_error(
           "'caller' and 'arguments' are restricted function properties and cannot be accessed in this context.",
           "TypeError"
         )}
      )
    else
      :undefined
    end
  end

  def proto_property(fun, "arguments") do
    if strict_function?(fun) or bound_function?(fun) do
      throw(
        {:js_throw,
         Heap.make_error(
           "'caller' and 'arguments' are restricted function properties and cannot be accessed in this context.",
           "TypeError"
         )}
      )
    else
      :undefined
    end
  end

  def proto_property(_fun, "constructor") do
    case Heap.get_ctx() do
      %{globals: globals} -> Map.get(globals, "Function", :undefined)
      _ -> :undefined
    end
  end

  def proto_property(_fun, _), do: :undefined

  defp strict_function?(%QuickBEAM.VM.Function{is_strict_mode: true}), do: true
  defp strict_function?({:closure, _, %QuickBEAM.VM.Function{is_strict_mode: true}}), do: true
  defp strict_function?(_), do: false

  defp strict_active_caller?(fun) do
    fun = raw_function(fun)

    Trace.get_frames()
    |> Enum.map(& &1.fun)
    |> caller_after(fun)
    |> strict_function?()
  end

  defp caller_after([current, caller | rest], fun) do
    cond do
      raw_function(current) != fun -> caller_after([caller | rest], fun)
      predefined_frame?(caller) -> caller_after([caller | rest], fun)
      true -> caller
    end
  end

  defp caller_after([_], _fun), do: nil
  defp caller_after([], _fun), do: nil

  defp predefined_frame?(%QuickBEAM.VM.Function{name: {:predefined, _}}), do: true
  defp predefined_frame?({:closure, _, %QuickBEAM.VM.Function{name: {:predefined, _}}}), do: true
  defp predefined_frame?(_), do: false

  defp raw_function({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: fun
  defp raw_function(fun), do: fun

  defp bound_function?({:bound, _, _, _, _}), do: true
  defp bound_function?(_), do: false

  defp fn_call(fun, [this_arg | args], _this), do: invoke_fun(fun, args, this_arg)
  defp fn_call(fun, [], _this), do: invoke_fun(fun, [], :undefined)

  defp fn_apply(fun, [this_arg | rest], _this) do
    invoke_fun(fun, apply_args(List.first(rest)), this_arg)
  end

  defp fn_apply(fun, [], _this), do: invoke_fun(fun, [], :undefined)

  defp apply_args(value) when value in [nil, :undefined], do: []

  defp apply_args({:obj, ref} = obj) do
    case Heap.get_obj(ref, []) do
      {:qb_arr, arr} -> :array.to_list(arr)
      list when is_list(list) -> list
      _ -> array_like_args(obj)
    end
  end

  defp apply_args({:qb_arr, arr}), do: :array.to_list(arr)
  defp apply_args(list) when is_list(list), do: list
  defp apply_args(%QuickBEAM.VM.Function{} = value), do: array_like_args(value)
  defp apply_args({:closure, _, %QuickBEAM.VM.Function{}} = value), do: array_like_args(value)
  defp apply_args({:bound, _, _, _, _} = value), do: array_like_args(value)
  defp apply_args({:builtin, _, _} = value), do: array_like_args(value)

  defp apply_args(_value),
    do: QuickBEAM.VM.JSThrow.type_error!("CreateListFromArrayLike called on non-object")

  defp array_like_args(value) do
    length = value |> Get.get("length") |> QuickBEAM.VM.Runtime.to_number()
    length = if is_number(length) and length > 0, do: trunc(length), else: 0

    for index <- 0..(length - 1)//1 do
      Get.get(value, Integer.to_string(index))
    end
  end

  defp fn_bind(fun, [this_arg | bound_args], _this) do
    orig_len = bind_target_length(fun)
    orig_name = bind_target_name(fun)

    bound_len = bound_length(orig_len, length(bound_args))
    bound_fn = fn args, _this2 -> invoke_fun(fun, bound_args ++ args, this_arg) end
    {:bound, bound_len, {:builtin, "bound " <> orig_name, bound_fn}, fun, bound_args}
  end

  defp fn_bind(fun, [], _this) do
    orig_len = bind_target_length(fun)
    orig_name = bind_target_name(fun)

    bound_fn = fn args, _this2 -> invoke_fun(fun, args, :undefined) end
    {:bound, orig_len, {:builtin, "bound " <> orig_name, bound_fn}, fun, []}
  end

  defp bind_target_length(fun) do
    case Get.get(fun, "length") do
      n when is_number(n) -> integer_or_infinity(n)
      :infinity -> :infinity
      :neg_infinity -> 0
      _ -> 0
    end
  end

  defp bind_target_name(fun) do
    case Get.get(fun, "name") do
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  defp integer_or_infinity(n) when is_integer(n), do: n
  defp integer_or_infinity(n) when is_float(n), do: trunc(n)

  defp bound_length(:infinity, _argc), do: :infinity
  defp bound_length(n, argc) when is_number(n), do: max(0, n - argc)

  defp invoke_fun(fun, args, this_arg) do
    case fun do
      %QuickBEAM.VM.Function{} ->
        Invocation.invoke_with_receiver(fun, args, coerce_function_this(fun, this_arg))

      {:closure, _, %QuickBEAM.VM.Function{}} ->
        Invocation.invoke_with_receiver(fun, args, coerce_function_this(fun, this_arg))

      {:builtin, _, _} = builtin ->
        if Test262.realm_global(builtin) do
          Builtin.call(builtin, args, coerce_function_this(builtin, this_arg))
        else
          Builtin.call(builtin, args, this_arg)
        end

      other ->
        Builtin.call(other, args, this_arg)
    end
  end

  defp coerce_function_this(fun, this_arg) do
    if strict_function?(fun) do
      this_arg
    else
      case this_arg do
        value when value in [nil, :undefined] ->
          Test262.realm_global(fun) || value

        value when is_binary(value) or is_number(value) or is_boolean(value) ->
          wrap_function_this(fun, value)

        {:bigint, _} = value ->
          wrap_function_this(fun, value)

        {:symbol, _} = value ->
          wrap_function_this(fun, value)

        {:symbol, _, _} = value ->
          wrap_function_this(fun, value)

        _ ->
          this_arg
      end
    end
  end

  defp wrap_function_this(fun, value) do
    type = WrappedPrimitive.type_for_value(value)
    proto = Test262.realm_intrinsic(fun, type)

    case proto do
      {:obj, _} -> Heap.wrap(%{WrappedPrimitive.slot(type) => value, "__proto__" => proto})
      _ -> WrappedPrimitive.wrap(value)
    end
  end
end
