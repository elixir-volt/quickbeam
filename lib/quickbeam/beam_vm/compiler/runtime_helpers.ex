defmodule QuickBEAM.BeamVM.Compiler.RuntimeHelpers do
  @moduledoc false

  import Bitwise, only: [bnot: 1]
  import QuickBEAM.BeamVM.Heap.Keys, only: [key_order: 0, map_data: 0, proto: 0, set_data: 0]

  alias QuickBEAM.BeamVM.{Builtin, Bytecode, Heap}
  alias QuickBEAM.BeamVM.Interpreter.{Scope, Values}
  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Runtime.Property

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

  def is_undefined(val), do: val == :undefined
  def is_null(val), do: val == nil
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

  def get_var(atom_idx) do
    globals = current_globals()
    name = atom_name(atom_idx)

    case Map.fetch(globals, name) do
      {:ok, val} -> val
      :error -> throw({:js_throw, Heap.make_error("#{name} is not defined", "ReferenceError")})
    end
  end

  def get_var_undef(atom_idx) do
    globals = current_globals()
    Map.get(globals, atom_name(atom_idx), :undefined)
  end

  def push_atom_value(atom_idx), do: atom_name(atom_idx)

  def new_object do
    object_proto = Heap.get_object_prototype()
    init = if object_proto, do: %{proto() => object_proto}, else: %{}
    Heap.wrap(init)
  end

  def array_from(list), do: Heap.wrap(list)

  def get_field(obj, atom_idx), do: Property.get(obj, atom_name(atom_idx))

  def put_field(obj, atom_idx, val) do
    QuickBEAM.BeamVM.Interpreter.Objects.put(obj, atom_name(atom_idx), val)
    :ok
  end

  def define_field(obj, atom_idx, val) do
    QuickBEAM.BeamVM.Interpreter.Objects.put(obj, atom_name(atom_idx), val)
    obj
  end

  def put_array_el(obj, idx, val) do
    QuickBEAM.BeamVM.Interpreter.Objects.put_element(obj, idx, val)
    :ok
  end

  def append_spread(arr, idx, obj) do
    src_list = spread_source_to_list(obj)
    arr_list = spread_target_to_list(arr)
    new_idx = if(is_integer(idx), do: idx, else: Runtime.to_int(idx)) + length(src_list)
    merged = arr_list ++ src_list

    merged_obj =
      case arr do
        {:obj, ref} ->
          Heap.put_obj(ref, merged)
          {:obj, ref}

        _ ->
          merged
      end

    {new_idx, merged_obj}
  end

  def copy_data_properties(target, source) do
    src_props = enumerable_string_props(source)

    case target do
      {:obj, ref} ->
        existing = Heap.get_obj(ref, %{})
        Heap.put_obj(ref, Map.merge(if(is_map(existing), do: existing, else: %{}), src_props))
        target

      _ ->
        target
    end
  end

  def construct_runtime(ctor, new_target, args) do
    raw_ctor = unwrap_constructor_target(ctor)
    raw_new_target = unwrap_new_target(new_target)

    ctor_proto =
      constructor_prototype(raw_new_target) || constructor_prototype(raw_ctor) ||
        Heap.get_object_prototype()

    init = if ctor_proto, do: %{proto() => ctor_proto}, else: %{}
    this_obj = Heap.wrap(init)

    result =
      case ctor do
        %Bytecode.Function{} = fun ->
          QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(
            fun,
            args,
            Runtime.gas_budget(),
            this_obj
          )

        {:closure, _, %Bytecode.Function{}} = closure ->
          QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(
            closure,
            args,
            Runtime.gas_budget(),
            this_obj
          )

        {:bound, _, _inner, orig_fun, bound_args} ->
          construct_runtime(orig_fun, new_target, bound_args ++ args)

        {:builtin, _name, cb} when is_function(cb, 2) ->
          cb.(args, this_obj)

        _ ->
          this_obj
      end

    case result do
      {:obj, _} = obj -> obj
      %Bytecode.Function{} = fun -> fun
      {:closure, _, %Bytecode.Function{}} = closure -> closure
      _ -> this_obj
    end
  end

  def instanceof({:obj, _} = obj, ctor) do
    ctor_proto = Property.get(ctor, "prototype")
    prototype_chain_contains?(obj, ctor_proto)
  end

  def instanceof(_obj, _ctor), do: false

  def delete_property(nil, key) do
    throw(
      {:js_throw,
       Heap.make_error("Cannot delete properties of null (deleting '#{key}')", "TypeError")}
    )
  end

  def delete_property(:undefined, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot delete properties of undefined (deleting '#{key}')",
         "TypeError"
       )}
    )
  end

  def delete_property({:obj, ref}, key) do
    map = Heap.get_obj(ref, %{})

    if is_map(map) do
      desc = Heap.get_prop_desc(ref, key)

      if match?(%{configurable: false}, desc) do
        false
      else
        Heap.put_obj(ref, Map.delete(map, key))
        true
      end
    else
      true
    end
  end

  def delete_property(_obj, _key), do: true

  def is_undefined_or_null(val), do: val == :undefined or val == nil

  def ensure_capture_cell({:cell, _} = cell, _val), do: cell

  def ensure_capture_cell(_cell, val) do
    ref = make_ref()
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

  def sync_capture_cell({:cell, ref}, val) do
    Heap.put_cell(ref, val)
    :ok
  end

  def sync_capture_cell(_, _), do: :ok

  def invoke_runtime(fun, args) do
    case fun do
      %Bytecode.Function{} ->
        QuickBEAM.BeamVM.Interpreter.invoke(fun, args, Runtime.gas_budget())

      {:closure, _, %Bytecode.Function{}} ->
        QuickBEAM.BeamVM.Interpreter.invoke(fun, args, Runtime.gas_budget())

      {:bound, _, inner, _, _} ->
        invoke_runtime(inner, args)

      other ->
        Builtin.call(other, args, nil)
    end
  end

  def invoke_method_runtime(fun, this_obj, args) do
    case fun do
      %Bytecode.Function{} ->
        QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(
          fun,
          args,
          Runtime.gas_budget(),
          this_obj
        )

      {:closure, _, %Bytecode.Function{}} ->
        QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(
          fun,
          args,
          Runtime.gas_budget(),
          this_obj
        )

      {:bound, _, inner, _, _} ->
        invoke_method_runtime(inner, this_obj, args)

      other ->
        Builtin.call(other, args, this_obj)
    end
  end

  def get_length(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} -> :array.size(arr)
          list when is_list(list) -> length(list)
          map when is_map(map) -> Map.get(map, "length", map_size(map))
          _ -> 0
        end

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      s when is_binary(s) ->
        Property.string_length(s)

      %Bytecode.Function{} = fun ->
        fun.defined_arg_count

      {:closure, _, %Bytecode.Function{} = fun} ->
        fun.defined_arg_count

      {:bound, len, _, _, _} ->
        len

      _ ->
        :undefined
    end
  end

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
                {iter_obj, Property.get(iter_obj, "next")}

              Map.has_key?(map, "next") ->
                {obj_ref, Property.get(obj_ref, "next")}

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
    done = Property.get(result, "done")
    value = Property.get(result, "value")

    if done == true do
      {true, :undefined, :undefined}
    else
      {false, value, iter_obj}
    end
  end

  def iterator_close(:undefined), do: :ok
  def iterator_close({:list_iter, _, _}), do: :ok

  def iterator_close(iter_obj) do
    return_fn = Property.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      Runtime.call_callback(return_fn, [])
    end

    :ok
  end

  defp spread_source_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  defp spread_source_to_list(list) when is_list(list), do: list

  defp spread_source_to_list({:obj, ref} = source_obj) do
    case Heap.get_obj(ref) do
      {:qb_arr, _} ->
        Heap.to_list(source_obj)

      list when is_list(list) ->
        list

      map when is_map(map) ->
        cond do
          Map.has_key?(map, {:symbol, "Symbol.iterator"}) ->
            iter_fn = Map.get(map, {:symbol, "Symbol.iterator"})
            iter_obj = Runtime.call_callback(iter_fn, [])
            collect_iterator_values(iter_obj, [])

          Map.has_key?(map, set_data()) ->
            Map.get(map, set_data(), [])

          Map.has_key?(map, map_data()) ->
            Map.get(map, map_data(), [])

          true ->
            []
        end

      _ ->
        []
    end
  end

  defp spread_source_to_list(_), do: []

  defp spread_target_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  defp spread_target_to_list(list) when is_list(list), do: list
  defp spread_target_to_list({:obj, _ref} = obj), do: Heap.to_list(obj)
  defp spread_target_to_list(_), do: []

  defp enumerable_string_props({:obj, ref} = source_obj) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, _} ->
        Enum.reduce(0..max(Heap.array_size(ref) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Property.get(source_obj, Integer.to_string(i)))
        end)

      list when is_list(list) ->
        Enum.reduce(0..max(length(list) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Property.get(source_obj, Integer.to_string(i)))
        end)

      map when is_map(map) ->
        map
        |> Map.keys()
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(fn k -> String.starts_with?(k, "__") and String.ends_with?(k, "__") end)
        |> Enum.reduce(%{}, fn k, acc -> Map.put(acc, k, Property.get(source_obj, k)) end)

      _ ->
        %{}
    end
  end

  defp enumerable_string_props(map) when is_map(map), do: map
  defp enumerable_string_props(_), do: %{}

  defp enumerable_keys({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, arr} ->
        numeric_index_keys(:array.size(arr))

      list when is_list(list) ->
        numeric_index_keys(length(list))

      map when is_map(map) ->
        own_keys = enumerable_object_keys(map, ref)
        proto_keys = enumerable_proto_keys(Map.get(map, proto()))
        Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys)))

      _ ->
        []
    end
  end

  defp enumerable_keys(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(fn key -> String.starts_with?(key, "__") and String.ends_with?(key, "__") end)
    |> Runtime.sort_numeric_keys()
  end

  defp enumerable_keys(list) when is_list(list), do: numeric_index_keys(length(list))
  defp enumerable_keys(s) when is_binary(s), do: numeric_index_keys(Property.string_length(s))
  defp enumerable_keys(_), do: []

  defp enumerable_object_keys(map, ref) do
    raw_keys =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> Map.keys(map)
      end

    raw_keys
    |> Enum.filter(&enumerable_key_candidate?/1)
    |> Enum.reject(fn key -> match?(%{enumerable: false}, Heap.get_prop_desc(ref, key)) end)
  end

  defp enumerable_proto_keys({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        own_keys = enumerable_object_keys(map, ref)
        parent_keys = enumerable_proto_keys(Map.get(map, proto()))
        own_keys ++ Enum.reject(parent_keys, &(&1 in own_keys))

      _ ->
        []
    end
  end

  defp enumerable_proto_keys(_), do: []

  defp enumerable_key_candidate?(key) when is_binary(key),
    do: not (String.starts_with?(key, "__") and String.ends_with?(key, "__"))

  defp enumerable_key_candidate?(_), do: false

  defp numeric_index_keys(size) when size <= 0, do: []
  defp numeric_index_keys(size), do: Enum.map(0..(size - 1), &Integer.to_string/1)

  defp collect_iterator_values(iter_obj, acc) do
    next_fn = Property.get(iter_obj, "next")
    step = Runtime.call_callback(next_fn, [])

    if Property.get(step, "done") do
      Enum.reverse(acc)
    else
      collect_iterator_values(iter_obj, [Property.get(step, "value") | acc])
    end
  end

  defp unwrap_constructor_target({:closure, _, %Bytecode.Function{} = fun}), do: fun
  defp unwrap_constructor_target({:bound, _, inner, _, _}), do: unwrap_constructor_target(inner)
  defp unwrap_constructor_target(other), do: other

  defp unwrap_new_target({:closure, _, %Bytecode.Function{} = fun}), do: fun
  defp unwrap_new_target(%Bytecode.Function{} = fun), do: fun
  defp unwrap_new_target(_), do: nil

  defp constructor_prototype(nil), do: nil

  defp constructor_prototype(target),
    do: normalize_constructor_prototype(Property.get(target, "prototype"))

  defp normalize_constructor_prototype({:obj, _} = object_proto), do: object_proto
  defp normalize_constructor_prototype(_), do: nil

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

  defp current_globals do
    case Heap.get_ctx() do
      %{globals: globals} -> globals
      _ -> Runtime.global_bindings()
    end
  end

  defp atom_name(atom_idx) do
    atoms =
      case Heap.get_ctx() do
        %{atoms: atoms} -> atoms
        _ -> Heap.get_atoms()
      end

    Scope.resolve_atom(atoms, atom_idx)
  end
end
