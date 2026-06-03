defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Stack do
  @moduledoc "Stack manipulation opcodes: push constants, dup, drop, swap, rot, perm, insert, nip, nop."

  alias QuickBEAM.VM.Compiler.Analysis.Types, as: AnalysisTypes
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Captures, Emit, State}
  alias QuickBEAM.VM.OpcodeSpec

  @small_int_handlers Map.new(OpcodeSpec.small_int_push_names(), &{&1, {:push_small_int, &1}})

  @handlers Map.merge(@small_int_handlers, %{
              push_i32: :push_integer,
              push_i16: :push_integer,
              push_i8: :push_integer,
              push_true: :push_true,
              push_false: :push_false,
              null: :null,
              undefined: :undefined,
              push_empty_string: :push_empty_string,
              push_bigint_i32: :push_bigint_i32,
              push_atom_value: :push_atom_value,
              push_this: :push_this,
              push_const: :push_const,
              push_const8: :push_const,
              fclosure: :fclosure,
              fclosure8: :fclosure,
              private_symbol: :private_symbol,
              dup: :dup,
              dup1: :dup1,
              dup2: :dup2,
              dup3: :dup3,
              insert2: :insert2,
              insert3: :insert3,
              insert4: :insert4,
              drop: :drop,
              nip: :nip,
              nip1: :nip1,
              swap: :swap,
              swap2: :swap2,
              rot3l: :rot3l,
              rot3r: :rot3r,
              rot4l: :rot4l,
              rot5l: :rot5l,
              perm3: :perm3,
              perm4: :perm4,
              perm5: :perm5,
              nop: :nop
            })

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :stack,
                        do: name

  if @invalid_handlers != [] do
    raise "stack lowering handlers registered for non-stack opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, constants, arg_count, name_args) do
    lower_registered(state, constants, arg_count, name_args)
  end

  defp lower_registered(state, constants, arg_count, {{:ok, name}, args}) do
    case Map.get(@handlers, name) do
      nil -> :not_handled
      handler -> lower_handler(handler, state, constants, arg_count, args)
    end
  end

  defp lower_registered(_state, _constants, _arg_count, _name_args), do: :not_handled

  defp lower_handler(:push_integer, state, _constants, _arg_count, [value]),
    do: {:ok, Emit.push(state, Builder.integer(value))}

  defp lower_handler({:push_small_int, name}, state, _constants, _arg_count, _args) do
    {:ok, value} = OpcodeSpec.small_int_push(name)
    {:ok, Emit.push(state, Builder.integer(value))}
  end

  defp lower_handler(:push_true, state, _constants, _arg_count, []),
    do: {:ok, Emit.push(state, Builder.atom(true))}

  defp lower_handler(:push_false, state, _constants, _arg_count, []),
    do: {:ok, Emit.push(state, Builder.atom(false))}

  defp lower_handler(:null, state, _constants, _arg_count, []),
    do: {:ok, Emit.push(state, Builder.atom(nil))}

  defp lower_handler(:undefined, state, _constants, _arg_count, []),
    do: {:ok, Emit.push(state, Builder.atom(:undefined))}

  defp lower_handler(:push_empty_string, state, _constants, _arg_count, []),
    do: {:ok, Emit.push(state, Builder.literal(""))}

  defp lower_handler(:push_bigint_i32, state, _constants, _arg_count, [value]),
    do:
      {:ok, Emit.push(state, Builder.tuple_expr([Builder.atom(:bigint), Builder.integer(value)]))}

  defp lower_handler(:push_atom_value, state, _constants, _arg_count, [atom_idx]),
    do: {:ok, Emit.push(state, Builder.literal(Builder.atom_name(state, atom_idx)), :string)}

  defp lower_handler(:push_this, state, _constants, _arg_count, []),
    do: {:ok, Emit.push(state, State.abi_call(state, :push_this, []), :object)}

  defp lower_handler(:push_const, state, constants, arg_count, [const_idx]),
    do: push_const(state, constants, arg_count, const_idx)

  defp lower_handler(:fclosure, state, constants, arg_count, [const_idx]),
    do: lower_fclosure(state, constants, arg_count, const_idx)

  defp lower_handler(:private_symbol, state, _constants, _arg_count, [atom_idx]) do
    {:ok,
     Emit.push(
       state,
       State.constant_call(state, :private_symbol, [
         Builder.literal(Builder.atom_name(state, atom_idx))
       ]),
       :unknown
     )}
  end

  defp lower_handler(:dup, state, _constants, _arg_count, []), do: Emit.duplicate_top(state)
  defp lower_handler(:dup1, state, _constants, _arg_count, []), do: lower_dup1(state)
  defp lower_handler(:dup2, state, _constants, _arg_count, []), do: Emit.duplicate_top_two(state)
  defp lower_handler(:dup3, state, _constants, _arg_count, []), do: lower_dup3(state)
  defp lower_handler(:insert2, state, _constants, _arg_count, []), do: Emit.insert_top_two(state)

  defp lower_handler(:insert3, state, _constants, _arg_count, []),
    do: Emit.insert_top_three(state)

  defp lower_handler(:insert4, state, _constants, _arg_count, []), do: lower_insert4(state)
  defp lower_handler(:drop, state, _constants, _arg_count, []), do: Emit.drop_top(state)
  defp lower_handler(:nip, state, _constants, _arg_count, []), do: lower_nip(state)
  defp lower_handler(:nip1, state, _constants, _arg_count, []), do: lower_nip1(state)
  defp lower_handler(:swap, state, _constants, _arg_count, []), do: Emit.swap_top(state)
  defp lower_handler(:swap2, state, _constants, _arg_count, []), do: lower_swap2(state)
  defp lower_handler(:rot3l, state, _constants, _arg_count, []), do: lower_rot3l(state)
  defp lower_handler(:rot3r, state, _constants, _arg_count, []), do: lower_rot3r(state)
  defp lower_handler(:rot4l, state, _constants, _arg_count, []), do: lower_rot4l(state)
  defp lower_handler(:rot5l, state, _constants, _arg_count, []), do: lower_rot5l(state)
  defp lower_handler(:perm3, state, _constants, _arg_count, []), do: Emit.permute_top_three(state)
  defp lower_handler(:perm4, state, _constants, _arg_count, []), do: lower_perm4(state)
  defp lower_handler(:perm5, state, _constants, _arg_count, []), do: lower_perm5(state)
  defp lower_handler(:nop, state, _constants, _arg_count, []), do: {:ok, state}
  defp lower_handler(_handler, _state, _constants, _arg_count, _args), do: :not_handled

  defp push_const(state, constants, arg_count, idx) do
    case Enum.at(constants, idx) do
      nil ->
        {:error, {:unsupported_const, idx}}

      value
      when is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value) or
             is_nil(value) ->
        {:ok, Emit.push(state, Builder.literal(value))}

      :undefined ->
        {:ok, Emit.push(state, Builder.atom(:undefined), :undefined)}

      value when value in [:nan, :infinity, :neg_infinity] ->
        {:ok, Emit.push(state, Builder.atom(value), :number)}

      {:bigint, value} ->
        {:ok,
         Emit.push(state, Builder.tuple_expr([Builder.atom(:bigint), Builder.integer(value)]))}

      %QuickBEAM.VM.Function{} = fun when fun.closure_vars == [] ->
        {:ok, Emit.push(state, Builder.literal(fun), AnalysisTypes.function_type(fun))}

      %QuickBEAM.VM.Function{} ->
        lower_fclosure(state, constants, arg_count, idx)

      {:template_object, _elems, _raw} = value ->
        {:ok,
         Emit.push(
           state,
           State.constant_call(state, :materialize_constant, [Builder.literal(value)]),
           :object
         )}

      _ ->
        {:error, {:unsupported_const, idx}}
    end
  end

  defp lower_fclosure(state, constants, arg_count, const_idx) do
    case Enum.at(constants, const_idx) do
      %QuickBEAM.VM.Function{closure_vars: []} = fun ->
        closure =
          Builder.tuple_expr([
            Builder.atom(:closure),
            Builder.map_expr(class_field_initializer_marker_entries(state, [])),
            Builder.literal(fun)
          ])

        {:ok, Emit.push(state, closure, AnalysisTypes.function_type(fun))}

      %QuickBEAM.VM.Function{} = fun ->
        with {:ok, state, entries} <-
               lower_closure_entries(state, arg_count, fun.closure_vars, []) do
          closure =
            Builder.tuple_expr([
              Builder.atom(:closure),
              Builder.map_expr(
                class_field_initializer_marker_entries(state, Enum.reverse(entries))
              ),
              Builder.literal(fun)
            ])

          {:ok, Emit.push(state, closure, AnalysisTypes.function_type(fun))}
        end

      nil ->
        {:error, {:unsupported_const, const_idx}}

      other ->
        {:error, {:unsupported_fclosure_const, const_idx, other}}
    end
  end

  defp class_field_initializer_marker_entries(state, entries) do
    if class_field_initializer_state?(state) do
      [{Builder.literal(:__class_field_initializer__), Builder.literal(true)} | entries]
    else
      entries
    end
  end

  defp class_field_initializer_state?(%{locals: locals}) when is_list(locals) do
    names = MapSet.new(Enum.map(locals, &QuickBEAM.VM.Names.resolve_display_name(&1.name)))

    MapSet.subset?(MapSet.new(["this", "new.target", "<home_object>"]), names) and
      not MapSet.member?(names, "arguments")
  end

  defp class_field_initializer_state?(_), do: false

  defp lower_closure_entries(state, _arg_count, [], acc), do: {:ok, state, acc}

  defp lower_closure_entries(
         state,
         arg_count,
         [%{closure_type: 2, var_idx: idx} = cv | rest],
         acc
       ) do
    {parent_ref, state} =
      Emit.bind(
        state,
        Builder.temp_name(state.temp),
        State.abi_call(state, :get_var_ref, [Builder.literal(idx)])
      )

    {cell, state} =
      Emit.bind(
        state,
        Builder.temp_name(state.temp),
        State.abi_call(state, :ensure_capture_cell, [parent_ref, parent_ref])
      )

    key = Builder.literal({cv.closure_type, cv.var_idx})
    lower_closure_entries(state, arg_count, rest, [{key, cell} | acc])
  end

  defp lower_closure_entries(state, arg_count, [cv | rest], acc) do
    with {:ok, slot_idx} <- closure_slot_index(arg_count, cv),
         {:ok, state, cell} <- Captures.ensure_capture_cell(state, slot_idx) do
      key = Builder.literal({cv.closure_type, cv.var_idx})
      lower_closure_entries(state, arg_count, rest, [{key, cell} | acc])
    end
  end

  defp closure_slot_index(_arg_count, %{closure_type: 1, var_idx: idx}), do: {:ok, idx}
  defp closure_slot_index(arg_count, %{closure_type: 0, var_idx: idx}), do: {:ok, idx + arg_count}

  defp closure_slot_index(_arg_count, %{closure_type: 2, var_idx: idx}),
    do: {:error, {:closure_var_ref_not_supported, idx}}

  defp closure_slot_index(_arg_count, %{closure_type: type, var_idx: idx}),
    do: {:error, {:closure_type_not_supported, type, idx}}

  defp lower_dup1(state) do
    with {:ok, a, ta, state} <- Emit.pop_typed(state),
         {:ok, b, tb, state} <- Emit.pop_typed(state) do
      {a_bound, state} = Emit.bind(state, Builder.temp_name(state.temp), a)
      {b_bound, state} = Emit.bind(state, Builder.temp_name(state.temp), b)

      {:ok,
       %{
         state
         | stack: [a_bound, b_bound, b_bound | state.stack],
           stack_types: [ta, tb, tb | state.stack_types]
       }}
    end
  end

  defp lower_dup3(state) do
    with {:ok, a, ta, state} <- Emit.pop_typed(state),
         {:ok, b, tb, state} <- Emit.pop_typed(state),
         {:ok, c, tc, state} <- Emit.pop_typed(state) do
      {c_bound, state} = Emit.bind(state, Builder.temp_name(state.temp), c)
      {b_bound, state} = Emit.bind(state, Builder.temp_name(state.temp), b)
      {a_bound, state} = Emit.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b_bound, c_bound, a_bound, b_bound, c_bound | state.stack],
           stack_types: [ta, tb, tc, ta, tb, tc | state.stack_types]
       }}
    end
  end

  defp lower_insert4(state) do
    with {:ok, a, ta, state} <- Emit.pop_typed(state),
         {:ok, b, tb, state} <- Emit.pop_typed(state),
         {:ok, c, tc, state} <- Emit.pop_typed(state),
         {:ok, d, td, state} <- Emit.pop_typed(state) do
      {a_bound, state} = Emit.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b, c, d, a_bound | state.stack],
           stack_types: [ta, tb, tc, td, ta | state.stack_types]
       }}
    end
  end

  defp lower_nip(%{stack: [a, _b | rest], stack_types: [ta, _tb | type_rest]} = state),
    do: {:ok, %{state | stack: [a | rest], stack_types: [ta | type_rest]}}

  defp lower_nip(_state), do: {:error, :stack_underflow}

  defp lower_nip1(%{stack: [a, b, _c | rest], stack_types: [ta, tb, _tc | type_rest]} = state),
    do: {:ok, %{state | stack: [a, b | rest], stack_types: [ta, tb | type_rest]}}

  defp lower_nip1(_state), do: {:error, :stack_underflow}

  defp lower_swap2(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do: {:ok, %{state | stack: [c, d, a, b | rest], stack_types: [tc, td, ta, tb | type_rest]}}

  defp lower_swap2(_state), do: {:error, :stack_underflow}

  defp lower_rot3l(%{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state),
    do: {:ok, %{state | stack: [c, a, b | rest], stack_types: [tc, ta, tb | type_rest]}}

  defp lower_rot3l(_state), do: {:error, :stack_underflow}

  defp lower_rot3r(%{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state),
    do: {:ok, %{state | stack: [b, c, a | rest], stack_types: [tb, tc, ta | type_rest]}}

  defp lower_rot3r(_state), do: {:error, :stack_underflow}

  defp lower_rot4l(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do: {:ok, %{state | stack: [d, a, b, c | rest], stack_types: [td, ta, tb, tc | type_rest]}}

  defp lower_rot4l(_state), do: {:error, :stack_underflow}

  defp lower_rot5l(
         %{
           stack: [a, b, c, d, e | rest],
           stack_types: [ta, tb, tc, td, te | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{
            state
            | stack: [e, a, b, c, d | rest],
              stack_types: [te, ta, tb, tc, td | type_rest]
          }}

  defp lower_rot5l(_state), do: {:error, :stack_underflow}

  defp lower_perm4(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do: {:ok, %{state | stack: [a, c, d, b | rest], stack_types: [ta, tc, td, tb | type_rest]}}

  defp lower_perm4(_state), do: {:error, :stack_underflow}

  defp lower_perm5(
         %{
           stack: [a, b, c, d, e | rest],
           stack_types: [ta, tb, tc, td, te | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{
            state
            | stack: [a, c, d, e, b | rest],
              stack_types: [ta, tc, td, te, tb | type_rest]
          }}

  defp lower_perm5(_state), do: {:error, :stack_underflow}
end
