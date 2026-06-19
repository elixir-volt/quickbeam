defmodule QuickBEAM.VM.Compiler.Forms do
  @moduledoc "Erlang abstract-format form builder: assembles the module, entry, and block function forms for compilation."

  alias QuickBEAM.VM.Compiler.{BEAMForms, RuntimeABI}

  @large_frame_slot_threshold 200
  @line BEAMForms.line()

  @doc "Compiles lowered Erlang forms into a loadable module."
  def compile_module(module, entry, ctx_entry, fun, arity, slot_count, block_forms) do
    forms = [
      {:attribute, @line, :module, module},
      {:attribute, @line, :export, [{entry, arity}, {ctx_entry, arity + 1}]},
      entry_form(entry, ctx_entry, arity),
      ctx_entry_form(ctx_entry, arity, slot_count, force_capture_slots?(fun))
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
    body = [local_call(ctx_entry, [remote_call(RuntimeABI, :entry_ctx, []) | args])]
    BEAMForms.function(entry, arity, [BEAMForms.clause(args, [], body)])
  end

  defp ctx_entry_form(ctx_entry, arity, slot_count, force_capture_slots?) do
    ctx = var("Ctx")
    args = [ctx | slot_vars(arity)]

    locals =
      if slot_count <= arity,
        do: [],
        else: Enum.map(arity..(slot_count - 1), fn _ -> atom(:undefined) end)

    initial_slots = slot_vars(arity) ++ locals

    capture_cells =
      cond do
        slot_count == 0 ->
          []

        force_capture_slots? ->
          Enum.map(
            initial_slots,
            &remote_call(RuntimeABI, :ensure_capture_cell, [ctx, atom(:undefined), &1])
          )

        true ->
          Enum.map(1..slot_count, fn _ -> atom(:undefined) end)
      end

    body_args =
      if large_frame?(slot_count) do
        [ctx, tuple_expr(slot_vars(arity) ++ locals), tuple_expr(capture_cells)]
      else
        [ctx | slot_vars(arity) ++ locals ++ capture_cells]
      end

    body = [local_call(block_name(0), body_args)]

    BEAMForms.function(ctx_entry, arity + 1, [BEAMForms.clause(args, [], body)])
  end

  defp force_capture_slots?(fun) do
    instructions =
      if is_tuple(fun.instructions) do
        {:ok, Tuple.to_list(fun.instructions)}
      else
        {:error, :missing_instructions}
      end

    case instructions do
      {:ok, instructions} ->
        Enum.any?(instructions, fn {op, _args} ->
          match?({:ok, :catch}, QuickBEAM.VM.Compiler.Analysis.CFG.opcode_name(op))
        end)

      {:error, _} ->
        false
    end
  end

  defp helper_forms(_fun) do
    [
      add_helper(),
      guarded_binary_helper(:op_sub, :-, RuntimeABI, :sub),
      guarded_binary_helper(:op_mul, :*, RuntimeABI, :mul),
      div_helper(),
      number_guarded_binary_helper(:op_lt, :<, RuntimeABI, :lt),
      number_guarded_binary_helper(:op_lte, :"=<", RuntimeABI, :lte),
      number_guarded_binary_helper(:op_gt, :>, RuntimeABI, :gt),
      number_guarded_binary_helper(:op_gte, :>=, RuntimeABI, :gte),
      mod_helper(),
      guarded_binary_helper(:op_band, :band, RuntimeABI, :band),
      guarded_binary_helper(:op_bor, :bor, RuntimeABI, :bor),
      guarded_binary_helper(:op_bxor, :bxor, RuntimeABI, :bxor),
      unary_fallback_helper2(:op_shl, RuntimeABI, :shl),
      unary_fallback_helper2(:op_sar, RuntimeABI, :sar),
      unary_fallback_helper2(:op_shr, RuntimeABI, :shr),
      eq_helper(),
      neq_helper(),
      strict_eq_helper(),
      strict_neq_helper(),
      neg_helper(),
      unary_fallback_helper(:op_plus, RuntimeABI, :to_number),
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
          remote_call(RuntimeABI, :invoke_runtime, [
            ctx,
            remote_call(RuntimeABI, getter_name(prefix), [ctx, idx]),
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
          remote_call(RuntimeABI, :invoke_runtime, [
            ctx,
            remote_call(RuntimeABI, getter_name(prefix), [ctx, idx]),
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

    function_form(:op_add, 2, [
      clause([a, b], [integer_guards(a, b)], [op(:+, a, b)]),
      clause([a, b], [binary_guards(a, b)], [binary_concat(a, b)]),
      clause([a, b], [], [remote_call(RuntimeABI, :add, [a, b])])
    ])
  end

  defp guarded_binary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")
    b = var("B")

    function_form(name, 2, [
      clause([a, b], [integer_guards(a, b)], [op(op, a, b)]),
      clause([a, b], [], [remote_call(fallback_mod, fallback_fun, [a, b])])
    ])
  end

  defp number_guarded_binary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")
    b = var("B")

    function_form(name, 2, [
      clause([a, b], [number_guards(a, b)], [op(op, a, b)]),
      clause([a, b], [], [remote_call(fallback_mod, fallback_fun, [a, b])])
    ])
  end

  defp div_helper do
    a = var("A")
    b = var("B")

    function_form(:op_div, 2, [
      clause([a, b], [], [remote_call(RuntimeABI, :js_div, [a, b])])
    ])
  end

  defp mod_helper do
    a = var("A")
    b = var("B")

    function_form(:op_mod, 2, [
      clause([a, b], [], [remote_call(RuntimeABI, :mod, [a, b])])
    ])
  end

  defp neg_helper do
    a = var("A")

    function_form(:op_neg, 1, [
      clause([BEAMForms.integer(0)], [], [BEAMForms.literal(-0.0)]),
      clause([a], [[integer_guard(a)]], [op(:-, a)]),
      clause([a], [[float_guard(a)]], [op(:-, a)]),
      clause([a], [], [remote_call(RuntimeABI, :neg, [a])])
    ])
  end

  defp unary_fallback_helper(name, fallback_mod, fallback_fun) do
    a = var("A")

    function_form(name, 1, [
      clause([a], [[integer_guard(a)]], [a]),
      clause([a], [], [remote_call(fallback_mod, fallback_fun, [a])])
    ])
  end

  defp unary_fallback_helper2(name, fallback_mod, fallback_fun) do
    a = var("A")
    b = var("B")

    function_form(name, 2, [
      clause([a, b], [], [remote_call(fallback_mod, fallback_fun, [a, b])])
    ])
  end

  defp eq_helper do
    a = var("A")
    b = var("B")

    same = var("Same")

    {:function, @line, :op_eq, 2,
     [
       {:clause, @line, [{:atom, @line, :nan}, b], [], [{:atom, @line, false}]},
       {:clause, @line, [a, {:atom, @line, :nan}], [], [{:atom, @line, false}]},
       {:clause, @line, [same, same], [], [{:atom, @line, true}]},
       {:clause, @line, [a, b], [number_guards(a, b)], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b],
        [
          [
            {:op, @line, :andalso, {:call, @line, {:atom, @line, :is_binary}, [a]},
             {:call, @line, {:atom, @line, :is_binary}, [b]}}
          ]
        ], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(RuntimeABI, :eq, [a, b])]}
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
       {:clause, @line, [a, b], [], [remote_call(RuntimeABI, :strict_eq, [a, b])]}
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

  defp integer_guard(expr), do: BEAMForms.is_integer_guard(expr)
  defp number_guard(expr), do: BEAMForms.is_number_guard(expr)
  defp float_guard(expr), do: BEAMForms.is_float_guard(expr)
  defp binary_guard(expr), do: BEAMForms.is_binary_guard(expr)

  defp block_name(idx), do: BEAMForms.block_name(idx)
  defp slot_var(idx), do: var("Slot#{idx}")
  defp slot_vars(0), do: []
  defp slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  defp tuple_expr(values), do: BEAMForms.tuple(values)
  defp large_frame?(slot_count), do: slot_count > @large_frame_slot_threshold
  defp var(name), do: BEAMForms.var(name)
  defp atom(value), do: BEAMForms.atom(value)
  defp remote_call(mod, fun, args), do: BEAMForms.remote_call(mod, fun, args)
  defp binary_concat(left, right), do: BEAMForms.binary_concat(left, right)
  defp function_form(name, arity, clauses), do: BEAMForms.function(name, arity, clauses)
  defp clause(patterns, guards, body), do: BEAMForms.clause(patterns, guards, body)
  defp op(operator, left, right), do: BEAMForms.op(operator, left, right)
  defp op(operator, operand), do: BEAMForms.op(operator, operand)

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
                      remote_call(RuntimeABI, :get_property, [
                        obj_tuple,
                        key
                      ])
                    ]},
                   {:clause, @line, [{:atom, @line, :error}], [],
                    [
                      remote_call(RuntimeABI, :get_property, [
                        obj_tuple,
                        key
                      ])
                    ]}
                 ]}
              ]},
             {:clause, @line, [wild], [],
              [
                remote_call(RuntimeABI, :get_property, [obj_tuple, key])
              ]}
           ]}
        ]},
       {:clause, @line, [obj2, key2], [], [remote_call(RuntimeABI, :get_property, [obj2, key2])]}
     ]}
  end

  defp local_call(fun, args), do: BEAMForms.local_call(fun, args)

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
       {:clause, @line, [{:atom, @line, :__tdz__}], [],
        [
          remote_call(RuntimeABI, :reference_error!, [
            :erl_parse.abstract("Cannot access variable before initialization")
          ])
        ]},
       {:clause, @line, [{:atom, @line, :undefined}], [], [:erl_parse.abstract("undefined")]},
       {:clause, @line, [{:atom, @line, nil}], [], [:erl_parse.abstract("object")]},
       {:clause, @line, [{:atom, @line, true}], [], [:erl_parse.abstract("boolean")]},
       {:clause, @line, [{:atom, @line, false}], [], [:erl_parse.abstract("boolean")]},
       {:clause, @line, [v], [[{:call, @line, {:atom, @line, :is_number}, [v]}]],
        [:erl_parse.abstract("number")]},
       {:clause, @line, [v], [[{:call, @line, {:atom, @line, :is_binary}, [v]}]],
        [:erl_parse.abstract("string")]},
       {:clause, @line, [v], [], [remote_call(RuntimeABI, :typeof, [v])]}
     ]}
  end

  defp list_expr(values), do: BEAMForms.list(values)
end
