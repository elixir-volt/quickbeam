defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Globals do
  @moduledoc "Global variable and var-ref opcodes: get_var, put_var, define_var, get_var_ref, make_*_ref, get/put_ref_value."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, Slots, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings
  alias QuickBEAM.VM.OpcodeSpec

  @handlers %{
    get_var: :get_var,
    get_var_undef: :get_var_undef,
    put_var: {:put_var, false},
    put_var_init: {:put_var, true},
    define_func: {:put_var, true},
    define_var: :define_var,
    check_define_var: :check_define_var,
    get_var_ref: :get_var_ref,
    get_var_ref0: :get_var_ref,
    get_var_ref1: :get_var_ref,
    get_var_ref2: :get_var_ref,
    get_var_ref3: :get_var_ref,
    get_var_ref_check: :get_var_ref_check,
    put_var_ref: :put_var_ref,
    put_var_ref0: :put_var_ref,
    put_var_ref1: :put_var_ref,
    put_var_ref2: :put_var_ref,
    put_var_ref3: :put_var_ref,
    put_var_ref_check: :put_var_ref,
    put_var_ref_check_init: :put_var_ref,
    set_var_ref: :set_var_ref,
    set_var_ref0: :set_var_ref,
    set_var_ref1: :set_var_ref,
    set_var_ref2: :set_var_ref,
    set_var_ref3: :set_var_ref,
    make_loc_ref: :make_loc_ref,
    make_arg_ref: :make_arg_ref,
    make_var_ref: :make_var_ref,
    make_var_ref_ref: :make_var_ref_ref,
    get_ref_value: :get_ref_value,
    put_ref_value: :put_ref_value,
    delete_var: :delete_var
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :globals,
                        do: name

  if @invalid_handlers != [] do
    raise "global lowering handlers registered for non-global opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, {{:ok, name}, args}) do
    case Map.get(@handlers, name) do
      nil -> :not_handled
      handler -> lower_handler(handler, state, args)
    end
  end

  def lower(_state, _name_args), do: :not_handled

  defp lower_handler(:get_var, state, [atom_idx]) do
    name = Builder.atom_name(state, atom_idx)

    if is_binary(name) do
      LoweringEffects.effectful_push(state, inline_get_var(state, name))
    else
      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :get_var, [Builder.literal(name)])
      )
    end
  end

  defp lower_handler(:get_var_undef, state, [atom_idx]) do
    name = Builder.atom_name(state, atom_idx)

    if is_binary(name) do
      LoweringEffects.effectful_push(state, inline_get_var_undef(state, name))
    else
      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :get_var_undef, [Builder.literal(name)])
      )
    end
  end

  defp lower_handler({:put_var, init?}, state, [atom_idx | _rest]),
    do: lower_put_var(state, atom_idx, init?)

  defp lower_handler(:define_var, state, [atom_idx, scope]) do
    {:ok,
     State.update_ctx(
       state,
       State.abi_call(state, :define_var, [Builder.literal(atom_idx), Builder.literal(scope)])
     )}
  end

  defp lower_handler(:check_define_var, state, [atom_idx | _rest]) do
    {:ok,
     State.update_ctx(
       state,
       State.abi_call(state, :check_define_var, [Builder.literal(atom_idx)])
     )}
  end

  defp lower_handler(:get_var_ref, state, [idx]) do
    {expr, state} = State.inline_get_var_ref(state, idx)
    LoweringEffects.effectful_push(state, expr)
  end

  defp lower_handler(:get_var_ref_check, state, [idx]) do
    State.abi_call(state, :get_var_ref_check, [Builder.literal(idx)])
    |> then(&LoweringEffects.effectful_push(state, &1))
  end

  defp lower_handler(:put_var_ref, state, [idx]), do: lower_put_var_ref(state, idx)
  defp lower_handler(:set_var_ref, state, [idx]), do: lower_set_var_ref(state, idx)

  defp lower_handler(:make_loc_ref, state, [atom_idx, var_idx]),
    do: lower_make_loc_ref(state, atom_idx, var_idx)

  defp lower_handler(:make_arg_ref, state, [atom_idx, var_idx]),
    do: lower_make_arg_ref(state, atom_idx, var_idx)

  defp lower_handler(:make_var_ref, state, [atom_idx]), do: lower_make_var_ref(state, atom_idx)

  defp lower_handler(:make_var_ref, state, [atom_idx, var_idx]),
    do: lower_make_loc_ref(state, atom_idx, var_idx)

  defp lower_handler(:make_var_ref_ref, state, [atom_idx, var_idx]),
    do: lower_make_var_ref_ref(state, atom_idx, var_idx)

  defp lower_handler(:get_ref_value, state, []), do: lower_get_ref_value(state)
  defp lower_handler(:put_ref_value, state, []), do: lower_put_ref_value(state)

  defp lower_handler(:delete_var, state, [atom_idx]) do
    {:ok,
     Emit.push(
       state,
       State.abi_call(state, :delete_var, [Builder.literal(atom_idx)]),
       :boolean
     )}
  end

  defp lower_handler(_handler, _state, _args), do: :not_handled

  defp lower_put_var(state, atom_idx, init?) do
    with {:ok, val, _type, state} <- Emit.pop_typed(state) do
      {:ok,
       State.update_ctx(
         state,
         State.abi_call(state, :put_var, [
           Builder.literal(atom_idx),
           val,
           Builder.literal(init: init?, strict: state.strict_mode)
         ])
       )}
    end
  end

  defp lower_put_var_ref(state, idx) do
    with {:ok, val, _type, state} <- Emit.pop_typed(state) do
      {:ok,
       %{
         state
         | body: [
             State.abi_call(state, :put_var_ref, [Builder.literal(idx), val]) | state.body
           ]
       }}
    end
  end

  defp lower_set_var_ref(state, idx) do
    with {:ok, val, _type, state} <- Emit.pop_typed(state) do
      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :set_var_ref, [Builder.literal(idx), val])
      )
    end
  end

  defp lower_make_loc_ref(state, atom_idx, idx) do
    ref =
      State.abi_call(state, :make_loc_ref, [
        Builder.literal(idx),
        Slots.slot_expr(state, idx)
      ])

    key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> Emit.push(ref, :unknown) |> Emit.push(key, :string)}
  end

  defp lower_make_arg_ref(state, atom_idx, idx) do
    ref = State.abi_call(state, :make_arg_ref, [Builder.literal(idx)])
    key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> Emit.push(ref, :unknown) |> Emit.push(key, :string)}
  end

  defp lower_make_var_ref(state, atom_idx) do
    ref = State.abi_call(state, :make_var_ref, [Builder.literal(atom_idx)])
    key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> Emit.push(ref, :unknown) |> Emit.push(key, :string)}
  end

  defp lower_make_var_ref_ref(state, atom_idx, idx) do
    ref = State.abi_call(state, :make_var_ref_ref, [Builder.literal(idx)])
    key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> Emit.push(ref, :unknown) |> Emit.push(key, :string)}
  end

  defp lower_get_ref_value(state) do
    with {:ok, key, key_type, state} <- Emit.pop_typed(state),
         {:ok, ref, ref_type, state} <- Emit.pop_typed(state) do
      value = State.abi_call(state, :get_ref_value, [key, ref])

      {:ok,
       %{
         state
         | stack: [value, key, ref | state.stack],
           stack_types: [:unknown, key_type, ref_type | state.stack_types]
       }}
    end
  end

  defp lower_put_ref_value(state) do
    with {:ok, val, state} <- Emit.pop(state),
         {:ok, key, state} <- Emit.pop(state),
         {:ok, ref, state} <- Emit.pop(state) do
      {:ok, State.update_ctx(state, State.abi_call(state, :put_ref_value, [val, key, ref]))}
    end
  end

  defp inline_get_var(state, "arguments") do
    Builder.remote_call(Bindings, :get_var, [
      State.ctx_expr(state),
      Builder.literal("arguments")
    ])
  end

  defp inline_get_var(state, name) do
    Builder.remote_call(Bindings, :get_global, [
      Builder.map_get(State.ctx_expr(state), Builder.atom(:globals)),
      Builder.literal(name)
    ])
  end

  defp inline_get_var_undef(state, "arguments") do
    Builder.remote_call(Bindings, :get_var_undef, [
      State.ctx_expr(state),
      Builder.literal("arguments")
    ])
  end

  defp inline_get_var_undef(state, name) do
    Builder.remote_call(Bindings, :get_global_undef, [
      Builder.map_get(State.ctx_expr(state), Builder.atom(:globals)),
      Builder.literal(name)
    ])
  end
end
