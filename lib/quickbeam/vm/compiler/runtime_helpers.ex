defmodule QuickBEAM.VM.Compiler.RuntimeHelpers do
  @moduledoc false

  import Bitwise, only: [bnot: 1]
  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.{Builtin, Bytecode, GlobalEnv, Heap, Invocation, Names}
  alias QuickBEAM.VM.Environment.Captures
  alias QuickBEAM.VM.Interpreter.{Closures, Context, Values}
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Class, Copy, Delete, Functions, Get, Methods, Private, Put}
  alias QuickBEAM.VM.Runtime

  @tdz :__tdz__

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

  def ensure_initialized_local!(_ctx, val), do: ensure_initialized_local!(val)
  def strict_neq(_ctx, a, b), do: strict_neq(a, b)
  def undefined?(_ctx, val), do: undefined?(val)
  def null?(_ctx, val), do: null?(val)
  def typeof_is_undefined(_ctx, val), do: typeof_is_undefined(val)
  def typeof_is_function(_ctx, val), do: typeof_is_function(val)
  def bit_not(_ctx, a), do: bit_not(a)
  def lnot(_ctx, a), do: lnot(a)
  def inc(_ctx, a), do: inc(a)
  def dec(_ctx, a), do: dec(a)
  def post_inc(_ctx, a), do: post_inc(a)
  def post_dec(_ctx, a), do: post_dec(a)

  def get_var(ctx, name) when is_binary(name), do: fetch_ctx_var(ctx, name)

  def get_var(ctx, atom_idx),
    do: fetch_ctx_var(ctx, Names.resolve_atom(context_atoms(ctx), atom_idx))

  def get_var_undef(ctx, name) when is_binary(name),
    do: GlobalEnv.get(context_globals(ctx), name, :undefined)

  def get_var_undef(ctx, atom_idx),
    do: get_var_undef(ctx, Names.resolve_atom(context_atoms(ctx), atom_idx))

  def push_atom_value(ctx, atom_idx), do: Names.resolve_atom(context_atoms(ctx), atom_idx)

  def private_symbol(_ctx, name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(ctx, atom_idx),
    do: Private.private_symbol(Names.resolve_atom(context_atoms(ctx), atom_idx))

  def new_object(_ctx), do: new_object()
  def array_from(_ctx, list), do: array_from(list)

  def get_var_ref(ctx, idx), do: read_var_ref(current_var_ref(ctx, idx))
  def get_var_ref_check(ctx, idx), do: checked_var_ref(ctx, idx)

  def invoke_var_ref(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), args)

  def invoke_var_ref0(ctx, idx), do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [])

  def invoke_var_ref1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0])

  def invoke_var_ref2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1])

  def invoke_var_ref3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), args)

  def invoke_var_ref_check0(ctx, idx),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [])

  def invoke_var_ref_check1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0])

  def invoke_var_ref_check2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1])

  def invoke_var_ref_check3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1, arg2])

  def put_var_ref(ctx, idx, val) do
    write_var_ref(current_var_ref(ctx, idx), val)
    :ok
  end

  def set_var_ref(ctx, idx, val) do
    put_var_ref(ctx, idx, val)
    val
  end

  def push_this(ctx) do
    case context_this(ctx) do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        throw({:js_throw, Heap.make_error("this is not initialized", "ReferenceError")})

      this ->
        this
    end
  end

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

  def get_super(ctx, func) do
    if context_home_object(ctx, context_current_func(ctx)) == func,
      do: context_super(ctx),
      else: Class.get_super(func)
  end

  def get_array_el2(_ctx, obj, idx), do: get_array_el2(obj, idx)
  def set_function_name(_ctx, fun, name), do: set_function_name(fun, name)

  def set_function_name_atom(ctx, fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, context_atoms(ctx))

  def set_function_name_computed(_ctx, fun, name_val),
    do: set_function_name_computed(fun, name_val)

  def put_field(_ctx, obj, key, val) when is_binary(key) do
    put_field(obj, key, val)
  end

  def put_field(ctx, obj, atom_idx, val),
    do: put_field(obj, Names.resolve_atom(context_atoms(ctx), atom_idx), val)

  def define_field(_ctx, obj, key, val) when is_binary(key), do: define_field(obj, key, val)

  def define_field(ctx, obj, atom_idx, val),
    do: define_field(obj, Names.resolve_atom(context_atoms(ctx), atom_idx), val)

  def put_array_el(_ctx, obj, idx, val), do: put_array_el(obj, idx, val)
  def define_array_el(_ctx, obj, idx, val), do: define_array_el(obj, idx, val)

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

  def define_method_computed(_ctx, target, method, field_name, flags),
    do: define_method_computed(target, method, field_name, flags)

  def set_home_object(_ctx, method, target), do: set_home_object(method, target)
  def add_brand(_ctx, target, brand), do: add_brand(target, brand)
  def append_spread(_ctx, arr, idx, obj), do: append_spread(arr, idx, obj)

  def copy_data_properties(_ctx, target, source) do
    copy_data_properties(target, source)
  end

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

  def invoke_runtime(ctx, fun, args), do: Invocation.invoke_runtime(ctx, fun, args)

  def invoke_method_runtime(ctx, fun, this_obj, args),
    do: Invocation.invoke_method_runtime(ctx, fun, this_obj, args)

  def construct_runtime(ctx, ctor, new_target, args),
    do: Invocation.construct_runtime(ctx, ctor, new_target, args)

  def for_of_start(ctx, obj) do
    case obj do
      list when is_list(list) ->
        {{:list_iter, list, 0}, :undefined}

      {:obj, ref} = obj_ref ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} ->
            {{:list_iter, :array.to_list(arr), 0}, :undefined}

          list when is_list(list) ->
            {{:list_iter, list, 0}, :undefined}

          map when is_map(map) ->
            sym_iter = {:symbol, "Symbol.iterator"}

            cond do
              Map.has_key?(map, sym_iter) ->
                iter_fn = Map.get(map, sym_iter)
                iter_obj = Invocation.call_callback(ctx, iter_fn, [])
                {iter_obj, Get.get(iter_obj, "next")}

              Map.has_key?(map, "next") ->
                {obj_ref, Get.get(obj_ref, "next")}

              true ->
                {{:list_iter, [], 0}, :undefined}
            end

          _ ->
            {{:list_iter, [], 0}, :undefined}
        end

      s when is_binary(s) ->
        {{:list_iter, String.codepoints(s), 0}, :undefined}

      _ ->
        {{:list_iter, [], 0}, :undefined}
    end
  end

  def for_in_start(_ctx, obj), do: for_in_start(obj)
  def for_in_next(_ctx, iter), do: for_in_next(iter)

  def for_of_next(_ctx, _next_fn, :undefined), do: {true, :undefined, :undefined}

  def for_of_next(_ctx, _next_fn, {:list_iter, list, idx}) do
    if idx < length(list) do
      {false, Enum.at(list, idx), {:list_iter, list, idx + 1}}
    else
      {true, :undefined, :undefined}
    end
  end

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

  def iterator_close(_ctx, :undefined), do: :ok
  def iterator_close(_ctx, {:list_iter, _, _}), do: :ok

  def iterator_close(ctx, iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      Invocation.call_callback(ctx, return_fn, [])
    end

    :ok
  end

  def delete_property(_ctx, obj, key), do: delete_property(obj, key)
  def ensure_capture_cell(_ctx, cell, val), do: ensure_capture_cell(cell, val)
  def close_capture_cell(_ctx, cell, val), do: close_capture_cell(cell, val)
  def sync_capture_cell(_ctx, cell, val), do: sync_capture_cell(cell, val)

  def set_proto(_ctx, obj, proto), do: set_proto(obj, proto)

  def get_private_field(_ctx, obj, key) do
    case Private.get_field(obj, key) do
      :missing -> throw({:js_throw, Private.brand_error()})
      val -> val
    end
  end

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

  def check_brand(_ctx, obj, brand) do
    case Private.ensure_brand(obj, brand) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
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
          Invocation.invoke_with_receiver(
            {:closure, %{}, f},
            args,
            context_gas(ctx),
            pending_this
          )

        {:closure, _, %Bytecode.Function{}} = closure ->
          Invocation.invoke_with_receiver(closure, args, context_gas(ctx), pending_this)

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

  def make_loc_ref(_ctx, idx), do: make_loc_ref(idx)
  def make_arg_ref(_ctx, idx), do: make_arg_ref(idx)

  def make_var_ref_ref(ctx, idx) do
    case current_var_ref(ctx, idx) do
      {:cell, _} = cell -> cell
      val ->
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}
    end
  end

  def get_ref_value(_ctx, ref), do: get_ref_value(ref)
  def put_ref_value(_ctx, val, ref), do: put_ref_value(val, ref)

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

  def throw_error(ctx, atom_idx, reason) do
    name = Names.resolve_atom(context_atoms(ctx), atom_idx)

    {error_type, message} =
      case reason do
        0 -> {"TypeError", "'#{name}' is read-only"}
        1 -> {"SyntaxError", "redeclaration of '#{name}'"}
        2 -> {"ReferenceError", "cannot access '#{name}' before initialization"}
        3 -> {"ReferenceError", "unsupported reference to 'super'"}
        4 -> {"TypeError", "iterator does not have a throw method"}
        _ -> {"Error", name}
      end

    throw({:js_throw, Heap.make_error(message, error_type)})
  end

  def ensure_initialized_local!(val) do
    if val == @tdz do
      throw(
        {:js_throw,
         Heap.make_error("Cannot access variable before initialization", "ReferenceError")}
      )
    end

    val
  end

  def strict_neq(a, b), do: not Values.strict_eq(a, b)

  def undefined?(val), do: val == :undefined
  def null?(val), do: val == nil
  def typeof_is_undefined(val), do: val == :undefined or val == nil
  def typeof_is_function(val), do: Builtin.callable?(val)

  def bit_not(a), do: Values.to_int32(bnot(Values.to_int32(a)))
  def lnot(a), do: not Values.truthy?(a)

  def inc(a), do: Values.add(a, 1)
  def dec(a), do: Values.sub(a, 1)

  def post_inc(a) do
    num = Values.to_number(a)
    {Values.add(num, 1), num}
  end

  def post_dec(a) do
    num = Values.to_number(a)
    {Values.sub(num, 1), num}
  end

  def get_var(name) when is_binary(name) do
    case GlobalEnv.fetch(name) do
      {:found, val} ->
        val

      :not_found ->
        throw({:js_throw, Heap.make_error("#{name} is not defined", "ReferenceError")})
    end
  end

  def get_var(atom_idx), do: get_var(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_var_undef(name) when is_binary(name), do: GlobalEnv.get(name, :undefined)

  def get_var_undef(atom_idx),
    do: get_var_undef(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def push_atom_value(atom_idx), do: Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)

  def private_symbol(name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(atom_idx),
    do: Private.private_symbol(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def new_object do
    object_proto = Heap.get_object_prototype()
    init = if object_proto, do: %{proto() => object_proto}, else: %{}
    Heap.wrap(init)
  end

  def array_from(list), do: Heap.wrap(list)

  def get_field(obj, key) when is_binary(key), do: Get.get(obj, key)

  def get_field(obj, atom_idx),
    do: Get.get(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_var_ref(idx), do: read_var_ref(current_var_ref(idx))

  def get_var_ref_check(idx), do: checked_var_ref(idx)

  def invoke_var_ref(idx, args), do: Invocation.invoke_runtime(get_var_ref(idx), args)
  def invoke_var_ref0(idx), do: Invocation.invoke_runtime(get_var_ref(idx), [])
  def invoke_var_ref1(idx, arg0), do: Invocation.invoke_runtime(get_var_ref(idx), [arg0])

  def invoke_var_ref2(idx, arg0, arg1),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1])

  def invoke_var_ref3(idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(idx, args), do: Invocation.invoke_runtime(checked_var_ref(idx), args)
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

  def push_this do
    case InvokeContext.current_this() do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        throw({:js_throw, Heap.make_error("this is not initialized", "ReferenceError")})

      this ->
        this
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

  def get_array_el2(obj, idx), do: {Get.get(obj, idx), obj}

  def set_function_name(fun, name), do: Functions.rename(fun, name)

  def set_function_name_atom(fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, InvokeContext.current_atoms())

  def set_function_name_computed(fun, name_val), do: Functions.set_name_computed(fun, name_val)

  def put_field(obj, key, val) when is_binary(key) do
    Put.put(obj, key, val)
    :ok
  end

  def put_field(obj, atom_idx, val),
    do: put_field(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), val)

  def define_field(obj, key, val) when is_binary(key) do
    Put.put(obj, key, val)
    obj
  end

  def define_field(obj, atom_idx, val),
    do: define_field(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), val)

  def put_array_el(obj, idx, val) do
    Put.put_element(obj, idx, val)
    :ok
  end

  def define_array_el(obj, idx, val), do: Put.define_array_el(obj, idx, val)

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

  def define_method_computed(target, method, field_name, flags),
    do: Methods.define_method_computed(target, method, field_name, flags)

  def set_home_object(method, target), do: Methods.set_home_object(method, target)

  def add_brand(target, brand), do: Private.add_brand(target, brand)

  def append_spread(arr, idx, obj), do: Copy.append_spread(arr, idx, obj)

  def copy_data_properties(target, source) do
    Copy.copy_data_properties(target, source)
    target
  end

  def construct_runtime(ctor, new_target, args),
    do: Invocation.construct_runtime(ctor, new_target, args)

  def instanceof({:obj, _} = obj, ctor) do
    ctor_proto = Get.get(ctor, "prototype")
    prototype_chain_contains?(obj, ctor_proto)
  end

  def instanceof(_obj, _ctor), do: false

  def delete_property(obj, key), do: Delete.delete_property(obj, key)

  def undefined_or_null?(val), do: val == :undefined or val == nil

  def ensure_capture_cell(cell, val), do: Captures.ensure(cell, val)
  def close_capture_cell(cell, val), do: Captures.close(cell, val)
  def sync_capture_cell(cell, val), do: Captures.sync(cell, val)

  def set_proto({:obj, ref} = _obj, proto) do
    map = Heap.get_obj(ref, %{})
    if is_map(map), do: Heap.put_obj(ref, Map.put(map, proto(), proto))
    :ok
  end

  def set_proto(_obj, _proto), do: :ok

  def make_loc_ref(_idx) do
    ref = make_ref()
    Heap.put_cell(ref, :undefined)
    {:cell, ref}
  end

  def make_arg_ref(idx) do
    ref = make_ref()
    val = elem(InvokeContext.current_arg_buf(), idx)
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

  def get_ref_value({:cell, _} = cell), do: Closures.read_cell(cell)
  def get_ref_value(_), do: :undefined

  def put_ref_value(val, {:cell, _} = cell) do
    Closures.write_cell(cell, val)
    val
  end

  def put_ref_value(val, _), do: val

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

  def invoke_runtime(fun, args), do: Invocation.invoke_runtime(fun, args)

  def invoke_method_runtime(fun, this_obj, args),
    do: Invocation.invoke_method_runtime(fun, this_obj, args)

  def await(_ctx, val), do: Interpreter.resolve_awaited(val)
  def await(val), do: Interpreter.resolve_awaited(val)

  def get_length(obj), do: Get.length_of(obj)

  def for_of_start(obj) do
    case obj do
      list when is_list(list) ->
        {{:list_iter, list, 0}, :undefined}

      {:obj, ref} = obj_ref ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} ->
            {{:list_iter, :array.to_list(arr), 0}, :undefined}

          list when is_list(list) ->
            {{:list_iter, list, 0}, :undefined}

          map when is_map(map) ->
            sym_iter = {:symbol, "Symbol.iterator"}

            cond do
              Map.has_key?(map, sym_iter) ->
                iter_fn = Map.get(map, sym_iter)
                iter_obj = Runtime.call_callback(iter_fn, [])
                {iter_obj, Get.get(iter_obj, "next")}

              Map.has_key?(map, "next") ->
                {obj_ref, Get.get(obj_ref, "next")}

              true ->
                {{:list_iter, [], 0}, :undefined}
            end

          _ ->
            {{:list_iter, [], 0}, :undefined}
        end

      s when is_binary(s) ->
        {{:list_iter, String.codepoints(s), 0}, :undefined}

      _ ->
        {{:list_iter, [], 0}, :undefined}
    end
  end

  def for_in_start(obj), do: {:for_in_iterator, enumerable_keys(obj)}

  def for_in_next({:for_in_iterator, [key | rest_keys]}) do
    {false, key, {:for_in_iterator, rest_keys}}
  end

  def for_in_next({:for_in_iterator, []} = iter) do
    {true, :undefined, iter}
  end

  def for_in_next(iter), do: {true, :undefined, iter}

  def for_of_next(_next_fn, :undefined), do: {true, :undefined, :undefined}

  def for_of_next(_next_fn, {:list_iter, list, idx}) do
    if idx < length(list) do
      {false, Enum.at(list, idx), {:list_iter, list, idx + 1}}
    else
      {true, :undefined, :undefined}
    end
  end

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

  def iterator_close(:undefined), do: :ok
  def iterator_close({:list_iter, _, _}), do: :ok

  def iterator_close(iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      Runtime.call_callback(return_fn, [])
    end

    :ok
  end

  defp enumerable_keys(obj), do: Copy.enumerable_keys(obj)

  defp prototype_chain_contains?(_, :undefined), do: false
  defp prototype_chain_contains?(_, nil), do: false

  defp prototype_chain_contains?({:obj, ref}, target) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, proto()) do
          ^target -> true
          nil -> false
          :undefined -> false
          parent -> prototype_chain_contains?(parent, target)
        end

      _ ->
        false
    end
  end

  defp prototype_chain_contains?(_, _), do: false

  defp current_var_ref(idx), do: current_var_ref(current_context(), idx)

  defp current_var_ref(ctx, idx) do
    case context_current_func(ctx) do
      {:closure, captured, %Bytecode.Function{closure_vars: vars}}
      when idx >= 0 and idx < length(vars) ->
        cv = Enum.at(vars, idx)
        Map.get(captured, closure_capture_key(cv), :undefined)

      _ ->
        :undefined
    end
  end

  defp read_var_ref({:cell, _} = cell), do: Closures.read_cell(cell)
  defp read_var_ref(other), do: other

  defp checked_var_ref(idx), do: checked_var_ref(current_context(), idx)

  defp checked_var_ref(ctx, idx) do
    case current_var_ref(ctx, idx) do
      :__tdz__ ->
        throw({:js_throw, Heap.make_error(var_ref_error_message(ctx, idx), "ReferenceError")})

      {:cell, _} = cell ->
        val = Closures.read_cell(cell)

        if val == :__tdz__ and var_ref_name(ctx, idx) == "this" and
             derived_this_uninitialized?(ctx) do
          throw({:js_throw, Heap.make_error("this is not initialized", "ReferenceError")})
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

  defp fetch_ctx_var(ctx, name) do
    case GlobalEnv.fetch(context_globals(ctx), name) do
      {:found, val} ->
        val

      :not_found ->
        throw({:js_throw, Heap.make_error("#{name} is not defined", "ReferenceError")})
    end
  end

  defp current_context do
    case Heap.get_ctx() do
      %Context{} = ctx -> ctx
      map when is_map(map) -> context_struct(map)
      _ -> %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}
    end
  end

  defp context_struct(%Context{} = ctx), do: ctx

  defp context_struct(map) when is_map(map) do
    struct(Context, Map.merge(Map.from_struct(%Context{}), map))
  end

  defp context_atoms(%{atoms: atoms}), do: atoms
  defp context_atoms(_), do: {}
  defp context_globals(%{globals: globals}), do: globals
  defp context_globals(_), do: GlobalEnv.base_globals()
  defp context_current_func(%{current_func: current_func}), do: current_func
  defp context_current_func(_), do: :undefined
  defp context_arg_buf(%{arg_buf: arg_buf}), do: arg_buf
  defp context_arg_buf(_), do: {}
  defp context_this(%{this: this}), do: this
  defp context_this(_), do: :undefined
  defp context_new_target(%{new_target: new_target}), do: new_target
  defp context_new_target(_), do: :undefined
  defp context_gas(%{gas: gas}), do: gas
  defp context_gas(_), do: Context.default_gas()

  defp ensure_context(%Context{} = ctx), do: ctx
  defp ensure_context(map) when is_map(map), do: context_struct(map)

  defp ensure_context(_),
    do: %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}

  defp context_home_object(ctx, current_func) do
    case Map.get(ctx, :home_object, :undefined) do
      :undefined -> Functions.current_home_object(current_func)
      home_object -> home_object
    end
  end

  defp context_super(ctx) do
    case Map.get(ctx, :super, :undefined) do
      :undefined -> Class.get_super(context_home_object(ctx, context_current_func(ctx)))
      super -> super
    end
  end
end
