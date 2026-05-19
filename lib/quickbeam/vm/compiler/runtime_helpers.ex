defmodule QuickBEAM.VM.Compiler.RuntimeHelpers do
  @moduledoc "Runtime support for BEAM-compiled JavaScript bytecode."

  import QuickBEAM.VM.Heap.Keys, only: [date_ms: 0, proto: 0]
  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{
    Builtin,
    GlobalEnvironment,
    Heap,
    Invocation,
    JSThrow,
    Names
  }

  alias QuickBEAM.VM.Compiler.Runner
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Errors
  alias QuickBEAM.VM.Execution.ConstructorStack
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext

  alias QuickBEAM.VM.ObjectModel.{
    Class,
    Copy,
    Functions,
    Get,
    Methods,
    Private,
    Static
  }

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Semantics.{Construction, Eval, PropertyAccess}

  # ── Coercion ──

  @tdz :__tdz__
  @generator_return_resume :__quickbeam_generator_return_resume__

  def generator_return_resume(value), do: {@generator_return_resume, value}
  def generator_resume_return?({@generator_return_resume, _value}), do: true
  def generator_resume_return?(_value), do: false
  def generator_resume_value({@generator_return_resume, value}), do: value
  def generator_resume_value(value), do: value

  @doc "Returns a dirty interpreter context suitable for entry into compiled code."
  def entry_ctx do
    case Heap.get_ctx() do
      %Context{} = ctx ->
        Context.mark_dirty(ctx)

      map when is_map(map) ->
        map |> context_struct() |> Context.mark_dirty()

      _ ->
        %Context{atoms: Heap.get_atoms(), globals: GlobalEnvironment.base_globals()}
        |> Context.mark_dirty()
    end
  end

  @doc "Raises a JavaScript ReferenceError when a local is still in the temporal dead zone."
  def ensure_initialized_local!(_ctx \\ nil, val) do
    if val == @tdz do
      throw(
        {:js_throw,
         Heap.make_error("Cannot access variable before initialization", "ReferenceError")}
      )
    end

    val
  end

  def to_property_key(value), do: PropertyAccess.to_property_key(value)

  def to_property_key(ctx, value),
    do: with_runtime_ctx(ctx, fn -> PropertyAccess.to_property_key(value) end)

  def to_property_key_for_access(ctx, receiver, key),
    do: with_runtime_ctx(ctx, fn -> PropertyAccess.to_property_key_for_access(receiver, key) end)

  def to_object(:undefined), do: JSThrow.type_error!("Cannot convert undefined to object")
  def to_object(nil), do: JSThrow.type_error!("Cannot convert null to object")
  def to_object(value), do: value

  defp with_runtime_ctx(nil, fun), do: fun.()

  defp with_runtime_ctx(ctx, fun) do
    previous_ctx = Heap.get_ctx()
    Heap.put_ctx(ctx)

    try do
      fun.()
    after
      if previous_ctx, do: Heap.put_ctx(previous_ctx), else: Heap.put_ctx(nil)
    end
  end

  @doc "Returns whether a value is JavaScript `undefined`."
  def undefined?(_ctx \\ nil, val), do: val == :undefined
  def null?(_ctx \\ nil, val), do: val == nil
  def typeof_is_undefined(_ctx \\ nil, val), do: val == :undefined or val == nil
  def typeof_is_function(_ctx \\ nil, val), do: Builtin.callable?(val)

  def strict_neq(_ctx \\ nil, a, b), do: not Values.strict_eq(a, b)

  def bit_not(_ctx \\ nil, a), do: Values.bnot(a)

  def in_operator(_ctx \\ nil, key, obj) do
    unless object_like?(obj) do
      JSThrow.type_error!("right-hand side of 'in' should be an object")
    end

    QuickBEAM.VM.ObjectModel.HasProperty.has_property?(obj, Names.normalize_property_key(key))
  end

  @doc "Applies JavaScript logical NOT."
  def lnot(_ctx \\ nil, a), do: not Values.truthy?(a)

  def inc(ctx \\ nil, value)
  def inc(_ctx, {:bigint, n}), do: {:bigint, n + 1}
  def inc(_ctx, a) when is_number(a), do: Values.add(a, 1)
  def inc(_ctx, a), do: Values.add(Values.to_number(a), 1)

  def dec(ctx \\ nil, value)
  def dec(_ctx, {:bigint, n}), do: {:bigint, n - 1}
  def dec(_ctx, a) when is_number(a), do: Values.sub(a, 1)
  def dec(_ctx, a), do: Values.sub(Values.to_number(a), 1)

  def post_inc(ctx \\ nil, value)
  def post_inc(_ctx, {:bigint, n} = old), do: {{:bigint, n + 1}, old}

  def post_inc(_ctx, a) do
    num = Values.to_number(a)
    {Values.add(num, 1), num}
  end

  @doc "Applies JavaScript postfix decrement and returns `{new_value, old_value}`."
  def post_dec(ctx \\ nil, value)
  def post_dec(_ctx, {:bigint, n} = old), do: {{:bigint, n - 1}, old}

  def post_dec(_ctx, a) do
    num = Values.to_number(a)
    {Values.sub(num, 1), num}
  end

  @doc "Resolves an awaited JavaScript value for compiled async code."
  def await(_ctx \\ nil, val), do: QuickBEAM.VM.Interpreter.resolve_awaited(val)

  defdelegate context_struct(ctx), to: RuntimeContext, as: :struct_context

  @doc "Returns the atom table from a context-like value."
  defdelegate context_atoms(ctx), to: RuntimeContext, as: :atoms
  defdelegate context_globals(ctx), to: RuntimeContext, as: :globals
  defdelegate context_current_func(ctx), to: RuntimeContext, as: :current_func
  defdelegate context_arg_buf(ctx), to: RuntimeContext, as: :arg_buf

  @doc "Returns the JavaScript `this` value from a context-like value."
  defdelegate context_this(ctx), to: RuntimeContext, as: :this
  defdelegate context_new_target(ctx), to: RuntimeContext, as: :new_target
  defdelegate context_gas(ctx), to: RuntimeContext, as: :gas
  defdelegate ensure_context(ctx), to: RuntimeContext, as: :ensure

  @doc "Returns the home object associated with the current function."
  def context_home_object(ctx, current_func) do
    case Map.get(ctx, :home_object, :undefined) do
      :undefined -> QuickBEAM.VM.ObjectModel.Functions.current_home_object(current_func)
      home_object -> home_object
    end
  end

  def context_super(ctx) do
    case Map.get(ctx, :super, :undefined) do
      :undefined ->
        QuickBEAM.VM.ObjectModel.Class.get_super(
          context_home_object(ctx, context_current_func(ctx))
        )

      super ->
        super
    end
  end

  # ── Functions ──

  @doc "Constructs a JavaScript value from compiled code."
  def construct_runtime(ctx, ctor, new_target, args),
    do: Invocation.construct_runtime(ctx, ctor, new_target, args)

  def construct_runtime(ctx, ctor, new_target, args, call_pc) do
    ConstructorStack.with_stack(Errors.compiled_stack(ctx, call_pc), fn ->
      construct_runtime(ctx, ctor, new_target, args)
    end)
  end

  def construct_runtime(ctor, new_target, args),
    do: Invocation.construct_runtime(ctor, new_target, args)

  def check_ctor_return(ctx, val) do
    case Construction.check_ctor_return(val) do
      {:ok, replace_with_this?, checked_val} ->
        {replace_with_this?, checked_val}

      {:error, message} ->
        throw(
          {:js_throw,
           Errors.make_error_with_ctx(ctx, message, "TypeError", ConstructorStack.get())}
        )
    end
  end

  def init_ctor(ctx) do
    current_func = context_current_func(ctx)

    raw =
      case current_func do
        {:closure, _, %QuickBEAM.VM.Function{} = f} -> f
        %QuickBEAM.VM.Function{} = f -> f
        other -> other
      end

    parent = Heap.get_parent_ctor(raw)
    args = Tuple.to_list(context_arg_buf(ctx))

    pending_this =
      case context_this(ctx) do
        {:uninitialized, {:obj, _} = obj} -> obj
        {:obj, _} = obj -> obj
        other -> other
      end

    parent_ctx = Context.mark_dirty(%{ensure_context(ctx) | this: pending_this})

    result =
      case parent do
        nil ->
          pending_this

        %QuickBEAM.VM.Function{} = f ->
          case Runner.invoke_constructor(
                 {:closure, %{}, f},
                 args,
                 pending_this,
                 context_new_target(ctx),
                 parent_ctx
               ) do
            {:ok, val} ->
              val

            :error ->
              Invocation.invoke_with_receiver(
                {:closure, %{}, f},
                args,
                context_gas(ctx),
                pending_this
              )
          end

        {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
          case Runner.invoke_constructor(
                 closure,
                 args,
                 pending_this,
                 context_new_target(ctx),
                 parent_ctx
               ) do
            {:ok, val} ->
              val

            :error ->
              Invocation.invoke_with_receiver(
                closure,
                args,
                context_gas(ctx),
                pending_this
              )
          end

        {:builtin, _name, cb} when is_function(cb, 2) ->
          cb.(args, pending_this)

        _ ->
          pending_this
      end

    result =
      case result do
        {:obj, _} = obj -> obj
        _ -> pending_this
      end

    Heap.put_ctx(Context.mark_dirty(%{parent_ctx | this: result}))
    result
  end

  @doc "Invokes a JavaScript callable from compiled code."
  def invoke_runtime(ctx, fun, args), do: Invocation.invoke_runtime(ctx, fun, args)
  def invoke_runtime(fun, args), do: Invocation.invoke_runtime(fun, args)

  def eval_or_call(ctx, fun, [code | _] = args) when is_binary(code) do
    if fun == ctx.globals["eval"] do
      eval_source(ctx, code)
    else
      Invocation.invoke_runtime(ctx, fun, args)
    end
  end

  def eval_or_call(ctx, fun, args), do: Invocation.invoke_runtime(ctx, fun, args)

  defp eval_source(ctx, code) do
    case simple_eval_delete_identifier(code, ctx) do
      {:ok, result} -> result
      :error -> compile_eval_source(ctx, code)
    end
  end

  defp compile_eval_source(ctx, code) do
    case compile_eval_program(ctx, code) do
      {:ok, program} ->
        run_eval_program(ctx, program)

      {:source_error, {:parse_error, errors}} ->
        throw({:js_throw, Heap.make_error(parse_error_message(errors), "SyntaxError")})

      {:source_error, msg} ->
        throw({:js_throw, Heap.make_error(inspect(msg), "SyntaxError")})
    end
  end

  defp compile_eval_program(%{runtime_pid: runtime_pid}, code)
       when is_pid(runtime_pid) do
    compile_native_eval_program(runtime_pid, code)
  end

  defp compile_eval_program(%{runtime_pid: runtime_pid}, code)
       when is_atom(runtime_pid) and not is_nil(runtime_pid) do
    compile_native_eval_program(runtime_pid, code)
  end

  defp compile_eval_program(_ctx, code), do: compile_source_eval_program(code)

  defp compile_native_eval_program(runtime_pid, code) do
    case QuickBEAM.Runtime.compile(runtime_pid, code, "<eval>") do
      {:ok, bytecode} ->
        case QuickBEAM.VM.BytecodeParser.decode(bytecode) do
          {:ok, program} -> {:ok, program}
          {:error, _decode_reason} -> compile_source_eval_program(code)
        end

      {:error, %QuickBEAM.JS.Error{} = error} ->
        throw({:js_throw, error})

      {:error, reason} ->
        throw({:js_throw, Heap.make_error(inspect(reason), "SyntaxError")})
    end
  end

  defp compile_source_eval_program(code) do
    case QuickBEAM.JS.Compiler.compile(code) do
      {:ok, program} -> {:ok, program}
      {:error, reason} -> {:source_error, reason}
    end
  end

  defp run_eval_program(ctx, program) do
    reject_eval_lexical_conflicts!(ctx, program.value)

    arguments = Bindings.get_var(ctx, "arguments")
    globals = Map.put(ctx.globals, "arguments", arguments)

    case QuickBEAM.VM.Interpreter.eval(
           program.value,
           [],
           %{
             gas: ctx.gas,
             runtime_pid: ctx.runtime_pid,
             globals: globals,
             this: ctx.this,
             arg_buf: ctx.arg_buf,
             current_func: ctx.current_func,
             new_target: ctx.new_target
           },
           program.atoms
         ) do
      {:ok, value} -> value
      {:error, {:js_throw, value}} -> throw({:js_throw, value})
      _ -> :undefined
    end
  end

  defp simple_eval_delete_identifier(code, ctx),
    do: Eval.simple_delete_identifier(code, context_globals(ctx))

  defp reject_eval_lexical_conflicts!(ctx, %QuickBEAM.VM.Function{} = eval_fun) do
    unless current_strict_mode?(ctx) do
      Eval.reject_lexical_conflicts!(ctx, declared_names(eval_fun), false)
    end
  end

  defp declared_names(%QuickBEAM.VM.Function{} = fun), do: Eval.declared_local_names(fun)

  defp current_strict_mode?(%Context{
         current_func: {:closure, _, %QuickBEAM.VM.Function{is_strict_mode: strict}}
       }),
       do: strict

  defp current_strict_mode?(%Context{
         current_func: %QuickBEAM.VM.Function{is_strict_mode: strict}
       }),
       do: strict

  defp current_strict_mode?(_ctx), do: false

  defp parse_error_message([%{message: message} | _]), do: message
  defp parse_error_message(_errors), do: "Syntax error"

  def invoke_method_runtime(ctx, fun, this_obj, args),
    do: Invocation.invoke_method_runtime(ctx, fun, this_obj, args)

  def invoke_method_runtime(fun, this_obj, args),
    do: Invocation.invoke_method_runtime(fun, this_obj, args)

  @doc "Invokes a tail-position JavaScript method from compiled code."
  def invoke_tail_method(ctx, fun, this_obj, args),
    do: Invocation.invoke_method_runtime(ctx, fun, this_obj, args)

  def define_class(ctx, ctor, parent_ctor, atom_idx) do
    ctor_closure =
      case ctor do
        %QuickBEAM.VM.Function{} = fun -> {:closure, %{}, fun}
        other -> other
      end

    Class.define_class(
      ctor_closure,
      parent_ctor,
      Names.resolve_atom(context_atoms(ctx), atom_idx)
    )
  end

  def define_class(ctor, parent_ctor, atom_idx) do
    ctor_closure =
      case ctor do
        %QuickBEAM.VM.Function{} = fun -> {:closure, %{}, fun}
        other -> other
      end

    Class.define_class(
      ctor_closure,
      parent_ctor,
      Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)
    )
  end

  def define_class_computed(_ctx, ctor, parent_ctor, computed_name) do
    ctor_closure =
      case ctor do
        %QuickBEAM.VM.Function{} = fun -> {:closure, %{}, fun}
        other -> other
      end

    Class.define_class(ctor_closure, parent_ctor, Functions.function_name(computed_name))
  end

  @doc "Defines a method, getter, or setter from compiled code."
  def define_method(_ctx, target, method, name, flags) when is_binary(name),
    do: Methods.define_method(target, method, name, flags)

  def define_method(_ctx, target, method, {:tagged_int, _} = atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        QuickBEAM.VM.ObjectModel.PropertyKey.normalize(atom_idx),
        flags
      )

  def define_method(ctx, target, method, atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        Names.resolve_atom(context_atoms(ctx), atom_idx),
        flags
      )

  def define_method(target, method, name, flags) when is_binary(name),
    do: Methods.define_method(target, method, name, flags)

  def define_method(target, method, {:tagged_int, _} = atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        QuickBEAM.VM.ObjectModel.PropertyKey.normalize(atom_idx),
        flags
      )

  def define_method(target, method, atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        Names.resolve_atom(InvokeContext.current_atoms(), atom_idx),
        flags
      )

  @doc "Defines a computed-name method, getter, or setter from compiled code."
  def define_method_computed(_ctx \\ nil, target, method, field_name, flags),
    do: Methods.define_method_computed(target, method, field_name, flags)

  def add_brand(_ctx \\ nil, target, brand), do: Private.add_brand(target, brand)

  def check_brand(_ctx, obj, brand) do
    case Private.ensure_brand(obj, brand) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  @doc "Throws a JavaScript error value."
  def throw_error(ctx, atom_idx, reason),
    do: Errors.throw(ctx, atom_idx, reason, &Names.resolve_atom(context_atoms(&1), &2))

  @doc "Applies a superclass constructor for `super(...)`."
  def apply_super(ctx, fun, new_target, args),
    do: Invocation.construct_runtime(ctx, fun, new_target, args)

  def apply_super(fun, new_target, args),
    do: Invocation.construct_runtime(fun, new_target, args)

  def push_this(ctx) do
    case context_this(ctx) do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        JSThrow.reference_error!("this is not initialized")

      this ->
        this
    end
  end

  def push_this do
    case InvokeContext.current_this() do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        JSThrow.reference_error!("this is not initialized")

      this ->
        this
    end
  end

  @doc "Creates special object forms used by compiled object/class bytecode."
  def special_object(ctx, type) when type in [0, 1], do: Bindings.get_var(ctx, "arguments")

  def special_object(ctx, type) do
    current_func = context_current_func(ctx)

    Construction.special_object(
      type,
      current_func,
      context_arg_buf(ctx),
      context_new_target(ctx),
      context_home_object(ctx, current_func)
    )
  end

  def special_object(type) do
    case InvokeContext.fast_ctx() do
      {_atoms, _globals, current_func, arg_buf, _this, new_target, home_object, _super, _ctx} ->
        Construction.special_object(type, current_func, arg_buf, new_target, home_object)

      _ ->
        current_func = InvokeContext.current_func()
        arg_buf = InvokeContext.current_arg_buf()

        Construction.special_object(
          type,
          current_func,
          arg_buf,
          InvokeContext.current_new_target(),
          InvokeContext.current_home_object(current_func)
        )
    end
  end

  @doc "Updates the active `this` value in a context."
  def update_this(ctx, this_val), do: Context.mark_dirty(%{ctx | this: this_val})

  def update_this(this_val) do
    case Heap.get_ctx() do
      %Context{} = ctx -> Context.mark_dirty(%{ctx | this: this_val})
      map when is_map(map) -> Context.mark_dirty(%{context_struct(map) | this: this_val})
      _ -> ensure_context(nil) |> Map.put(:this, this_val) |> Context.mark_dirty()
    end
  end

  @doc "Applies JavaScript `instanceof` semantics."
  def instanceof(obj, ctor) do
    has_instance = Get.get(ctor, {:symbol, "Symbol.hasInstance"})

    if has_instance != :undefined and has_instance != nil and Builtin.callable?(has_instance) do
      has_instance
      |> Invocation.invoke_with_receiver([obj], Runtime.gas_budget(), ctor)
      |> Values.truthy?()
    else
      ordinary_instanceof(obj, ctor)
    end
  end

  defp ordinary_instanceof(obj, ctor) do
    unless Builtin.callable?(ctor) or is_object(ctor) do
      JSThrow.type_error!("Right-hand side of instanceof is not callable")
    end

    unless callable_instanceof_target?(ctor) do
      JSThrow.type_error!("Right-hand side of instanceof is not callable")
    end

    cond do
      not object_like?(obj) ->
        false

      special_builtin_instance?(obj, ctor) ->
        true

      true ->
        ctor_proto = Get.get(ctor, "prototype")

        case ctor_proto do
          {:obj, _} ->
            prototype_chain_contains?(obj, ctor_proto)

          _ ->
            JSThrow.type_error!(
              "Function has non-object prototype '#{Values.stringify(ctor_proto)}' in instanceof check"
            )
        end
    end
  end

  def get_length(obj), do: Get.length_of(obj)

  @doc "Loads a registered VM module by name."
  def import_module(ctx, specifier) do
    if is_binary(specifier) and Map.get(ctx, :runtime_pid) != nil do
      case QuickBEAM.Runtime.load_module(ctx.runtime_pid, specifier, "") do
        :ok ->
          QuickBEAM.VM.Promise.resolved(QuickBEAM.VM.Runtime.new_object())

        {:error, _} ->
          QuickBEAM.VM.Promise.rejected(
            Errors.make_error_with_ctx(ctx, "Cannot find module '#{specifier}'", "TypeError")
          )
      end
    else
      QuickBEAM.VM.Promise.rejected(
        Errors.make_error_with_ctx(ctx, "Invalid module specifier", "TypeError")
      )
    end
  end

  def import_module(_specifier) do
    QuickBEAM.VM.Promise.rejected(Heap.make_error("Invalid module specifier", "TypeError"))
  end

  defp object_like?({:obj, _}), do: true
  defp object_like?({:qb_arr, _}), do: true
  defp object_like?(value) when is_map(value), do: true
  defp object_like?(value) when is_list(value), do: true
  defp object_like?({:builtin, _, _}), do: true
  defp object_like?(%QuickBEAM.VM.Function{}), do: true
  defp object_like?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp object_like?({:bound, _, _, _, _}), do: true
  defp object_like?(_), do: false

  defp callable_instanceof_target?({:builtin, _, map}) when is_map(map), do: false
  defp callable_instanceof_target?({:obj, ref}), do: Get.get({:obj, ref}, "call") != :undefined
  defp callable_instanceof_target?(ctor), do: Builtin.callable?(ctor)

  defp builtin_name({:builtin, name, _}), do: name
  defp builtin_name(_), do: nil

  defp special_builtin_instance?(obj, ctor) when not is_object(obj) do
    Builtin.callable?(obj) and builtin_name(ctor) in ["Function", "Object"]
  end

  defp special_builtin_instance?({:obj, ref}, ctor) do
    case builtin_name(ctor) do
      "Array" ->
        match?({:qb_arr, _}, Heap.get_obj(ref)) or is_list(Heap.get_obj(ref))

      "BigInt" ->
        match?(
          {:ok, _},
          QuickBEAM.VM.ObjectModel.WrappedPrimitive.value(Heap.get_obj(ref, %{}), :bigint)
        )

      name when is_binary(name) ->
        data = Heap.get_obj(ref, %{})

        typed_array_instance?(data, name) or
          (name == "Date" and Map.has_key?(data, date_ms()))

      "Object" ->
        true

      _ ->
        false
    end
  end

  defp special_builtin_instance?(_, _), do: false

  defp typed_array_instance?(%{"__typed_array__" => true, "__type__" => type}, constructor_name) do
    typed_array_constructor_type(constructor_name) == type
  end

  defp typed_array_instance?(_, _), do: false

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

  def with_has_property(_ctx, obj, key), do: Static.with_has_property?(obj, key)

  @doc "Appends spread values into an array-like target."
  def append_spread(_ctx \\ nil, arr, idx, obj), do: Copy.append_spread(arr, idx, obj)

  # ── Misc ──

  @doc "Returns whether a value is either `undefined` or `null`."
  def undefined_or_null?(val), do: val == :undefined or val == nil

  def set_name_computed(_ctx \\ nil, fun, name_val),
    do: Functions.set_name_computed(fun, name_val)

  # ── Private helpers ──

  defp prototype_chain_contains?({:obj, ref} = obj, target) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        if Map.has_key?(map, proto()) do
          case Map.get(map, proto()) do
            ^target -> true
            nil -> false
            :undefined -> false
            parent -> prototype_chain_contains?(parent, target)
          end
        else
          parent = Heap.get_object_prototype()

          cond do
            obj == parent -> false
            parent == target -> true
            true -> prototype_chain_contains?(parent, target)
          end
        end

      {:qb_arr, _} ->
        parent = Heap.get_array_proto(ref)
        parent == target or prototype_chain_contains?(parent, target)

      list when is_list(list) ->
        parent = Heap.get_array_proto(ref)
        parent == target or prototype_chain_contains?(parent, target)

      _ ->
        false
    end
  end

  defp prototype_chain_contains?(fun, target) when is_tuple(fun) or is_struct(fun) do
    parent = Class.get_super(fun)

    cond do
      parent == target -> true
      parent in [nil, :undefined] -> false
      true -> prototype_chain_contains?(parent, target)
    end
  end

  defp prototype_chain_contains?(_, _), do: false
end
