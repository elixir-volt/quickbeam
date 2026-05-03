defmodule QuickBEAM.VM.Compiler.RuntimeHelpers do
  @moduledoc "Runtime support for JIT-compiled code."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]
  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Builtin, Bytecode, GlobalEnv, Heap, Invocation, JSThrow, Names}
  alias QuickBEAM.VM.Compiler.Runner
  alias QuickBEAM.VM.Environment.Captures
  alias QuickBEAM.VM.Interpreter.{Closures, Context, Values}
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext

  alias QuickBEAM.VM.ObjectModel.{
    Class,
    Copy,
    Delete,
    Functions,
    Get,
    Methods,
    Private,
    Put,
    Static
  }

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Collections

  # ── Coercion ──

  @tdz :__tdz__

  @doc "Returns a dirty interpreter context suitable for entry into compiled code."
  def entry_ctx do
    case Heap.get_ctx() do
      %Context{} = ctx ->
        Context.mark_dirty(ctx)

      map when is_map(map) ->
        map |> context_struct() |> Context.mark_dirty()

      _ ->
        %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}
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

  def to_object(:undefined), do: JSThrow.type_error!("Cannot convert undefined to object")
  def to_object(nil), do: JSThrow.type_error!("Cannot convert null to object")
  def to_object(value), do: value

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

    QuickBEAM.VM.ObjectModel.Put.has_property(obj, Names.normalize_property_key(key))
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

  def ensure_capture_cell(_ctx \\ nil, cell, val), do: Captures.ensure(cell, val)
  def close_capture_cell(_ctx \\ nil, cell, val), do: Captures.close(cell, val)
  def sync_capture_cell(_ctx \\ nil, cell, val), do: Captures.sync(cell, val)
  def read_capture_cell(_ctx \\ nil, cell, slot_val), do: Captures.read(cell, slot_val)

  @doc "Resolves an awaited JavaScript value for compiled async code."
  def await(_ctx \\ nil, val), do: QuickBEAM.VM.Interpreter.resolve_awaited(val)

  def context_struct(%Context{} = ctx), do: ctx

  def context_struct(map) when is_map(map) do
    struct(Context, Map.merge(Map.from_struct(%Context{}), map))
  end

  @doc "Returns the atom table from a context-like value."
  def context_atoms(%{atoms: atoms}), do: atoms
  def context_atoms(_), do: {}
  def context_globals(%{globals: globals}), do: globals
  def context_globals(_), do: GlobalEnv.base_globals()
  def context_current_func(%{current_func: current_func}), do: current_func
  def context_current_func(_), do: :undefined
  def context_arg_buf(%{arg_buf: arg_buf}), do: arg_buf
  def context_arg_buf(_), do: {}
  @doc "Returns the JavaScript `this` value from a context-like value."
  def context_this(%{this: this}), do: this
  def context_this(_), do: :undefined
  def context_new_target(%{new_target: new_target}), do: new_target
  def context_new_target(_), do: :undefined
  def context_gas(%{gas: gas}), do: gas
  def context_gas(_), do: Context.default_gas()

  def ensure_context(%Context{} = ctx), do: ctx
  def ensure_context(map) when is_map(map), do: context_struct(map)

  def ensure_context(_),
    do: %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}

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

  # ── Variables ──

  @doc "Reads a variable binding or throws a JavaScript ReferenceError when absent."
  def get_var(ctx, name) when is_binary(name), do: fetch_ctx_var(ctx, name)

  def get_var(ctx, atom_idx),
    do: fetch_ctx_var(ctx, Names.resolve_atom(context_atoms(ctx), atom_idx))

  def get_global(globals, name) do
    case fetch_global_binding(globals, name) do
      {:ok, val} -> val
      :error -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  @doc "Reads a global binding and returns `:undefined` when absent."
  def get_global_undef(globals, name) do
    case fetch_global_binding(globals, name) do
      {:ok, val} -> val
      :error -> :undefined
    end
  end

  def get_var_undef(ctx, name) when is_binary(name),
    do: GlobalEnv.get(context_globals(ctx), name, :undefined)

  def get_var_undef(ctx, atom_idx),
    do: get_var_undef(ctx, Names.resolve_atom(context_atoms(ctx), atom_idx))

  defp fetch_global_binding(globals, name) do
    persistent = Heap.get_persistent_globals() || %{}
    builtins = Heap.get_builtin_names() || MapSet.new()

    if not MapSet.member?(builtins, name) and Map.has_key?(persistent, name) do
      Map.fetch(persistent, name)
    else
      Map.fetch(globals, name)
    end
  end

  def delete_var(ctx, atom_idx) do
    name = Names.resolve_atom(context_atoms(ctx), atom_idx)
    builtins = Heap.get_builtin_names() || MapSet.new()

    case Map.fetch(context_globals(ctx), name) do
      {:ok, _value} when name in ["NaN", "undefined", "Infinity", "globalThis"] ->
        false

      {:ok, {:builtin, _, _}} ->
        true

      {:ok, _value} ->
        MapSet.member?(builtins, name)

      :error ->
        true
    end
  end

  @doc "Resolves an atom-table entry to its runtime value."
  def push_atom_value(ctx, atom_idx),
    do: Names.resolve_atom(context_atoms(ctx), atom_idx)

  def materialize_constant(_ctx, {:template_object, elems, raw}) do
    elems = template_elements(elems)
    raw_elements = template_raw_elements(raw, elems)

    raw_ref = make_ref()
    Heap.put_obj(raw_ref, template_object_map(raw_elements))

    ref = make_ref()
    Heap.put_obj(ref, Map.put(template_object_map(elems), "raw", {:obj, raw_ref}))
    {:obj, ref}
  end

  def materialize_constant(_ctx, value), do: value

  defp template_elements({:array, elems}) when is_list(elems), do: elems
  defp template_elements(elems) when is_list(elems), do: elems
  defp template_elements(value), do: [value]

  defp template_raw_elements(:undefined, elems), do: elems
  defp template_raw_elements({:template_object, raw, _}, _elems), do: template_elements(raw)
  defp template_raw_elements(raw, _elems), do: template_elements(raw)

  defp template_object_map(elems) do
    elems
    |> Enum.with_index()
    |> Enum.reduce(%{"length" => length(elems)}, fn {value, idx}, acc ->
      Map.put(acc, Integer.to_string(idx), value)
    end)
  end

  def private_symbol(_ctx, name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(ctx, atom_idx),
    do: Private.private_symbol(Names.resolve_atom(context_atoms(ctx), atom_idx))

  @doc "Reads the value referenced by a compiled variable reference."
  def get_var_ref(ctx, idx), do: read_var_ref(current_var_ref(ctx, idx))
  def get_var_ref_check(ctx, idx), do: checked_var_ref(ctx, idx)

  def get_capture(ctx, key) do
    case context_current_func(ctx) do
      {:closure, captured, _} -> read_var_ref(Map.get(captured, key, :undefined))
      _ -> :undefined
    end
  end

  @doc "Invokes a callable stored in a variable reference."
  def invoke_var_ref(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), args)

  def invoke_var_ref0(ctx, idx), do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [])

  def invoke_var_ref1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0])

  @doc "Invokes a callable variable reference with two arguments."
  def invoke_var_ref2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1])

  def invoke_var_ref3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), args)

  @doc "Checks and invokes a callable variable reference with no arguments."
  def invoke_var_ref_check0(ctx, idx),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [])

  def invoke_var_ref_check1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0])

  def invoke_var_ref_check2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1])

  @doc "Checks and invokes a callable variable reference with three arguments."
  def invoke_var_ref_check3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1, arg2])

  def put_var_ref(ctx, idx, val) do
    write_var_ref(current_var_ref(ctx, idx), val)
    :ok
  end

  @doc "Writes a value through a compiled variable reference and returns the value."
  def set_var_ref(ctx, idx, val) do
    put_var_ref(ctx, idx, val)
    val
  end

  def put_capture(ctx, key, val) do
    case context_current_func(ctx) do
      {:closure, captured, _} -> write_var_ref(Map.get(captured, key, :undefined), val)
      _ -> :ok
    end

    :ok
  end

  @doc "Writes a captured variable and returns the value."
  def set_capture(ctx, key, val) do
    put_capture(ctx, key, val)
    val
  end

  def make_var_ref(ctx, atom_idx) do
    {:global_ref, Names.resolve_atom(context_atoms(ctx), atom_idx)}
  end

  @doc "Returns or creates a mutable reference cell for an existing variable reference."
  def make_var_ref_ref(ctx, idx) do
    case current_var_ref(ctx, idx) do
      {:cell, _} = cell ->
        cell

      val ->
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}
    end
  end

  def get_var(name) when is_binary(name) do
    case GlobalEnv.fetch(name) do
      {:found, val} -> val
      :not_found -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  def get_var(atom_idx),
    do: get_var(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_var_undef(name) when is_binary(name), do: GlobalEnv.get(name, :undefined)

  def get_var_undef(atom_idx),
    do: get_var_undef(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def push_atom_value(atom_idx), do: Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)

  def private_symbol(name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(atom_idx),
    do: Private.private_symbol(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_var_ref(idx), do: read_var_ref(current_var_ref(idx))
  def get_var_ref_check(idx), do: checked_var_ref(idx)

  def invoke_var_ref(idx, args), do: Invocation.invoke_runtime(get_var_ref(idx), args)
  def invoke_var_ref0(idx), do: Invocation.invoke_runtime(get_var_ref(idx), [])
  def invoke_var_ref1(idx, arg0), do: Invocation.invoke_runtime(get_var_ref(idx), [arg0])

  def invoke_var_ref2(idx, arg0, arg1),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1])

  def invoke_var_ref3(idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(idx, args),
    do: Invocation.invoke_runtime(checked_var_ref(idx), args)

  def invoke_var_ref_check0(idx), do: Invocation.invoke_runtime(checked_var_ref(idx), [])

  def invoke_var_ref_check1(idx, arg0),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0])

  def invoke_var_ref_check2(idx, arg0, arg1),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0, arg1])

  def invoke_var_ref_check3(idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0, arg1, arg2])

  def put_var_ref(idx, val) do
    write_var_ref(current_var_ref(idx), val)
    :ok
  end

  def set_var_ref(idx, val) do
    put_var_ref(idx, val)
    val
  end

  @doc "Creates a mutable reference cell for a local slot value."
  def make_loc_ref(_ctx \\ nil, _idx) do
    ref = make_ref()
    Heap.put_cell(ref, :undefined)
    {:cell, ref}
  end

  def make_arg_ref(_ctx \\ nil, idx) do
    ref = make_ref()
    val = elem(InvokeContext.current_arg_buf(), idx)
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

  @doc "Reads the value from a reference cell or object-property reference."
  def get_ref_value(_ctx \\ nil, key, ref)
  def get_ref_value(_ctx, _key, {:cell, _} = cell), do: Closures.read_cell(cell)
  def get_ref_value(ctx, _key, {:global_ref, name}), do: get_var_undef(ctx, name)
  def get_ref_value(_ctx, key, obj) when is_binary(key), do: Get.get(obj, key)
  def get_ref_value(_ctx, _key, _), do: :undefined

  def put_ref_value(ctx \\ nil, val, key, ref)

  def put_ref_value(ctx, val, _key, {:cell, _} = cell) do
    Closures.write_cell(cell, val)
    ctx
  end

  def put_ref_value(ctx, val, _key, {:global_ref, name}) do
    GlobalEnv.put(ensure_context(ctx), name, val)
  end

  def put_ref_value(ctx, val, key, obj) when is_binary(key) do
    Put.put(obj, key, val)
    ctx
  end

  def put_ref_value(ctx, _val, _key, _), do: ctx

  @doc "Reads a variable from a compiled context or throws when absent."
  def fetch_ctx_var(ctx, name) do
    case GlobalEnv.fetch(context_globals(ctx), name) do
      {:found, val} -> val
      :not_found -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  # ── Objects ──

  @doc "Reads a JavaScript property value."
  def get_field(obj, key) when is_binary(key), do: Get.get(obj, key)

  def get_field(obj, atom_idx),
    do: Get.get(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_array_el2(_ctx \\ nil, obj, idx), do: {Get.get(obj, idx), obj}

  def get_private_field(_ctx, obj, key) do
    case Private.get_field(obj, key) do
      :missing -> throw({:js_throw, Private.brand_error()})
      val -> val
    end
  end

  @doc "Writes a JavaScript property value."
  def put_field(_ctx, obj, key, val) when is_binary(key), do: put_field(obj, key, val)

  def put_field(ctx, obj, atom_idx, val),
    do: put_field(obj, Names.resolve_atom(context_atoms(ctx), atom_idx), val)

  def put_field(obj, key, val) when is_binary(key) do
    Put.put(obj, key, val)
    :ok
  end

  def put_field(obj, atom_idx, val),
    do: put_field(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), val)

  @doc "Writes a JavaScript array element."
  def put_array_el(_ctx \\ nil, obj, idx, val) do
    Put.put_element(obj, idx, val)
    :ok
  end

  def define_array_el(_ctx \\ nil, obj, idx, val), do: Put.define_array_el(obj, idx, val)

  def define_field(_ctx, obj, key, val) when is_binary(key), do: define_field(obj, key, val)

  def define_field(ctx, obj, atom_idx, val),
    do: define_field(obj, Names.resolve_atom(context_atoms(ctx), atom_idx), val)

  def define_field(obj, key, val) when is_binary(key) do
    Put.put(obj, key, val)
    obj
  end

  def define_field(obj, atom_idx, val),
    do: define_field(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), val)

  @doc "Writes an existing private class field or throws when absent."
  def put_private_field(_ctx, obj, key, val) do
    case Private.put_field!(obj, key, val) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  def define_private_field(_ctx, obj, key, val) do
    case Private.define_field!(obj, key, val) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  @doc "Assigns a JavaScript function display name."
  def set_function_name(_ctx \\ nil, fun, name), do: Functions.rename(fun, name)

  def set_function_name_atom(ctx, fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, context_atoms(ctx))

  def set_function_name_atom(fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, InvokeContext.current_atoms())

  @doc "Assigns a function display name from a computed property value."
  def set_function_name_computed(_ctx \\ nil, fun, name_val),
    do: Functions.set_name_computed(fun, name_val)

  def set_home_object(_ctx \\ nil, method, target), do: Methods.set_home_object(method, target)

  def get_super(ctx, func) do
    if context_home_object(ctx, context_current_func(ctx)) == func,
      do: context_super(ctx),
      else: Class.get_super(func)
  end

  def get_super(func) do
    case InvokeContext.fast_ctx() do
      {_atoms, _globals, _current_func, _arg_buf, _this, _new_target, ^func, super} ->
        super

      _ ->
        if InvokeContext.current_home_object(InvokeContext.current_func()) == func,
          do: InvokeContext.current_super(),
          else: Class.get_super(func)
    end
  end

  @doc "Copies enumerable object-spread properties."
  def copy_data_properties(_ctx \\ nil, target, source, exclude \\ nil) do
    Copy.copy_data_properties(target, source, exclude)
    target
  end

  def new_object(_ctx \\ nil) do
    object_proto = Heap.get_object_prototype()
    init = if object_proto, do: %{proto() => object_proto}, else: %{}
    Heap.wrap(init)
  end

  @doc "Converts an iterable or array-like value to a JavaScript array object."
  def array_from(_ctx \\ nil, list), do: Heap.wrap(list)

  def delete_property(ctx \\ nil, obj, key)

  def delete_property(ctx, obj, key) when is_map(ctx) or is_struct(ctx) do
    key_str = if is_binary(key), do: key, else: Values.stringify(key)

    if obj == context_this(ctx) and Map.has_key?(context_globals(ctx), key_str) do
      case Map.fetch!(context_globals(ctx), key_str) do
        {:builtin, _, _} -> true
        _ -> false
      end
    else
      delete_property(nil, obj, key)
    end
  end

  def delete_property(_ctx, {:builtin, _name, map} = fun, key) when is_map(map),
    do: Static.delete_static(fun, key)

  def delete_property(_ctx, {:builtin, _name, _} = fun, key), do: Static.delete_static(fun, key)
  def delete_property(_ctx, {:closure, _, _} = fun, key), do: Static.delete_static(fun, key)
  def delete_property(_ctx, %Bytecode.Function{} = fun, key), do: Static.delete_static(fun, key)
  def delete_property(_ctx, obj, key), do: Delete.delete_property(obj, key)

  def set_proto(_ctx \\ nil, obj, proto)

  def set_proto(_ctx, {:obj, ref} = _obj, proto) do
    map = Heap.get_obj(ref, %{})
    if is_map(map), do: Heap.put_obj(ref, Map.put(map, proto(), proto))
    :ok
  end

  def set_proto(_ctx, _obj, _proto), do: :ok

  # ── Functions ──

  @doc "Constructs a JavaScript value from compiled code."
  def construct_runtime(ctx, ctor, new_target, args),
    do: Invocation.construct_runtime(ctx, ctor, new_target, args)

  def construct_runtime(ctx, ctor, new_target, args, call_pc) do
    previous = Process.get(:qb_constructor_call_stack)
    Process.put(:qb_constructor_call_stack, compiled_stack(ctx, call_pc))

    try do
      construct_runtime(ctx, ctor, new_target, args)
    after
      if previous,
        do: Process.put(:qb_constructor_call_stack, previous),
        else: Process.delete(:qb_constructor_call_stack)
    end
  end

  def construct_runtime(ctor, new_target, args),
    do: Invocation.construct_runtime(ctor, new_target, args)

  def check_ctor_return(ctx, val) do
    case Class.check_ctor_return(val) do
      {replace_with_this?, checked_val} ->
        {replace_with_this?, checked_val}

      :error ->
        throw(
          {:js_throw,
           make_error_with_ctx(
             ctx,
             "Derived constructors may only return object or undefined",
             "TypeError",
             Process.get(:qb_constructor_call_stack)
           )}
        )
    end
  end

  def init_ctor(ctx) do
    current_func = context_current_func(ctx)

    raw =
      case current_func do
        {:closure, _, %Bytecode.Function{} = f} -> f
        %Bytecode.Function{} = f -> f
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

        %Bytecode.Function{} = f ->
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

        {:closure, _, %Bytecode.Function{}} = closure ->
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
        %Bytecode.Function{} = fun -> {:closure, %{}, fun}
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
        %Bytecode.Function{} = fun -> {:closure, %{}, fun}
        other -> other
      end

    Class.define_class(
      ctor_closure,
      parent_ctor,
      Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)
    )
  end

  @doc "Defines a method, getter, or setter from compiled code."
  def define_method(_ctx, target, method, name, flags) when is_binary(name),
    do: define_method(target, method, name, flags)

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
  def throw_error(ctx, atom_idx, reason) do
    name = Names.resolve_atom(context_atoms(ctx), atom_idx)
    {error_type, message} = throw_error_message(name, reason)
    throw({:js_throw, Heap.make_error(message, error_type)})
  end

  def throw_error_message(name, reason) do
    case reason do
      0 -> {"TypeError", "'#{name}' is read-only"}
      1 -> {"SyntaxError", "redeclaration of '#{name}'"}
      2 -> {"ReferenceError", "cannot access '#{name}' before initialization"}
      3 -> {"ReferenceError", "unsupported reference to 'super'"}
      4 -> {"TypeError", "iterator does not have a throw method"}
      _ -> {"Error", name}
    end
  end

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
  def special_object(ctx, type) do
    current_func = context_current_func(ctx)
    arg_buf = context_arg_buf(ctx)

    case type do
      0 -> Heap.wrap(Tuple.to_list(arg_buf))
      1 -> Heap.wrap(Tuple.to_list(arg_buf))
      2 -> current_func
      3 -> context_new_target(ctx)
      4 -> context_home_object(ctx, current_func)
      5 -> Heap.wrap(%{})
      6 -> Heap.wrap(%{})
      7 -> Heap.wrap(%{"__proto__" => nil})
      _ -> :undefined
    end
  end

  def special_object(type) do
    case InvokeContext.fast_ctx() do
      {_atoms, _globals, current_func, arg_buf, _this, new_target, home_object, _super} ->
        case type do
          0 -> Heap.wrap(Tuple.to_list(arg_buf))
          1 -> Heap.wrap(Tuple.to_list(arg_buf))
          2 -> current_func
          3 -> new_target
          4 -> home_object
          5 -> Heap.wrap(%{})
          6 -> Heap.wrap(%{})
          7 -> Heap.wrap(%{"__proto__" => nil})
          _ -> :undefined
        end

      _ ->
        current_func = InvokeContext.current_func()
        arg_buf = InvokeContext.current_arg_buf()

        case type do
          0 -> Heap.wrap(Tuple.to_list(arg_buf))
          1 -> Heap.wrap(Tuple.to_list(arg_buf))
          2 -> current_func
          3 -> InvokeContext.current_new_target()
          4 -> InvokeContext.current_home_object(current_func)
          5 -> Heap.wrap(%{})
          6 -> Heap.wrap(%{})
          7 -> Heap.wrap(%{"__proto__" => nil})
          _ -> :undefined
        end
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

    if object_like?(obj) do
      ctor_proto = Get.get(ctor, "prototype")

      case ctor_proto do
        {:obj, _} ->
          special_builtin_instance?(obj, ctor) or prototype_chain_contains?(obj, ctor_proto)

        _ ->
          JSThrow.type_error!(
            "Function has non-object prototype '#{Values.stringify(ctor_proto)}' in instanceof check"
          )
      end
    else
      false
    end
  end

  def get_length(obj), do: Get.length_of(obj)

  @doc "Loads a registered VM module by name."
  def import_module(ctx, specifier) do
    if is_binary(specifier) and Map.get(ctx, :runtime_pid) != nil do
      case QuickBEAM.Runtime.load_module(ctx.runtime_pid, specifier, "") do
        :ok ->
          QuickBEAM.VM.PromiseState.resolved(QuickBEAM.VM.Runtime.new_object())

        {:error, _} ->
          QuickBEAM.VM.PromiseState.rejected(
            make_error_with_ctx(ctx, "Cannot find module '#{specifier}'", "TypeError")
          )
      end
    else
      QuickBEAM.VM.PromiseState.rejected(
        make_error_with_ctx(ctx, "Invalid module specifier", "TypeError")
      )
    end
  end

  def import_module(_specifier) do
    QuickBEAM.VM.PromiseState.rejected(Heap.make_error("Invalid module specifier", "TypeError"))
  end

  defp object_like?({:obj, _}), do: true
  defp object_like?({:qb_arr, _}), do: true
  defp object_like?(value) when is_map(value), do: true
  defp object_like?(value) when is_list(value), do: true
  defp object_like?({:builtin, _, _}), do: true
  defp object_like?(%Bytecode.Function{}), do: true
  defp object_like?({:closure, _, %Bytecode.Function{}}), do: true
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
      "Array" -> match?({:qb_arr, _}, Heap.get_obj(ref)) or is_list(Heap.get_obj(ref))
      "Object" -> true
      _ -> false
    end
  end

  defp special_builtin_instance?(_, _), do: false

  defp make_error_with_ctx(ctx, message, name, stack_override \\ nil) do
    previous_ctx = Heap.get_ctx()
    Heap.put_ctx(ensure_context(ctx))

    try do
      Heap.make_error(message, name)
      |> ensure_compiled_stack(ctx, stack_override)
    after
      if previous_ctx, do: Heap.put_ctx(previous_ctx), else: Heap.put_ctx(nil)
    end
  end

  defp ensure_compiled_stack({:obj, ref} = error, ctx, stack_override) do
    stack = stack_override || compiled_stack(ctx)

    case Get.get(error, "stack") do
      "" ->
        Heap.update_obj(ref, %{}, &Map.put(&1, "stack", stack))
        error

      _ when stack_override != nil ->
        Heap.update_obj(ref, %{}, &Map.put(&1, "stack", stack))
        error

      _ ->
        error
    end
  end

  defp compiled_stack(ctx) do
    case context_current_func(ctx) do
      %Bytecode.Function{} = fun ->
        "    at #{fun.filename}:#{fun.line_num}:#{fun.col_num}"

      {:closure, _captures, %Bytecode.Function{} = fun} ->
        "    at #{fun.filename}:#{fun.line_num}:#{fun.col_num}"

      _ ->
        ""
    end
  end

  defp compiled_stack(ctx, pc) do
    case context_current_func(ctx) do
      %Bytecode.Function{} = fun -> stack_for_pc(fun, pc)
      {:closure, _captures, %Bytecode.Function{} = fun} -> stack_for_pc(fun, pc)
      _ -> ""
    end
  end

  defp stack_for_pc(%Bytecode.Function{} = fun, pc) do
    {line, col} = Bytecode.source_position(fun, pc)
    "    at #{fun.filename}:#{line}:#{col}"
  end

  def with_has_property(_ctx, obj, key), do: Static.with_has_property?(obj, key)

  # ── Iterators ──

  @doc "Creates iterator state for a JavaScript `for...of` loop."
  def for_of_start(ctx, obj) do
    case obj do
      list when is_list(list) ->
        {{:list_iter, list}, :undefined}

      {:obj, ref} = obj_ref ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, :array.to_list(arr)}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter(ctx, custom_fn, obj_ref)
            end

          list when is_list(list) ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, list}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter(ctx, custom_fn, obj_ref)
            end

          map when is_map(map) ->
            sym_iter = {:symbol, "Symbol.iterator"}

            cond do
              Map.has_key?(map, sym_iter) ->
                invoke_custom_iter(ctx, Map.get(map, sym_iter), obj_ref)

              Map.has_key?(map, "next") ->
                {obj_ref, Get.get(obj_ref, "next")}

              true ->
                {{:list_iter, []}, :undefined}
            end

          _ ->
            {{:list_iter, []}, :undefined}
        end

      s when is_binary(s) ->
        {{:list_iter, String.codepoints(s)}, :undefined}

      nil ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of null (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      :undefined ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of undefined (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      other ->
        throw(
          {:js_throw, Heap.make_error("#{Values.stringify(other)} is not iterable", "TypeError")}
        )
    end
  end

  def for_of_start(obj) do
    case obj do
      list when is_list(list) ->
        {{:list_iter, list}, :undefined}

      {:obj, ref} = obj_ref ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, :array.to_list(arr)}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter_ctxless(custom_fn, obj_ref)
            end

          list when is_list(list) ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, list}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter_ctxless(custom_fn, obj_ref)
            end

          map when is_map(map) ->
            sym_iter = {:symbol, "Symbol.iterator"}

            cond do
              Map.has_key?(map, sym_iter) ->
                invoke_custom_iter_ctxless(Map.get(map, sym_iter), obj_ref)

              Map.has_key?(map, "next") ->
                {obj_ref, Get.get(obj_ref, "next")}

              true ->
                {{:list_iter, []}, :undefined}
            end

          _ ->
            {{:list_iter, []}, :undefined}
        end

      s when is_binary(s) ->
        {{:list_iter, String.codepoints(s)}, :undefined}

      nil ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of null (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      :undefined ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of undefined (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      other ->
        throw(
          {:js_throw, Heap.make_error("#{Values.stringify(other)} is not iterable", "TypeError")}
        )
    end
  end

  @doc "Advances JavaScript `for...of` iterator state."
  def for_of_next(_ctx, _next_fn, :undefined), do: {true, :undefined, :undefined}

  def for_of_next(_ctx, _next_fn, {:list_iter, [head | tail]}),
    do: {false, head, {:list_iter, tail}}

  def for_of_next(_ctx, _next_fn, {:list_iter, []}), do: {true, :undefined, :undefined}

  def for_of_next(ctx, next_fn, iter_obj) do
    result = Invocation.call_callback(ctx, next_fn, [])
    done = Get.get(result, "done")
    value = Get.get(result, "value")

    if done == true do
      {true, :undefined, :undefined}
    else
      {false, value, iter_obj}
    end
  end

  def for_of_next(_next_fn, :undefined), do: {true, :undefined, :undefined}

  def for_of_next(_next_fn, {:list_iter, [head | tail]}),
    do: {false, head, {:list_iter, tail}}

  def for_of_next(_next_fn, {:list_iter, []}), do: {true, :undefined, :undefined}

  def for_of_next(next_fn, iter_obj) do
    result = Runtime.call_callback(next_fn, [])
    done = Get.get(result, "done")
    value = Get.get(result, "value")

    if done == true do
      {true, :undefined, :undefined}
    else
      {false, value, iter_obj}
    end
  end

  def iterator_next_result(_ctx \\ nil, next_fn, iter_obj, val)

  def iterator_next_result(_ctx, _next_fn, :undefined, _val),
    do: {Heap.wrap(%{"done" => true, "value" => :undefined}), :undefined}

  def iterator_next_result(_ctx, _next_fn, {:list_iter, [head | tail]}, _val),
    do: {Heap.wrap(%{"done" => false, "value" => head}), {:list_iter, tail}}

  def iterator_next_result(_ctx, _next_fn, {:list_iter, []}, _val),
    do: {Heap.wrap(%{"done" => true, "value" => :undefined}), :undefined}

  def iterator_next_result(_ctx, next_fn, iter_obj, val) do
    result = Runtime.call_callback(next_fn, [val])
    next_iter = if Get.get(result, "done") == true, do: :undefined, else: iter_obj
    {result, next_iter}
  end

  @doc "Creates key iteration state for a JavaScript `for...in` loop."
  def for_in_start(_ctx \\ nil, obj), do: {:for_in_iterator, enumerable_keys(obj), obj}

  def for_in_next(_ctx \\ nil, iter)

  def for_in_next(ctx, {:for_in_iterator, [key | rest_keys], obj}) do
    if Put.has_property(obj, key) do
      {false, key, {:for_in_iterator, rest_keys, obj}}
    else
      for_in_next(ctx, {:for_in_iterator, rest_keys, obj})
    end
  end

  def for_in_next(_ctx, {:for_in_iterator, []} = iter) do
    {true, :undefined, iter}
  end

  def for_in_next(_ctx, {:for_in_iterator, [], _obj} = iter) do
    {true, :undefined, iter}
  end

  def for_in_next(_ctx, iter), do: {true, :undefined, iter}

  @doc "Closes an iterator by calling its `return` method when present."
  def iterator_close(_ctx, :undefined), do: :ok
  def iterator_close(_ctx, {:list_iter, _}), do: :ok

  def iterator_close(ctx, iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      Invocation.invoke_method_runtime(ctx, return_fn, iter_obj, [])
    end

    :ok
  end

  def iterator_close(:undefined), do: :ok
  def iterator_close({:list_iter, _}), do: :ok

  def iterator_close(iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      Invocation.invoke_method_runtime(return_fn, iter_obj, [])
    end

    :ok
  end

  @doc "Collects remaining values from an iterator into a list."
  def collect_iterator(%Context{} = ctx, iter, next_fn) do
    do_collect(ctx, iter, next_fn, [])
  end

  def collect_iterator(iter, next_fn) do
    do_collect_ctxless(iter, next_fn, [])
  end

  @doc "Appends spread values into an array-like target."
  def append_spread(_ctx \\ nil, arr, idx, obj), do: Copy.append_spread(arr, idx, obj)

  def rest(ctx, start_idx) do
    arg_buf = context_arg_buf(ctx)

    rest_args =
      if start_idx < tuple_size(arg_buf) do
        Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
      else
        []
      end

    Heap.wrap(rest_args)
  end

  # ── Misc ──

  @doc "Returns whether a value is either `undefined` or `null`."
  def undefined_or_null?(val), do: val == :undefined or val == nil

  def set_name_computed(_ctx \\ nil, fun, name_val),
    do: Functions.set_name_computed(fun, name_val)

  # ── Private helpers ──

  defp current_var_ref(idx), do: current_var_ref(current_context(), idx)

  defp current_var_ref(ctx, idx) do
    case context_current_func(ctx) do
      {:closure, captured, %Bytecode.Function{} = fun} ->
        case capture_keys_tuple(fun) do
          keys when idx >= 0 and idx < tuple_size(keys) ->
            Map.get(captured, elem(keys, idx), :undefined)

          _ ->
            :undefined
        end

      _ ->
        :undefined
    end
  end

  defp capture_keys_tuple(%Bytecode.Function{closure_vars: vars} = fun) do
    case Heap.get_capture_keys(fun) do
      nil ->
        tuple = vars |> Enum.map(&closure_capture_key/1) |> List.to_tuple()
        Heap.put_capture_keys(fun, tuple)
        tuple

      cached ->
        cached
    end
  end

  defp read_var_ref({:cell, _} = cell), do: Closures.read_cell(cell)
  defp read_var_ref(other), do: other

  defp checked_var_ref(idx), do: checked_var_ref(current_context(), idx)

  defp checked_var_ref(ctx, idx) do
    case current_var_ref(ctx, idx) do
      :__tdz__ ->
        JSThrow.reference_error!(var_ref_error_message(ctx, idx))

      {:cell, _} = cell ->
        val = Closures.read_cell(cell)

        if val == :__tdz__ and var_ref_name(ctx, idx) == "this" and
             derived_this_uninitialized?(ctx) do
          JSThrow.reference_error!("this is not initialized")
        end

        val

      val ->
        val
    end
  end

  defp write_var_ref({:cell, _} = cell, val), do: Closures.write_cell(cell, val)
  defp write_var_ref(_, _), do: :ok

  defp var_ref_error_message(ctx, idx) do
    if var_ref_name(ctx, idx) == "this" and derived_this_uninitialized?(ctx) do
      "this is not initialized"
    else
      "Cannot access variable before initialization"
    end
  end

  defp var_ref_name(ctx, idx) do
    case context_current_func(ctx) do
      {:closure, _, %Bytecode.Function{closure_vars: vars}}
      when idx >= 0 and idx < length(vars) ->
        vars
        |> Enum.at(idx)
        |> Map.get(:name)
        |> Names.resolve_display_name(context_atoms(ctx))

      _ ->
        nil
    end
  end

  defp closure_capture_key(%{closure_type: type, var_idx: idx}), do: {type, idx}

  defp derived_this_uninitialized?(ctx) do
    case context_this(ctx) do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        true

      _ ->
        false
    end
  end

  defp current_context do
    case Heap.get_ctx() do
      %Context{} = ctx -> ctx
      map when is_map(map) -> context_struct(map)
      _ -> %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}
    end
  end

  defp prototype_chain_contains?({:obj, ref} = obj, target) do
    case Heap.get_obj(ref, %{}) do
      {:shape, _, _, _, parent} ->
        parent == target or prototype_chain_contains?(parent, target)

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

  defp do_collect(ctx, iter, next_fn, acc) do
    case for_of_next(ctx, next_fn, iter) do
      {true, _, _} -> Heap.wrap(Enum.reverse(acc))
      {false, val, new_iter} -> do_collect(ctx, new_iter, next_fn, [val | acc])
    end
  end

  defp do_collect_ctxless(iter, next_fn, acc) do
    case for_of_next(next_fn, iter) do
      {true, _, _} -> Heap.wrap(Enum.reverse(acc))
      {false, val, new_iter} -> do_collect_ctxless(new_iter, next_fn, [val | acc])
    end
  end

  defp enumerable_keys(obj), do: Copy.enumerable_keys(obj)

  defp check_array_proto_iterator({:obj, _ref}, _raw_ref),
    do: Collections.array_proto_iterator_status()

  defp invoke_custom_iter(_ctx, iter_fn, obj) do
    iter_obj = Invocation.invoke_with_receiver(iter_fn, [], Runtime.gas_budget(), obj)

    unless is_object(iter_obj) do
      throw(
        {:js_throw,
         Heap.make_error("Result of the Symbol.iterator method is not an object", "TypeError")}
      )
    end

    {iter_obj, Get.get(iter_obj, "next")}
  end

  defp invoke_custom_iter_ctxless(iter_fn, obj) do
    iter_obj = Invocation.invoke_with_receiver(iter_fn, [], Runtime.gas_budget(), obj)

    unless is_object(iter_obj) do
      throw(
        {:js_throw,
         Heap.make_error("Result of the Symbol.iterator method is not an object", "TypeError")}
      )
    end

    {iter_obj, Get.get(iter_obj, "next")}
  end
end
