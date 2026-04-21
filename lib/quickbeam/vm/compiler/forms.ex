defmodule QuickBEAM.VM.Compiler.Forms do
  @moduledoc false

  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.Interpreter.{Closures, Values}
  alias QuickBEAM.VM.{Heap, Invocation, Names}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}

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

  defp helper_forms(fun) do
    [
      add_helper(),
      guarded_binary_helper(:op_sub, :-, Values, :sub),
      guarded_binary_helper(:op_mul, :*, Values, :mul),
      guarded_binary_helper(:op_div, :/, Values, :div),
      guarded_binary_helper(:op_lt, :<, Values, :lt),
      guarded_binary_helper(:op_lte, :"=<", Values, :lte),
      guarded_binary_helper(:op_gt, :>, Values, :gt),
      guarded_binary_helper(:op_gte, :>=, Values, :gte)
      | invoke_var_ref_helpers(fun) ++
          [
            object_literal_helper(),
            object_literal_fields_helper(),
            new_object_helper(),
            define_field_name_helper(),
            invoke_method_runtime_helper(),
            get_field_helper(),
            get_field_store_helper(),
            get_length_helper(),
            eq_helper(),
            neq_helper(),
            strict_eq_helper(),
            strict_neq_helper(),
            guarded_unary_helper(:op_neg, :-, Values, :neg),
            unary_fallback_helper(:op_plus, Values, :to_number)
          ]
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

  defp invoke_var_ref_helpers(fun) do
    [
      current_var_ref_helper(fun),
      current_var_ref_from_closure_helper(),
      read_var_ref_helper(),
      get_var_ref_helper(fun),
      get_var_ref_check_helper(fun),
      checked_var_ref_cell_helper(),
      var_ref_error_message_helper(fun),
      var_ref_is_this_helper(fun),
      var_ref_is_this_from_closure_helper(),
      derived_this_uninitialized_helper()
      | invoke_var_ref_runtime_helpers()
    ]
  end

  defp current_var_ref_helper(fun) do
    ctx = var("Ctx")
    idx = var("Idx")
    captured = var("Captured")
    closure_fun = var("Fun")

    clauses =
      Enum.with_index(fun.closure_vars)
      |> Enum.map(fn {cv, idx_value} ->
        key = literal({cv.closure_type, cv.var_idx})
        value = var("Val#{idx_value}")

        {:clause, @line, [ctx, integer(idx_value)], [],
         [
           {:case, @line, remote_call(:maps, :get, [atom(:current_func), ctx]),
            [
              {:clause, @line, [tuple_expr([atom(:closure), captured, closure_fun])], [],
               [
                 {:case, @line, remote_call(:maps, :find, [key, captured]),
                  [
                    {:clause, @line, [tuple_expr([atom(:ok), value])], [], [value]},
                    {:clause, @line, [atom(:error)], [], [atom(:undefined)]}
                  ]}
               ]},
              {:clause, @line, [var(:_)], [], [atom(:undefined)]}
            ]}
         ]}
      end)

    {:function, @line, :op_current_var_ref, 2,
     clauses ++
       [
         {:clause, @line, [ctx, idx], [],
          [
            {:case, @line, remote_call(:maps, :get, [atom(:current_func), ctx]),
             [
               {:clause, @line, [tuple_expr([atom(:closure), captured, closure_fun])], [],
                [
                  local_call(:op_current_var_ref_from_closure, [
                    captured,
                    remote_call(:maps, :get, [atom(:closure_vars), closure_fun]),
                    idx
                  ])
                ]},
               {:clause, @line, [var(:_)], [], [atom(:undefined)]}
             ]}
          ]}
       ]}
  end

  defp current_var_ref_from_closure_helper do
    captured = var("Captured")
    cv = var("ClosureVar")
    rest = var("Rest")
    idx = var("Idx")
    val = var("Val")

    key =
      tuple_expr([
        remote_call(:maps, :get, [atom(:closure_type), cv]),
        remote_call(:maps, :get, [atom(:var_idx), cv])
      ])

    {:function, @line, :op_current_var_ref_from_closure, 3,
     [
       {:clause, @line, [captured, cons_pattern(cv, rest), integer(0)], [],
        [
          {:case, @line, remote_call(:maps, :find, [key, captured]),
           [
             {:clause, @line, [tuple_expr([atom(:ok), val])], [], [val]},
             {:clause, @line, [atom(:error)], [], [atom(:undefined)]}
           ]}
        ]},
       {:clause, @line, [captured, cons_pattern(var(:_), rest), idx],
        [positive_integer_guards(idx)],
        [local_call(:op_current_var_ref_from_closure, [captured, rest, decrement(idx)])]},
       {:clause, @line, [captured, nil_pattern(), idx], [], [atom(:undefined)]},
       {:clause, @line, [captured, var(:_), idx], [], [atom(:undefined)]}
     ]}
  end

  defp read_var_ref_helper do
    value = var("Value")
    cell_ref = var("CellRef")
    cell_pattern = tuple_expr([atom(:cell), cell_ref])

    {:function, @line, :op_read_var_ref, 1,
     [
       {:clause, @line, [cell_pattern], [], [remote_call(Closures, :read_cell, [cell_pattern])]},
       {:clause, @line, [value], [], [value]}
     ]}
  end

  defp get_var_ref_helper(fun) do
    ctx = var("Ctx")
    idx = var("Idx")

    clauses =
      Enum.with_index(fun.closure_vars)
      |> Enum.map(fn {cv, idx_value} ->
        {:clause, @line, [ctx, integer(idx_value)], [],
         [read_var_ref_expr(capture_lookup_expr(ctx, literal({cv.closure_type, cv.var_idx})))]}
      end)

    {:function, @line, :op_get_var_ref, 2,
     clauses ++
       [
         {:clause, @line, [ctx, idx], [],
          [local_call(:op_read_var_ref, [local_call(:op_current_var_ref, [ctx, idx])])]}
       ]}
  end

  defp get_var_ref_check_helper(fun) do
    ctx = var("Ctx")
    idx = var("Idx")
    val = var("Val")
    cell_ref = var("CellRef")
    cell_pattern = tuple_expr([atom(:cell), cell_ref])
    atoms = Process.get({:qb_fn_atoms, fun.byte_code}, {})

    clauses =
      Enum.with_index(fun.closure_vars)
      |> Enum.map(fn {cv, idx_value} ->
        is_this = Names.resolve_display_name(Map.get(cv, :name), atoms) == "this"

        {:clause, @line, [ctx, integer(idx_value)], [],
         [
           {:case, @line, capture_lookup_expr(ctx, literal({cv.closure_type, cv.var_idx})),
            [
              {:clause, @line, [atom(:__tdz__)], [], [tdz_error_expr(ctx, is_this)]},
              {:clause, @line, [cell_pattern], [],
               [checked_cell_expr(ctx, cell_pattern, is_this)]},
              {:clause, @line, [val], [], [val]}
            ]}
         ]}
      end)

    {:function, @line, :op_get_var_ref_check, 2,
     clauses ++
       [
         {:clause, @line, [ctx, idx], [],
          [
            {:case, @line, local_call(:op_current_var_ref, [ctx, idx]),
             [
               {:clause, @line, [atom(:__tdz__)], [],
                [
                  throw_js(
                    remote_call(Heap, :make_error, [
                      local_call(:op_var_ref_error_message, [ctx, idx]),
                      literal("ReferenceError")
                    ])
                  )
                ]},
               {:clause, @line, [cell_pattern], [],
                [local_call(:op_checked_var_ref_cell, [ctx, idx, cell_pattern])]},
               {:clause, @line, [val], [], [val]}
             ]}
          ]}
       ]}
  end

  defp capture_lookup_expr(ctx, key) do
    captured = var("CapturedLookup")
    closure_fun = var("ClosureFunLookup")
    value = var("CapturedValue")

    {:case, @line, remote_call(:maps, :get, [atom(:current_func), ctx]),
     [
       {:clause, @line, [tuple_expr([atom(:closure), captured, closure_fun])], [],
        [
          {:case, @line, remote_call(:maps, :find, [key, captured]),
           [
             {:clause, @line, [tuple_expr([atom(:ok), value])], [], [value]},
             {:clause, @line, [atom(:error)], [], [atom(:undefined)]}
           ]}
        ]},
       {:clause, @line, [var(:_)], [], [atom(:undefined)]}
     ]}
  end

  defp read_var_ref_expr(expr) do
    cell_ref = var("ReadCellRef")
    cell_pattern = tuple_expr([atom(:cell), cell_ref])
    value = var("ReadValue")

    {:case, @line, expr,
     [
       {:clause, @line, [cell_pattern], [], [remote_call(Closures, :read_cell, [cell_pattern])]},
       {:clause, @line, [value], [], [value]}
     ]}
  end

  defp tdz_error_expr(ctx, true) do
    {:case, @line, local_call(:op_derived_this_uninitialized, [ctx]),
     [
       {:clause, @line, [atom(true)], [],
        [
          throw_js(
            remote_call(Heap, :make_error, [
              literal("this is not initialized"),
              literal("ReferenceError")
            ])
          )
        ]},
       {:clause, @line, [atom(false)], [],
        [
          throw_js(
            remote_call(Heap, :make_error, [
              literal("Cannot access variable before initialization"),
              literal("ReferenceError")
            ])
          )
        ]}
     ]}
  end

  defp tdz_error_expr(_ctx, false) do
    throw_js(
      remote_call(Heap, :make_error, [
        literal("Cannot access variable before initialization"),
        literal("ReferenceError")
      ])
    )
  end

  defp checked_cell_expr(ctx, cell_pattern, true) do
    val = var("CheckedCellVal")

    {:block, @line,
     [
       {:match, @line, val, remote_call(Closures, :read_cell, [cell_pattern])},
       {:case, @line,
        {:op, @line, :andalso, {:op, @line, :==, val, atom(:__tdz__)},
         local_call(:op_derived_this_uninitialized, [ctx])},
        [
          {:clause, @line, [atom(true)], [],
           [
             throw_js(
               remote_call(Heap, :make_error, [
                 literal("this is not initialized"),
                 literal("ReferenceError")
               ])
             )
           ]},
          {:clause, @line, [atom(false)], [], [val]}
        ]}
     ]}
  end

  defp checked_cell_expr(_ctx, cell_pattern, false) do
    val = var("CheckedCellVal")

    {:block, @line,
     [
       {:match, @line, val, remote_call(Closures, :read_cell, [cell_pattern])},
       {:case, @line, {:op, @line, :==, val, atom(:__tdz__)},
        [
          {:clause, @line, [atom(true)], [],
           [
             throw_js(
               remote_call(Heap, :make_error, [
                 literal("Cannot access variable before initialization"),
                 literal("ReferenceError")
               ])
             )
           ]},
          {:clause, @line, [atom(false)], [], [val]}
        ]}
     ]}
  end

  defp checked_var_ref_cell_helper do
    ctx = var("Ctx")
    idx = var("Idx")
    cell = var("Cell")
    val = var("Val")

    {:function, @line, :op_checked_var_ref_cell, 3,
     [
       {:clause, @line, [ctx, idx, cell], [],
        [
          {:match, @line, val, remote_call(Closures, :read_cell, [cell])},
          {:case, @line,
           {:op, @line, :andalso, {:op, @line, :==, val, atom(:__tdz__)},
            {:op, @line, :andalso, local_call(:op_var_ref_is_this, [ctx, idx]),
             local_call(:op_derived_this_uninitialized, [ctx])}},
           [
             {:clause, @line, [atom(true)], [],
              [
                throw_js(
                  remote_call(Heap, :make_error, [
                    literal("this is not initialized"),
                    literal("ReferenceError")
                  ])
                )
              ]},
             {:clause, @line, [atom(false)], [], [val]}
           ]}
        ]}
     ]}
  end

  defp var_ref_error_message_helper(fun) do
    ctx = var("Ctx")
    idx = var("Idx")

    clauses =
      Enum.with_index(fun.closure_vars)
      |> Enum.map(fn {cv, idx_value} ->
        atoms = Process.get({:qb_fn_atoms, fun.byte_code}, {})
        is_this = Names.resolve_display_name(Map.get(cv, :name), atoms) == "this"

        body =
          if is_this do
            [
              {:case, @line, local_call(:op_derived_this_uninitialized, [ctx]),
               [
                 {:clause, @line, [atom(true)], [], [literal("this is not initialized")]},
                 {:clause, @line, [atom(false)], [],
                  [literal("Cannot access variable before initialization")]}
               ]}
            ]
          else
            [literal("Cannot access variable before initialization")]
          end

        {:clause, @line, [ctx, integer(idx_value)], [], body}
      end)

    {:function, @line, :op_var_ref_error_message, 2,
     clauses ++
       [
         {:clause, @line, [ctx, idx], [],
          [
            {:case, @line,
             {:op, @line, :andalso, local_call(:op_var_ref_is_this, [ctx, idx]),
              local_call(:op_derived_this_uninitialized, [ctx])},
             [
               {:clause, @line, [atom(true)], [], [literal("this is not initialized")]},
               {:clause, @line, [atom(false)], [],
                [literal("Cannot access variable before initialization")]}
             ]}
          ]}
       ]}
  end

  defp var_ref_is_this_helper(fun) do
    ctx = var("Ctx")
    idx = var("Idx")
    captured = var("Captured")
    closure_fun = var("Fun")
    atoms = Process.get({:qb_fn_atoms, fun.byte_code}, {})

    clauses =
      Enum.with_index(fun.closure_vars)
      |> Enum.map(fn {cv, idx_value} ->
        is_this = Names.resolve_display_name(Map.get(cv, :name), atoms) == "this"
        {:clause, @line, [ctx, integer(idx_value)], [], [atom(is_this)]}
      end)

    {:function, @line, :op_var_ref_is_this, 2,
     clauses ++
       [
         {:clause, @line, [ctx, idx], [],
          [
            {:case, @line, remote_call(:maps, :get, [atom(:current_func), ctx]),
             [
               {:clause, @line, [tuple_expr([atom(:closure), captured, closure_fun])], [],
                [
                  local_call(:op_var_ref_is_this_from_closure, [
                    remote_call(:maps, :get, [atom(:closure_vars), closure_fun]),
                    remote_call(:maps, :get, [atom(:atoms), ctx]),
                    idx
                  ])
                ]},
               {:clause, @line, [var(:_)], [], [atom(false)]}
             ]}
          ]}
       ]}
  end

  defp var_ref_is_this_from_closure_helper do
    cv = var("ClosureVar")
    rest = var("Rest")
    atoms = var("Atoms")
    idx = var("Idx")

    {:function, @line, :op_var_ref_is_this_from_closure, 3,
     [
       {:clause, @line, [cons_pattern(cv, rest), atoms, integer(0)], [],
        [
          {:op, @line, :==,
           remote_call(Names, :resolve_display_name, [
             remote_call(:maps, :get, [atom(:name), cv]),
             atoms
           ]), literal("this")}
        ]},
       {:clause, @line, [cons_pattern(var(:_), rest), atoms, idx], [positive_integer_guards(idx)],
        [local_call(:op_var_ref_is_this_from_closure, [rest, atoms, decrement(idx)])]},
       {:clause, @line, [nil_pattern(), atoms, idx], [], [atom(false)]},
       {:clause, @line, [var(:_), atoms, idx], [], [atom(false)]}
     ]}
  end

  defp derived_this_uninitialized_helper do
    ctx = var("Ctx")

    {:function, @line, :op_derived_this_uninitialized, 1,
     [
       {:clause, @line, [ctx], [],
        [
          {:case, @line, remote_call(:maps, :get, [atom(:this), ctx]),
           [
             {:clause, @line, [atom(:uninitialized)], [], [atom(true)]},
             {:clause, @line, [tuple_expr([atom(:uninitialized), var(:_)])], [], [atom(true)]},
             {:clause, @line, [var(:_)], [], [atom(false)]}
           ]}
        ]}
     ]}
  end

  defp invoke_var_ref_runtime_helpers do
    [
      invoke_var_ref_runtime_helper(:op_invoke_var_ref, :op_get_var_ref, :list),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref0, :op_get_var_ref, 0),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref1, :op_get_var_ref, 1),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref2, :op_get_var_ref, 2),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref3, :op_get_var_ref, 3),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref_check, :op_get_var_ref_check, :list),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref_check0, :op_get_var_ref_check, 0),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref_check1, :op_get_var_ref_check, 1),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref_check2, :op_get_var_ref_check, 2),
      invoke_var_ref_runtime_helper(:op_invoke_var_ref_check3, :op_get_var_ref_check, 3)
    ]
  end

  defp invoke_var_ref_runtime_helper(name, getter, :list) do
    ctx = var("Ctx")
    idx = var("Idx")
    args = var("Args")

    {:function, @line, name, 3,
     [
       {:clause, @line, [ctx, idx, args], [],
        [remote_call(Invocation, :invoke_runtime, [ctx, local_call(getter, [ctx, idx]), args])]}
     ]}
  end

  defp invoke_var_ref_runtime_helper(name, getter, argc) when argc in 0..3 do
    ctx = var("Ctx")
    idx = var("Idx")
    args = if argc == 0, do: [], else: Enum.map(1..argc, &var("Arg#{&1}"))

    {:function, @line, name, argc + 2,
     [
       {:clause, @line, [ctx, idx | args], [],
        [
          remote_call(Invocation, :invoke_runtime, [
            ctx,
            local_call(getter, [ctx, idx]),
            list_expr(args)
          ])
        ]}
     ]}
  end

  defp object_literal_helper do
    fields = var("Fields")
    order = var("Order")
    proto = var("Proto")
    order_key = literal(:__key_order__)

    {:function, @line, :op_object_literal, 2,
     [
       {:clause, @line, [fields, nil_pattern()], [],
        [
          {:case, @line, remote_call(Heap, :get_object_prototype, []),
           [
             {:clause, @line, [atom(nil)], [],
              [local_call(:op_object_literal_fields, [fields, map_expr([])])]},
             {:clause, @line, [atom(:undefined)], [],
              [local_call(:op_object_literal_fields, [fields, map_expr([])])]},
             {:clause, @line, [proto], [],
              [
                local_call(:op_object_literal_fields, [
                  fields,
                  map_expr([{literal("__proto__"), proto}])
                ])
              ]}
           ]}
        ]},
       {:clause, @line, [fields, order], [],
        [
          {:case, @line, remote_call(Heap, :get_object_prototype, []),
           [
             {:clause, @line, [atom(nil)], [],
              [local_call(:op_object_literal_fields, [fields, map_expr([{order_key, order}])])]},
             {:clause, @line, [atom(:undefined)], [],
              [local_call(:op_object_literal_fields, [fields, map_expr([{order_key, order}])])]},
             {:clause, @line, [proto], [],
              [
                local_call(:op_object_literal_fields, [
                  fields,
                  map_expr([{literal("__proto__"), proto}, {order_key, order}])
                ])
              ]}
           ]}
        ]}
     ]}
  end

  defp object_literal_fields_helper do
    field = var("Field")
    rest = var("Rest")
    key = var("Key")
    val = var("Val")
    map = var("Map")
    new_map = var("NewMap")

    {:function, @line, :op_object_literal_fields, 2,
     [
       {:clause, @line, [nil_pattern(), map], [], [remote_call(Heap, :wrap, [map])]},
       {:clause, @line, [cons_pattern(field, rest), map], [],
        [
          {:match, @line, tuple_expr([key, val]), field},
          {:match, @line, new_map,
           {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :put}},
            [key, val, map]}},
          local_call(:op_object_literal_fields, [rest, new_map])
        ]}
     ]}
  end

  defp new_object_helper do
    proto = var("Proto")

    {:function, @line, :op_new_object, 0,
     [
       {:clause, @line, [], [],
        [
          {:case, @line, remote_call(Heap, :get_object_prototype, []),
           [
             {:clause, @line, [atom(nil)], [], [remote_call(Heap, :wrap, [map_expr([])])]},
             {:clause, @line, [atom(:undefined)], [], [remote_call(Heap, :wrap, [map_expr([])])]},
             {:clause, @line, [proto], [],
              [remote_call(Heap, :wrap, [map_expr([{literal("__proto__"), proto}])])]}
           ]}
        ]}
     ]}
  end

  defp define_field_name_helper do
    obj = var("Obj")
    ref = var("Ref")
    key = var("Key")
    val = var("Val")
    map = var("Map")
    wrapped = tuple_expr([atom(:obj), ref])

    plain_object? =
      {:op, @line, :andalso, map_guard(map),
       {:op, @line, :andalso,
        {:op, @line, :not,
         {:call, @line, {:atom, @line, :is_map_key}, [literal("__proxy_target__"), map]}},
        {:op, @line, :andalso,
         {:op, @line, :not,
          {:call, @line, {:atom, @line, :is_map_key}, [literal("__proxy_handler__"), map]}},
         {:op, @line, :not, pd_flag_expr(frozen_key_expr(ref))}}}}

    {:function, @line, :op_define_field_name, 3,
     [
       {:clause, @line, [wrapped, key, val], [],
        [
          {:match, @line, map, pd_get_with_default_expr(obj_key_expr(ref), map_expr([]))},
          {:case, @line, plain_object?,
           [
             {:clause, @line, [atom(true)], [],
              [put_obj_name_key_expr(ref, map, key, val), wrapped]},
             {:clause, @line, [atom(false)], [],
              [remote_call(Put, :put, [wrapped, key, val]), wrapped]}
           ]}
        ]},
       {:clause, @line, [obj, key, val], [], [remote_call(Put, :put, [obj, key, val]), obj]}
     ]}
  end

  defp invoke_method_runtime_helper do
    ctx = var("Ctx")
    fun = var("Fun")
    obj = var("Obj")
    args = var("Args")

    {:function, @line, :op_invoke_method_runtime, 4,
     [
       {:clause, @line, [ctx, fun, obj, args], [],
        [remote_call(Invocation, :invoke_method_runtime, [ctx, fun, obj, args])]}
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
            pd_get_with_default_expr(obj_key_expr(ref), atom(nil)),
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
    getter = var("Getter")
    val = var("Val")

    {:function, @line, :op_get_field_from_store, 3,
     [
       {:clause, @line, [map, obj, key], [map_proxy_guards(map)],
        [remote_call(Get, :get, [obj, key])]},
       {:clause, @line, [map, obj, key], [[map_guard(map)]],
        [
          {:case, @line, remote_call(:maps, :find, [key, map]),
           [
             {:clause, @line,
              [
                {:tuple, @line, [atom(:ok), {:tuple, @line, [atom(:accessor), getter, var("_")]}]}
              ], [[not_nil_guard(getter)]], [remote_call(Get, :call_getter, [getter, obj])]},
             {:clause, @line, [{:tuple, @line, [atom(:ok), val]}], [], [val]},
             {:clause, @line, [atom(:error)], [], [remote_call(Get, :get, [obj, key])]}
           ]}
        ]},
       {:clause, @line, [map, obj, key], [], [remote_call(Get, :get, [obj, key])]}
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

  defp positive_integer_guards(expr),
    do: [integer_guard(expr), {:op, @line, :>, expr, integer(0)}]

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

  defp obj_key_expr(ref), do: tuple_expr([atom(:qb_obj), ref])
  defp frozen_key_expr(ref), do: tuple_expr([atom(:qb_frozen), ref])

  defp pd_get_with_default_expr(key, default) do
    value = var("PdValue")

    {:case, @line, {:call, @line, {:atom, @line, :get}, [key]},
     [
       {:clause, @line, [atom(:undefined)], [], [default]},
       {:clause, @line, [value], [], [value]}
     ]}
  end

  defp pd_flag_expr(key) do
    {:case, @line, {:call, @line, {:atom, @line, :get}, [key]},
     [
       {:clause, @line, [atom(true)], [], [atom(true)]},
       {:clause, @line, [var(:_)], [], [atom(false)]}
     ]}
  end

  defp put_obj_name_key_expr(ref, map, key, val) do
    order = var("Order")
    new_map = var("NewMap")
    order_key = literal(:__key_order__)

    {:case, @line,
     {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :find}}, [key, map]},
     [
       {:clause, @line, [tuple_expr([atom(:ok), var(:_)])], [],
        [
          {:call, @line, {:atom, @line, :put},
           [
             obj_key_expr(ref),
             {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :put}},
              [key, val, map]}
           ]}
        ]},
       {:clause, @line, [atom(:error)], [],
        [
          {:case, @line,
           {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :find}},
            [order_key, map]},
           [
             {:clause, @line, [tuple_expr([atom(:ok), order])], [],
              [
                {:match, @line, new_map,
                 {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :put}},
                  [
                    order_key,
                    {:cons, @line, key, order},
                    {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :put}},
                     [key, val, map]}
                  ]}},
                {:call, @line, {:atom, @line, :put}, [obj_key_expr(ref), new_map]}
              ]},
             {:clause, @line, [atom(:error)], [],
              [
                {:match, @line, new_map,
                 {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :put}},
                  [
                    order_key,
                    list_expr([key]),
                    {:call, @line, {:remote, @line, {:atom, @line, :maps}, {:atom, @line, :put}},
                     [key, val, map]}
                  ]}},
                {:call, @line, {:atom, @line, :put}, [obj_key_expr(ref), new_map]}
              ]}
           ]}
        ]}
     ]}
  end

  defp block_name(idx), do: String.to_atom("block_#{idx}")
  defp slot_var(idx), do: var("Slot#{idx}")
  defp slot_vars(0), do: []
  defp slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  defp var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  defp var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  defp var(name) when is_atom(name), do: {:var, @line, name}
  defp integer(value), do: {:integer, @line, value}
  defp atom(value), do: {:atom, @line, value}

  defp remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  defp literal(value), do: :erl_parse.abstract(value)

  defp map_expr(entries) do
    {:map, @line, Enum.map(entries, fn {key, value} -> {:map_field_assoc, @line, key, value} end)}
  end

  defp list_expr([]), do: {nil, @line}
  defp list_expr([head | tail]), do: {:cons, @line, head, list_expr(tail)}

  defp tuple_expr(values), do: {:tuple, @line, values}
  defp cons_pattern(head, tail), do: {:cons, @line, head, tail}
  defp nil_pattern, do: {nil, @line}
  defp decrement(expr), do: {:op, @line, :-, expr, integer(1)}

  defp throw_js(expr) do
    remote_call(:erlang, :throw, [tuple_expr([atom(:js_throw), expr])])
  end

  defp binary_concat(left, right) do
    {:bin, @line,
     [
       {:bin_element, @line, left, :default, [:binary]},
       {:bin_element, @line, right, :default, [:binary]}
     ]}
  end

  defp local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}
end
