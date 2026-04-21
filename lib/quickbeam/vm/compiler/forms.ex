defmodule QuickBEAM.VM.Compiler.Forms do
  @moduledoc false

  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.Get

  @line 1

  def compile_module(module, entry, ctx_entry, arity, slot_count, block_forms) do
    forms = [
      {:attribute, @line, :module, module},
      {:attribute, @line, :export, [{entry, arity}, {ctx_entry, arity + 1}]},
      entry_form(entry, ctx_entry, arity),
      ctx_entry_form(ctx_entry, arity, slot_count)
      | helper_forms() ++ block_forms
    ]

    case :compile.forms(forms, [:binary, :return_errors, :return_warnings]) do
      {:ok, mod, binary} -> {:ok, mod, binary}
      {:ok, mod, binary, _warnings} -> {:ok, mod, binary}
      {:error, errors, _warnings} -> {:error, {:compile_failed, errors}}
    end
  end

  defp entry_form(entry, ctx_entry, arity) do
    args = slot_vars(arity)
    body = [local_call(ctx_entry, [remote_call(RuntimeHelpers, :entry_ctx, []) | args])]
    {:function, @line, entry, arity, [{:clause, @line, args, [], body}]}
  end

  defp ctx_entry_form(ctx_entry, arity, slot_count) do
    ctx = var("Ctx")
    args = [ctx | slot_vars(arity)]

    locals =
      if slot_count <= arity,
        do: [],
        else: Enum.map(arity..(slot_count - 1), fn _ -> atom(:undefined) end)

    capture_cells =
      if slot_count == 0, do: [], else: Enum.map(1..slot_count, fn _ -> atom(:undefined) end)

    body = [local_call(block_name(0), [ctx | slot_vars(arity) ++ locals ++ capture_cells])]

    {:function, @line, ctx_entry, arity + 1, [{:clause, @line, args, [], body}]}
  end

  defp helper_forms do
    [
      add_helper(),
      guarded_binary_helper(:op_sub, :-, Values, :sub),
      guarded_binary_helper(:op_mul, :*, Values, :mul),
      guarded_binary_helper(:op_div, :/, Values, :div),
      guarded_binary_helper(:op_lt, :<, Values, :lt),
      guarded_binary_helper(:op_lte, :"=<", Values, :lte),
      guarded_binary_helper(:op_gt, :>, Values, :gt),
      guarded_binary_helper(:op_gte, :>=, Values, :gte),
      get_field_helper(),
      get_field_store_helper(),
      get_field_found_helper(),
      get_length_helper(),
      eq_helper(),
      neq_helper(),
      strict_eq_helper(),
      strict_neq_helper(),
      guarded_unary_helper(:op_neg, :-, Values, :neg),
      unary_fallback_helper(:op_plus, Values, :to_number)
    ]
  end

  defp add_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_add, 2,
     [
       {:clause, @line, [a, b], [integer_guards(a, b)], [{:op, @line, :+, a, b}]},
       {:clause, @line, [a, b], [binary_guards(a, b)], [binary_concat(a, b)]},
       {:clause, @line, [a, b], [], [remote_call(Values, :add, [a, b])]}
     ]}
  end

  defp guarded_binary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")
    b = var("B")

    {:function, @line, name, 2,
     [
       {:clause, @line, [a, b], [integer_guards(a, b)], [{:op, @line, op, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(fallback_mod, fallback_fun, [a, b])]}
     ]}
  end

  defp guarded_unary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")

    {:function, @line, name, 1,
     [
       {:clause, @line, [a], [[integer_guard(a)]], [{:op, @line, op, a}]},
       {:clause, @line, [a], [], [remote_call(fallback_mod, fallback_fun, [a])]}
     ]}
  end

  defp unary_fallback_helper(name, fallback_mod, fallback_fun) do
    a = var("A")

    {:function, @line, name, 1,
     [
       {:clause, @line, [a], [[integer_guard(a)]], [a]},
       {:clause, @line, [a], [], [remote_call(fallback_mod, fallback_fun, [a])]}
     ]}
  end

  defp get_field_helper do
    obj = var("Obj")
    ref = var("Ref")
    key = var("Key")
    wrapped = {:tuple, @line, [atom(:obj), ref]}

    {:function, @line, :op_get_field, 2,
     [
       {:clause, @line, [wrapped, key], [],
        [
          local_call(:op_get_field_from_store, [
            remote_call(QuickBEAM.VM.Heap, :get_obj, [ref]),
            wrapped,
            key
          ])
        ]},
       {:clause, @line, [obj, key], [], [remote_call(Get, :get, [obj, key])]}
     ]}
  end

  defp get_field_store_helper do
    map = var("Map")
    obj = var("Obj")
    key = var("Key")

    {:function, @line, :op_get_field_from_store, 3,
     [
       {:clause, @line, [map, obj, key], [map_proxy_guards(map)],
        [remote_call(Get, :get, [obj, key])]},
       {:clause, @line, [map, obj, key], [[map_guard(map)]],
        [local_call(:op_get_field_found, [remote_call(:maps, :find, [key, map]), obj, key])]},
       {:clause, @line, [map, obj, key], [], [remote_call(Get, :get, [obj, key])]}
     ]}
  end

  defp get_field_found_helper do
    getter = var("Getter")
    obj = var("Obj")
    key = var("Key")
    val = var("Val")

    {:function, @line, :op_get_field_found, 3,
     [
       {:clause, @line,
        [
          {:tuple, @line, [atom(:ok), {:tuple, @line, [atom(:accessor), getter, var("_")]}]},
          obj,
          key
        ], [[not_nil_guard(getter)]], [remote_call(Get, :call_getter, [getter, obj])]},
       {:clause, @line, [{:tuple, @line, [atom(:ok), val]}, obj, key], [], [val]},
       {:clause, @line, [atom(:error), obj, key], [], [remote_call(Get, :get, [obj, key])]}
     ]}
  end

  defp get_length_helper do
    a = var("A")
    arr = var("Arr")

    {:function, @line, :op_get_length, 1,
     [
       {:clause, @line, [{:tuple, @line, [atom(:qb_arr), arr]}], [],
        [remote_call(:array, :size, [arr])]},
       {:clause, @line, [a], [[list_guard(a)]], [remote_call(:erlang, :length, [a])]},
       {:clause, @line, [a], [[binary_guard(a)]], [remote_call(Get, :string_length, [a])]},
       {:clause, @line, [a], [], [remote_call(Get, :length_of, [a])]}
     ]}
  end

  defp eq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_eq, 2,
     [
       {:clause, @line, [a, b], [number_guards(a, b)], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(Values, :eq, [a, b])]}
     ]}
  end

  defp neq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_neq, 2,
     [
       {:clause, @line, [a, b], [], [{:op, @line, :not, local_call(:op_eq, [a, b])}]}
     ]}
  end

  defp strict_eq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_strict_eq, 2,
     [
       {:clause, @line, [a, b], [number_guards(a, b)], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(Values, :strict_eq, [a, b])]}
     ]}
  end

  defp strict_neq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_strict_neq, 2,
     [
       {:clause, @line, [a, b], [], [{:op, @line, :not, local_call(:op_strict_eq, [a, b])}]}
     ]}
  end

  defp integer_guards(a, b), do: [integer_guard(a), integer_guard(b)]
  defp number_guards(a, b), do: [number_guard(a), number_guard(b)]
  defp binary_guards(a, b), do: [binary_guard(a), binary_guard(b)]
  defp integer_guard(expr), do: {:call, @line, {:atom, @line, :is_integer}, [expr]}
  defp number_guard(expr), do: {:call, @line, {:atom, @line, :is_number}, [expr]}
  defp binary_guard(expr), do: {:call, @line, {:atom, @line, :is_binary}, [expr]}
  defp list_guard(expr), do: {:call, @line, {:atom, @line, :is_list}, [expr]}
  defp map_guard(expr), do: {:call, @line, {:atom, @line, :is_map}, [expr]}

  defp map_proxy_guards(map) do
    [
      map_guard(map),
      {:call, @line, {:atom, @line, :is_map_key}, [literal("__proxy_target__"), map]},
      {:call, @line, {:atom, @line, :is_map_key}, [literal("__proxy_handler__"), map]}
    ]
  end

  defp not_nil_guard(expr), do: {:op, @line, :"=/=", expr, atom(nil)}

  defp block_name(idx), do: String.to_atom("block_#{idx}")
  defp slot_var(idx), do: var("Slot#{idx}")
  defp slot_vars(0), do: []
  defp slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  defp var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  defp atom(value), do: {:atom, @line, value}

  defp remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  defp literal(value), do: :erl_parse.abstract(value)

  defp binary_concat(left, right) do
    {:bin, @line,
     [
       {:bin_element, @line, left, :default, [:binary]},
       {:bin_element, @line, right, :default, [:binary]}
     ]}
  end

  defp local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}
end
