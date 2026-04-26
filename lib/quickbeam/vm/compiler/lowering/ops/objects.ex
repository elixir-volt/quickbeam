defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Objects do
  @moduledoc "Object and array manipulation opcodes: get/put_field, get/put_array_el, define_field, set_name, set_proto, get/put_super, private fields, delete, in, instanceof."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.ObjectModel.{Class, Delete, Get, Private, Put}

  @doc "Lowers a bytecode instruction or function into compiler IR."
  def lower(state, name_args) do
    case name_args do
      {{:ok, :object}, []} ->
        {obj, state} =
          State.bind(
            state,
            Builder.temp_name(state.temp),
            Builder.remote_call(QuickBEAM.VM.Heap, :wrap, [Builder.literal(%{})])
          )

        {:ok, State.push(state, obj, {:shaped_object, %{}})}

      {{:ok, :array_from}, [argc]} ->
        State.array_from_call(state, argc)

      {{:ok, :regexp}, []} ->
        State.regexp_literal(state)

      {{:ok, :special_object}, [type]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(state, :special_object, [Builder.literal(type)]),
           special_object_type(type)
         )}

      {{:ok, :set_name}, [atom_idx]} ->
        State.set_name_atom(state, Builder.atom_name(state, atom_idx))

      {{:ok, :set_name_computed}, []} ->
        State.set_name_computed(state)

      {{:ok, :set_home_object}, []} ->
        State.set_home_object(state)

      {{:ok, :get_super}, []} ->
        State.unary_call(state, RuntimeHelpers, :get_super)

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

      {{:ok, :define_field}, [atom_idx]} ->
        State.define_field_name_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :get_array_el}, []} ->
        State.binary_call(state, Put, :get_element)

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
        {:ok, state}

      {{:ok, :to_propkey}, []} ->
        {:ok, state}

      {{:ok, :to_propkey2}, []} ->
        {:ok, state}

      {{:ok, :get_length}, []} ->
        State.get_length_call(state)

      {{:ok, :instanceof}, []} ->
        State.binary_call(state, RuntimeHelpers, :instanceof)

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
    with {:ok, proto, state} <- State.pop(state),
         {:ok, obj, _obj_type, state} <- State.pop_typed(state) do
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
    with {:ok, key, state} <- State.pop(state),
         {:ok, proto, state} <- State.pop(state),
         {:ok, this_obj, state} <- State.pop(state) do
      State.effectful_push(
        state,
        Builder.remote_call(Class, :get_super_value, [proto, this_obj, key])
      )
    end
  end

  defp lower_put_super_value(state) do
    with {:ok, val, state} <- State.pop(state),
         {:ok, key, state} <- State.pop(state),
         {:ok, proto_obj, state} <- State.pop(state),
         {:ok, this_obj, state} <- State.pop(state) do
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

  defp lower_check_ctor_return(state) do
    with {:ok, val, state} <- State.pop(state) do
      {pair, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          Builder.remote_call(Class, :check_ctor_return, [val])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:unknown, :unknown | state.stack_types]
       }}
    end
  end

  defp lower_get_private_field(state) do
    with {:ok, key, state} <- State.pop(state),
         {:ok, obj, state} <- State.pop(state) do
      State.effectful_push(
        state,
        State.compiler_call(state, :get_private_field, [obj, key])
      )
    end
  end

  defp lower_put_private_field(state) do
    with {:ok, key, state} <- State.pop(state),
         {:ok, val, state} <- State.pop(state),
         {:ok, obj, state} <- State.pop(state) do
      {:ok,
       %{
         state
         | body: [State.compiler_call(state, :put_private_field, [obj, key, val]) | state.body]
       }}
    end
  end

  defp lower_define_private_field(state) do
    with {:ok, val, state} <- State.pop(state),
         {:ok, key, state} <- State.pop(state),
         {:ok, obj, _obj_type, state} <- State.pop_typed(state) do
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
    with {:ok, key, state} <- State.pop(state),
         {:ok, obj, state} <- State.pop(state) do
      {:ok,
       State.push(
         state,
         Builder.remote_call(Private, :has_field?, [obj, key]),
         :boolean
       )}
    end
  end

  # Suppress unused alias warning — Delete is referenced via the module attribute path
  _ = Delete
  _ = Get
end
