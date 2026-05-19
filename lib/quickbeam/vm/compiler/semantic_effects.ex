defmodule QuickBEAM.VM.Compiler.SemanticEffects do
  @moduledoc """
  Semantic effects for VM operations that can invalidate compiler assumptions.

  JavaScript abstract operations can call user code, throw, mutate objects or
  globals, enqueue jobs, and invalidate object-shape assumptions. This metadata is
  intentionally conservative and should grow alongside compiler optimizations.
  """

  @default_effect %{
    calls_js?: false,
    can_throw?: false,
    can_mutate_heap?: false,
    can_mutate_globals?: false,
    can_run_microtasks?: false,
    invalidates_shape_aliases?: false,
    invalidates_global_bindings?: false,
    requires_iterator_close_on_abrupt?: false
  }

  @effects %{
    to_property_key: %{
      calls_js?: true,
      can_throw?: true,
      invalidates_shape_aliases?: true
    },
    copy_data_properties: %{
      calls_js?: true,
      can_throw?: true,
      can_mutate_heap?: true,
      invalidates_shape_aliases?: true
    },
    create_data_property: %{
      can_throw?: true,
      can_mutate_heap?: true,
      invalidates_shape_aliases?: true
    },
    get_field: %{
      calls_js?: true,
      can_throw?: true,
      invalidates_shape_aliases?: true
    },
    put_field: %{
      calls_js?: true,
      can_throw?: true,
      can_mutate_heap?: true,
      invalidates_shape_aliases?: true
    },
    delete_property: %{
      calls_js?: true,
      can_throw?: true,
      can_mutate_heap?: true,
      invalidates_shape_aliases?: true
    },
    in_operator: %{
      calls_js?: true,
      can_throw?: true
    },
    append_spread: %{
      calls_js?: true,
      can_throw?: true,
      can_mutate_heap?: true,
      invalidates_shape_aliases?: true
    },
    iterator_close: %{
      calls_js?: true,
      can_throw?: true,
      requires_iterator_close_on_abrupt?: true
    }
  }

  def effect(operation), do: Map.merge(@default_effect, Map.get(@effects, operation, %{}))

  def calls_js?(operation), do: Map.get(effect(operation), :calls_js?, false)

  def invalidates_shape_aliases?(operation),
    do: Map.get(effect(operation), :invalidates_shape_aliases?, false)

  def can_throw?(operation), do: Map.get(effect(operation), :can_throw?, false)

  def can_mutate_heap?(operation), do: Map.get(effect(operation), :can_mutate_heap?, false)
end
