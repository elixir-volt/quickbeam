defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Objects do
  @moduledoc "Object and array manipulation opcodes: get/put_field, get/put_array_el, define_field, set_name, set_proto, get/put_super, private fields, delete, in, instanceof."

  alias QuickBEAM.VM.Compiler.Lowering.Operators
  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.ObjectModel.{Class, Private, Put}

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, name_args) do
    case name_args do
      {{:ok, :object}, []} ->
        {obj, state} =
          Emit.bind(
            state,
            Builder.temp_name(state.temp),
            State.compiler_call(state, :new_object, [])
          )

        {:ok, Emit.push(state, obj, {:shaped_object, %{}})}

      {{:ok, :array_from}, [argc]} ->
        State.array_from_call(state, argc)

      {{:ok, :regexp}, []} ->
        State.regexp_literal(state)

      {{:ok, :special_object}, [type]} ->
        {:ok,
         Emit.push(
           state,
           State.abi_call(state, :special_object, [Builder.literal(type)]),
           special_object_type(type)
         )}

      {{:ok, :set_name}, [atom_idx]} ->
        State.set_name_atom(state, Builder.atom_name(state, atom_idx))

      {{:ok, :set_name_computed}, []} ->
        State.set_name_computed(state)

      {{:ok, :set_home_object}, []} ->
        State.set_home_object(state)

      {{:ok, :get_super}, []} ->
        Operators.unary_call(state, RuntimeHelpers, :get_super)

      {{:ok, :get_super_value}, []} ->
        lower_get_super_value(state)

      {{:ok, :put_super_value}, []} ->
        lower_put_super_value(state)

      {{:ok, :get_field}, [atom_idx]} ->
        State.get_field_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :get_field2}, [atom_idx]} ->
        State.get_field2(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :put_field}, [atom_idx]} ->
        State.put_field_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :define_static_method}, [atom_idx]} ->
        define_static_method_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :define_field}, [atom_idx]} ->
        State.define_field_name_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :get_array_el}, []} ->
        Operators.binary_call(state, Put, :get_element)

      {{:ok, :get_array_el2}, []} ->
        State.get_array_el2(state)

      {{:ok, :put_array_el}, []} ->
        State.put_array_el_call(state)

      {{:ok, :define_array_el}, []} ->
        State.define_array_el_call(state)

      {{:ok, :append}, []} ->
        State.append_call(state)

      {{:ok, :copy_data_properties}, [mask]} ->
        State.copy_data_properties_call(state, mask)

      {{:ok, :set_proto}, []} ->
        lower_set_proto(state)

      {{:ok, :check_ctor_return}, []} ->
        lower_check_ctor_return(state)

      {{:ok, :check_ctor}, []} ->
        {:ok, state}

      {{:ok, :to_object}, []} ->
        lower_effectful_unary_abi_call(state, :to_object)

      {{:ok, :to_propkey}, []} ->
        Operators.unary_abi_call(state, :to_property_key)

      {{:ok, :to_propkey2}, []} ->
        lower_to_propkey2(state)

      {{:ok, :get_length}, []} ->
        Operators.get_length_call(state)

      {{:ok, :instanceof}, []} ->
        Operators.binary_call(state, RuntimeHelpers, :instanceof)

      {{:ok, :in}, []} ->
        State.in_call(state)

      {{:ok, :delete}, []} ->
        State.delete_call(state)

      {{:ok, :get_private_field}, []} ->
        lower_get_private_field(state)

      {{:ok, :put_private_field}, []} ->
        lower_put_private_field(state)

      {{:ok, :define_private_field}, []} ->
        lower_define_private_field(state)

      {{:ok, :private_in}, []} ->
        lower_private_in(state)

      _ ->
        :not_handled
    end
  end

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
         | body: [State.compiler_call(state, :set_proto, [obj, proto]) | state.body],
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
        Builder.remote_call(Class, :get_super_value, [proto, this_obj, key])
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
             Builder.remote_call(Class, :put_super_value, [proto_obj, this_obj, key, val])
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
          State.compiler_call(state, :check_ctor_return, [val])
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
         State.compiler_call(state, :define_static_method, [ctor, key_expr, method])
       )}
    end
  end

  defp lower_get_private_field(state) do
    with {:ok, key, state} <- Emit.pop(state),
         {:ok, obj, state} <- Emit.pop(state) do
      LoweringEffects.effectful_push(
        state,
        State.compiler_call(state, :get_private_field, [obj, key])
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
         | body: [State.compiler_call(state, :put_private_field, [obj, key, val]) | state.body]
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
         | body: [State.compiler_call(state, :define_private_field, [obj, key, val]) | state.body],
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
         Builder.remote_call(Private, :has_private_or_brand?, [obj, key]),
         :boolean
       )}
    end
  end
end
