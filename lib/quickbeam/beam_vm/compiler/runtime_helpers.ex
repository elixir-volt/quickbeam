defmodule QuickBEAM.BeamVM.Compiler.RuntimeHelpers do
  @moduledoc false

  import Bitwise, only: [bnot: 1]
  import QuickBEAM.BeamVM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.BeamVM.{Builtin, Bytecode, GlobalEnv, Heap, Invocation, Names}
  alias QuickBEAM.BeamVM.Environment.Captures
  alias QuickBEAM.BeamVM.Interpreter.{Closures, Values}
  alias QuickBEAM.BeamVM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.BeamVM.ObjectModel.{Class, Copy, Delete, Functions, Get, Methods, Private, Put}
  alias QuickBEAM.BeamVM.Runtime

  @tdz :__tdz__

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

  def get_var_ref_check(idx) do
    case current_var_ref(idx) do
      :__tdz__ ->
        throw({:js_throw, Heap.make_error(var_ref_error_message(idx), "ReferenceError")})

      {:cell, _} = cell ->
        val = Closures.read_cell(cell)

        if val == :__tdz__ and var_ref_name(idx) == "this" and derived_this_uninitialized?() do
          throw({:js_throw, Heap.make_error("this is not initialized", "ReferenceError")})
        end

        val

      val ->
        val
    end
  end

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

  defp current_var_ref(idx) do
    case InvokeContext.current_func() do
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

  defp write_var_ref({:cell, _} = cell, val), do: Closures.write_cell(cell, val)
  defp write_var_ref(_, _), do: :ok

  defp var_ref_error_message(idx) do
    if var_ref_name(idx) == "this" and derived_this_uninitialized?() do
      "this is not initialized"
    else
      "Cannot access variable before initialization"
    end
  end

  defp var_ref_name(idx) do
    case InvokeContext.current_func() do
      {:closure, _, %Bytecode.Function{closure_vars: vars}}
      when idx >= 0 and idx < length(vars) ->
        vars
        |> Enum.at(idx)
        |> Map.get(:name)
        |> Names.resolve_display_name(InvokeContext.current_atoms())

      _ ->
        nil
    end
  end

  defp closure_capture_key(%{closure_type: type, var_idx: idx}), do: {type, idx}

  defp derived_this_uninitialized? do
    case InvokeContext.current_this() do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        true

      _ ->
        false
    end
  end
end
