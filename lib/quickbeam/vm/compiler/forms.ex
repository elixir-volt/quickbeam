defmodule QuickBEAM.VM.Compiler.Forms do
  @moduledoc "Erlang abstract-format form builder: assembles the module, entry, and block function forms for compilation."

  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation

  @line 1

  def compile_module(module, entry, ctx_entry, fun, arity, slot_count, block_forms) do
    forms = [
      {:attribute, @line, :module, module},
      {:attribute, @line, :export, [{entry, arity}, {ctx_entry, arity + 1}]},
      entry_form(entry, ctx_entry, arity),
      ctx_entry_form(ctx_entry, arity, slot_count)
      | helper_forms(fun) ++ block_forms
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

  defp helper_forms(_fun) do
    [
      add_helper(),
      guarded_binary_helper(:op_sub, :-, Values, :sub),
      guarded_binary_helper(:op_mul, :*, Values, :mul),
      guarded_binary_helper(:op_div, :/, Values, :div),
      guarded_binary_helper(:op_lt, :<, Values, :lt),
      guarded_binary_helper(:op_lte, :"=<", Values, :lte),
      guarded_binary_helper(:op_gt, :>, Values, :gt),
      guarded_binary_helper(:op_gte, :>=, Values, :gte),
      guarded_binary_helper(:op_mod, :rem, Values, :mod),
      guarded_binary_helper(:op_band, :band, Values, :band),
      guarded_binary_helper(:op_bor, :bor, Values, :bor),
      guarded_binary_helper(:op_bxor, :bxor, Values, :bxor),
      guarded_binary_helper(:op_shl, :bsl, Values, :shl),
      guarded_binary_helper(:op_sar, :bsr, Values, :sar),
      unary_fallback_helper2(:op_shr, Values, :shr),
      eq_helper(),
      neq_helper(),
      strict_eq_helper(),
      strict_neq_helper(),
      guarded_unary_helper(:op_neg, :-, Values, :neg),
      unary_fallback_helper(:op_plus, Values, :to_number),
      get_field_inline_helper(),
      truthy_inline_helper(),
      typeof_inline_helper()
      | invoke_var_ref_runtime_helpers()
    ]
  end

  defp invoke_var_ref_runtime_helpers do
    for prefix <- [:op_invoke_var_ref, :op_invoke_var_ref_check],
        arity <- [:list, 0, 1, 2, 3] do
      invoke_var_ref_runtime_helper(prefix, arity)
    end
  end

  defp invoke_var_ref_runtime_helper(prefix, :list) do
    ctx = var("Ctx")
    idx = var("Idx")
    args = var("Args")

    {:function, @line, String.to_atom("#{prefix}"), 3,
     [
       {:clause, @line, [ctx, idx, args], [],
        [
          remote_call(Invocation, :invoke_runtime, [
            ctx,
            remote_call(RuntimeHelpers, getter_name(prefix), [ctx, idx]),
            args
          ])
        ]}
     ]}
  end

  defp invoke_var_ref_runtime_helper(prefix, argc) when argc in 0..3 do
    ctx = var("Ctx")
    idx = var("Idx")
    args = if argc == 0, do: [], else: Enum.map(1..argc, &var("Arg#{&1}"))

    {:function, @line, String.to_atom("#{prefix}#{argc}"), argc + 2,
     [
       {:clause, @line, [ctx, idx | args], [],
        [
          remote_call(Invocation, :invoke_runtime, [
            ctx,
            remote_call(RuntimeHelpers, getter_name(prefix), [ctx, idx]),
            list_expr(args)
          ])
        ]}
     ]}
  end

  defp getter_name(:op_invoke_var_ref), do: :get_var_ref
  defp getter_name(:op_invoke_var_ref_check), do: :get_var_ref_check

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

  defp unary_fallback_helper2(name, fallback_mod, fallback_fun) do
    a = var("A")
    b = var("B")

    {:function, @line, name, 2,
     [
       {:clause, @line, [a, b], [], [remote_call(fallback_mod, fallback_fun, [a, b])]}
     ]}
  end

  defp eq_helper do
    a = var("A")
    b = var("B")

    same = var("Same")

    {:function, @line, :op_eq, 2,
     [
       {:clause, @line, [same, same], [], [{:atom, @line, true}]},
       {:clause, @line, [a, b], [number_guards(a, b)], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b],
        [
          [
            {:op, @line, :andalso, {:call, @line, {:atom, @line, :is_binary}, [a]},
             {:call, @line, {:atom, @line, :is_binary}, [b]}}
          ]
        ], [{:op, @line, :==, a, b}]},
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

  defp block_name(idx), do: String.to_atom("block_#{idx}")
  defp slot_var(idx), do: var("Slot#{idx}")
  defp slot_vars(0), do: []
  defp slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  defp var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  defp atom(value), do: {:atom, @line, value}

  defp remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  defp binary_concat(left, right) do
    {:bin, @line,
     [
       {:bin_element, @line, left, :default, [:binary]},
       {:bin_element, @line, right, :default, [:binary]}
     ]}
  end

  defp get_field_inline_helper do
    _obj = var("Obj")
    key = var("Key")
    id = var("Id")
    offsets = var("Offsets")
    vals = var("Vals")
    off = var("Off")
    wild = var("_")
    obj2 = var("Obj2")
    key2 = var("Key2")

    shape_match = {:tuple, @line, [{:atom, @line, :shape}, wild, offsets, vals, wild]}
    obj_tuple = {:tuple, @line, [{:atom, @line, :obj}, id]}

    {:function, @line, :op_get_field, 2,
     [
       {:clause, @line, [obj_tuple, key], [],
        [
          {:case, @line,
           {:call, @line, {:remote, @line, {:atom, @line, :erlang}, {:atom, @line, :get}}, [id]},
           [
             {:clause, @line, [shape_match], [],
              [
                {:case, @line,
                 {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :find}},
                  [key, offsets]},
                 [
                   {:clause, @line, [{:tuple, @line, [{:atom, @line, :ok}, off]}], [],
                    [
                      {:call, @line,
                       {:remote, @line, {:atom, @line, :erlang}, {:atom, @line, :element}},
                       [{:op, @line, :+, off, {:integer, @line, 1}}, vals]}
                    ]},
                   {:clause, @line, [{:atom, @line, :error}], [],
                    [remote_call(QuickBEAM.VM.ObjectModel.Get, :get, [obj_tuple, key])]}
                 ]}
              ]},
             {:clause, @line, [wild], [],
              [remote_call(QuickBEAM.VM.ObjectModel.Get, :get, [obj_tuple, key])]}
           ]}
        ]},
       {:clause, @line, [obj2, key2], [],
        [remote_call(QuickBEAM.VM.ObjectModel.Get, :get, [obj2, key2])]}
     ]}
  end

  defp local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}

  defp truthy_inline_helper do
    v = var("V")

    {:function, @line, :op_truthy, 1,
     [
       {:clause, @line, [{:atom, @line, nil}], [], [{:atom, @line, false}]},
       {:clause, @line, [{:atom, @line, :undefined}], [], [{:atom, @line, false}]},
       {:clause, @line, [{:atom, @line, false}], [], [{:atom, @line, false}]},
       {:clause, @line, [{:integer, @line, 0}], [], [{:atom, @line, false}]},
       {:clause, @line, [{:float, @line, 0.0}], [], [{:atom, @line, false}]},
       {:clause, @line, [{:float, @line, -0.0}], [], [{:atom, @line, false}]},
       {:clause, @line, [{:atom, @line, :nan}], [], [{:atom, @line, false}]},
       {:clause, @line, [{:bin, @line, []}], [], [{:atom, @line, false}]},
       {:clause, @line, [v], [], [{:atom, @line, true}]}
     ]}
  end

  defp typeof_inline_helper do
    v = var("V")

    {:function, @line, :op_typeof, 1,
     [
       {:clause, @line, [{:atom, @line, :undefined}], [], [:erl_parse.abstract("undefined")]},
       {:clause, @line, [{:atom, @line, nil}], [], [:erl_parse.abstract("object")]},
       {:clause, @line, [{:atom, @line, true}], [], [:erl_parse.abstract("boolean")]},
       {:clause, @line, [{:atom, @line, false}], [], [:erl_parse.abstract("boolean")]},
       {:clause, @line, [v], [[{:call, @line, {:atom, @line, :is_number}, [v]}]],
        [:erl_parse.abstract("number")]},
       {:clause, @line, [v], [[{:call, @line, {:atom, @line, :is_binary}, [v]}]],
        [:erl_parse.abstract("string")]},
       {:clause, @line, [v], [], [remote_call(Values, :typeof, [v])]}
     ]}
  end

  defp list_expr([]), do: {nil, @line}
  defp list_expr([h | t]), do: {:cons, @line, h, list_expr(t)}
end
