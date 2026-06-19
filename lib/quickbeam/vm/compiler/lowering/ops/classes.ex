defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Classes do
  @moduledoc "Class definition opcodes: define_class, define_method, add_brand, check_brand, init_ctor."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}
  alias QuickBEAM.VM.Compiler.RuntimeABI
  alias QuickBEAM.VM.OpcodeSpec

  @handlers %{
    define_class: :define_class,
    define_class_computed: :define_class_computed,
    define_method: :define_method,
    define_method_computed: :define_method_computed,
    add_brand: :add_brand,
    check_brand: :check_brand,
    init_ctor: :init_ctor
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :classes,
                        do: name

  if @invalid_handlers != [] do
    raise "class lowering handlers registered for non-class opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, {{:ok, name}, args}) do
    case Map.get(@handlers, name) do
      nil -> :not_handled
      handler -> lower_handler(handler, state, args)
    end
  end

  def lower(_state, _name_args), do: :not_handled

  defp lower_handler(:define_class, state, [atom_idx, _flags]),
    do: State.define_class_call(state, atom_idx)

  defp lower_handler(:define_class_computed, state, [atom_idx, _flags]),
    do: lower_define_class_computed(state, atom_idx)

  defp lower_handler(:define_method, state, [{:tagged_int, _} = atom_idx, flags]) do
    State.define_method_call(
      state,
      RuntimeABI.normalize_property_key_literal(atom_idx),
      flags
    )
  end

  defp lower_handler(:define_method, state, [atom_idx, flags]),
    do: State.define_method_call(state, Builder.atom_name(state, atom_idx), flags)

  defp lower_handler(:define_method_computed, state, [flags]),
    do: State.define_method_computed_call(state, flags)

  defp lower_handler(:add_brand, state, []), do: State.add_brand(state)
  defp lower_handler(:check_brand, state, []), do: lower_check_brand(state)

  defp lower_handler(:init_ctor, state, []) do
    LoweringEffects.effectful_push(state, State.abi_call(state, :init_ctor, []), :object)
  end

  defp lower_handler(_handler, _state, _args), do: :not_handled

  defp lower_define_class_computed(state, _atom_idx) do
    with {:ok, ctor, state} <- Emit.pop(state),
         {:ok, parent_ctor, state} <- Emit.pop(state),
         {:ok, computed_name, state} <- Emit.pop(state) do
      {pair, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          State.abi_call(state, :define_class_computed, [
            ctor,
            parent_ctor,
            computed_name
          ])
        )

      {:ok,
       %{
         state
         | stack: [
             Builder.tuple_element(pair, 1),
             Builder.tuple_element(pair, 2),
             computed_name | state.stack
           ],
           stack_types: [:object, :function, :string | state.stack_types]
       }}
    end
  end

  defp lower_check_brand(state) do
    with {:ok, state, brand} <- Emit.bind_stack_entry(state, 0),
         {:ok, state, obj} <- Emit.bind_stack_entry(state, 1) do
      {:ok,
       %{
         state
         | body: [State.abi_call(state, :check_brand, [obj, brand]) | state.body]
       }}
    else
      :error -> {:error, :check_brand_state_missing}
    end
  end
end
