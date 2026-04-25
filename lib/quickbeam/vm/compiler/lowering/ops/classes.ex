defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Classes do
  @moduledoc "Class definition opcodes: define_class, define_method, add_brand, check_brand, init_ctor."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}

  def lower(state, name_args) do
    case name_args do
      {{:ok, :define_class}, [atom_idx, _flags]} ->
        State.define_class_call(state, atom_idx)

      {{:ok, :define_class_computed}, [atom_idx, _flags]} ->
        lower_define_class_computed(state, atom_idx)

      {{:ok, :define_method}, [atom_idx, flags]} ->
        State.define_method_call(state, Builder.atom_name(state, atom_idx), flags)

      {{:ok, :define_method_computed}, [flags]} ->
        State.define_method_computed_call(state, flags)

      {{:ok, :add_brand}, []} ->
        State.add_brand(state)

      {{:ok, :check_brand}, []} ->
        lower_check_brand(state)

      {{:ok, :init_ctor}, []} ->
        State.effectful_push(
          state,
          State.compiler_call(state, :init_ctor, []),
          :object
        )

      _ ->
        :not_handled
    end
  end

  defp lower_define_class_computed(state, atom_idx) do
    with {:ok, ctor, state} <- State.pop(state),
         {:ok, parent_ctor, state} <- State.pop(state),
         {:ok, _computed_name, state} <- State.pop(state) do
      {pair, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          State.compiler_call(state, :define_class, [
            ctor,
            parent_ctor,
            Builder.literal(atom_idx)
          ])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:object, :function | state.stack_types]
       }}
    end
  end

  defp lower_check_brand(state) do
    with {:ok, state, brand} <- State.bind_stack_entry(state, 0),
         {:ok, state, obj} <- State.bind_stack_entry(state, 1) do
      {:ok,
       %{
         state
         | body:
             [State.compiler_call(state, :check_brand, [obj, brand]) | state.body]
       }}
    else
      :error -> {:error, :check_brand_state_missing}
    end
  end
end
