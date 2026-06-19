defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Objects do
  @moduledoc "Object and array manipulation opcodes: get/put_field, get/put_array_el, define_field, set_name, set_proto, get/put_super, private fields, delete, in, instanceof."

  alias QuickBEAM.VM.Compiler.Lowering.Operators
  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}
  alias QuickBEAM.VM.OpcodeSpec

  @handler_opcodes [
    :object,
    :array_from,
    :regexp,
    :special_object,
    :set_name,
    :set_name_computed,
    :set_home_object,
    :get_super,
    :get_super_value,
    :put_super_value,
    :get_field,
    :get_field2,
    :put_field,
    :define_static_method,
    :define_field,
    :get_array_el,
    :get_array_el2,
    :put_array_el,
    :define_array_el,
    :append,
    :copy_data_properties,
    :set_proto,
    :check_ctor_return,
    :check_ctor,
    :to_object,
    :to_propkey,
    :to_propkey2,
    :get_length,
    :instanceof,
    :in,
    :delete,
    :get_private_field,
    :put_private_field,
    :define_private_field,
    :private_in
  ]

  @invalid_handlers for name <- @handler_opcodes,
                        OpcodeSpec.lowering_family(name) != :objects,
                        do: name

  if @invalid_handlers != [] do
    raise "object lowering handlers registered for non-object opcodes: #{inspect(@invalid_handlers)}"
  end

  @handlers Map.new(@handler_opcodes, &{&1, &1})

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

  defp lower_handler(:object, state, []) do
    {obj, state} =
      Emit.bind(
        state,
        Builder.temp_name(state.temp),
        State.abi_call(state, :new_object, [])
      )

    {:ok, Emit.push(state, obj, {:shaped_object, %{}})}
  end

  defp lower_handler(:array_from, state, [argc]), do: State.array_from_call(state, argc)
  defp lower_handler(:regexp, state, []), do: State.regexp_literal(state)

  defp lower_handler(:special_object, state, [type]) do
    {:ok,
     Emit.push(
       state,
       State.abi_call(state, :special_object, [Builder.literal(type)]),
       special_object_type(type)
     )}
  end

  defp lower_handler(:set_name, state, [atom_idx]),
    do: State.set_name_atom(state, Builder.atom_name(state, atom_idx))

  defp lower_handler(:set_name_computed, state, []), do: State.set_name_computed(state)
  defp lower_handler(:set_home_object, state, []), do: State.set_home_object(state)
  defp lower_handler(:get_super, state, []), do: Operators.unary_abi_call(state, :get_super)
  defp lower_handler(:get_super_value, state, []), do: lower_get_super_value(state)
  defp lower_handler(:put_super_value, state, []), do: lower_put_super_value(state)

  defp lower_handler(:get_field, state, [atom_idx]),
    do: State.get_field_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

  defp lower_handler(:get_field2, state, [atom_idx]),
    do: State.get_field2(state, Builder.literal(Builder.atom_name(state, atom_idx)))

  defp lower_handler(:put_field, state, [atom_idx]),
    do: State.put_field_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

  defp lower_handler(:define_static_method, state, [atom_idx]),
    do: define_static_method_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

  defp lower_handler(:define_field, state, [atom_idx]),
    do: State.define_field_name_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

  defp lower_handler(:get_array_el, state, []), do: State.get_array_el(state)
  defp lower_handler(:get_array_el2, state, []), do: State.get_array_el2(state)
  defp lower_handler(:put_array_el, state, []), do: State.put_array_el_call(state)
  defp lower_handler(:define_array_el, state, []), do: State.define_array_el_call(state)
  defp lower_handler(:append, state, []), do: State.append_call(state)

  defp lower_handler(:copy_data_properties, state, [mask]),
    do: State.copy_data_properties_call(state, mask)

  defp lower_handler(:set_proto, state, []), do: lower_set_proto(state)
  defp lower_handler(:check_ctor_return, state, []), do: lower_check_ctor_return(state)
  defp lower_handler(:check_ctor, state, []), do: {:ok, state}
  defp lower_handler(:to_object, state, []), do: lower_effectful_unary_abi_call(state, :to_object)

  defp lower_handler(:to_propkey, state, []),
    do: Operators.unary_abi_call(state, :to_property_key)

  defp lower_handler(:to_propkey2, state, []), do: lower_to_propkey2(state)
  defp lower_handler(:get_length, state, []), do: Operators.get_length_call(state)
  defp lower_handler(:instanceof, state, []), do: Operators.binary_abi_call(state, :instanceof)
  defp lower_handler(:in, state, []), do: State.in_call(state)
  defp lower_handler(:delete, state, []), do: State.delete_call(state)
  defp lower_handler(:get_private_field, state, []), do: lower_get_private_field(state)
  defp lower_handler(:put_private_field, state, []), do: lower_put_private_field(state)
  defp lower_handler(:define_private_field, state, []), do: lower_define_private_field(state)
  defp lower_handler(:private_in, state, []), do: lower_private_in(state)
  defp lower_handler(_handler, _state, _args), do: :not_handled

  defp special_object_type(2), do: :self_fun
  defp special_object_type(3), do: :function
  defp special_object_type(type) when type in [0, 1, 5, 6, 7], do: :object
  defp special_object_type(_), do: :unknown

  defp lower_set_proto(state) do
    with {:ok, proto, state} <- Emit.pop(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      {:ok,
       %{
         state
         | body: [State.abi_call(state, :set_proto, [obj, proto]) | state.body],
           stack: [obj | state.stack],
           stack_types: [:object | state.stack_types]
       }}
    end
  end

  defp lower_get_super_value(state) do
    with {:ok, key, state} <- Emit.pop(state),
         {:ok, proto, state} <- Emit.pop(state),
         {:ok, this_obj, state} <- Emit.pop(state) do
      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :get_super_value, [proto, this_obj, key])
      )
    end
  end

  defp lower_put_super_value(state) do
    with {:ok, val, state} <- Emit.pop(state),
         {:ok, key, state} <- Emit.pop(state),
         {:ok, proto_obj, state} <- Emit.pop(state),
         {:ok, this_obj, state} <- Emit.pop(state) do
      {:ok,
       %{
         state
         | body: [
             State.abi_call(state, :put_super_value, [proto_obj, this_obj, key, val])
             | state.body
           ]
       }}
    end
  end

  defp lower_effectful_unary_abi_call(state, fun) do
    with {:ok, expr, _type, state} <- Emit.pop_typed(state) do
      LoweringEffects.effectful_push(
        state,
        Builder.remote_call(QuickBEAM.VM.Compiler.RuntimeABI, fun, [state.ctx, expr])
      )
    end
  end

  defp lower_to_propkey2(state) do
    with {:ok, key, _key_type, state} <- Emit.pop_typed(state),
         {:ok, obj, obj_type, state} <- Emit.pop_typed(state) do
      state = LoweringEffects.apply_effect(state, :to_property_key, obj)

      {:ok,
       state
       |> Emit.push(obj, obj_type)
       |> Emit.push(
         State.abi_call(state, :to_property_key_for_access, [obj, key]),
         :unknown
       )}
    end
  end

  defp lower_check_ctor_return(state) do
    with {:ok, val, state} <- Emit.pop(state) do
      {pair, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          State.abi_call(state, :check_ctor_return, [val])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:unknown, :unknown | state.stack_types]
       }}
    end
  end

  defp define_static_method_call(state, key_expr) do
    with {:ok, method, _method_type, state} <- Emit.pop_typed(state),
         {:ok, ctor, _ctor_type, state} <- Emit.pop_typed(state) do
      {:ok,
       Emit.emit(
         state,
         State.abi_call(state, :define_static_method, [ctor, key_expr, method])
       )}
    end
  end

  defp lower_get_private_field(state) do
    with {:ok, key, state} <- Emit.pop(state),
         {:ok, obj, state} <- Emit.pop(state) do
      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :get_private_field, [obj, key])
      )
    end
  end

  defp lower_put_private_field(state) do
    with {:ok, key, state} <- Emit.pop(state),
         {:ok, val, state} <- Emit.pop(state),
         {:ok, obj, state} <- Emit.pop(state) do
      {:ok,
       %{
         state
         | body: [State.abi_call(state, :put_private_field, [obj, key, val]) | state.body]
       }}
    end
  end

  defp lower_define_private_field(state) do
    with {:ok, val, state} <- Emit.pop(state),
         {:ok, key, state} <- Emit.pop(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      {:ok,
       %{
         state
         | body: [State.abi_call(state, :define_private_field, [obj, key, val]) | state.body],
           stack: [obj | state.stack],
           stack_types: [:object | state.stack_types]
       }}
    end
  end

  defp lower_private_in(state) do
    with {:ok, key, state} <- Emit.pop(state),
         {:ok, obj, state} <- Emit.pop(state) do
      {:ok,
       Emit.push(
         state,
         State.abi_call(state, :private_in, [obj, key]),
         :boolean
       )}
    end
  end
end
