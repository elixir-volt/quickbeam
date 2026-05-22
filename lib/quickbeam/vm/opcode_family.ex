defmodule QuickBEAM.VM.OpcodeFamily do
  @moduledoc "Canonical opcode-family metadata shared by lowering and interpreter adapters."

  alias QuickBEAM.VM.OpcodeSpec

  @call OpcodeSpec.family_members(:call)
  @get_slot OpcodeSpec.family_members(:get_slot)
  @put_slot OpcodeSpec.family_members(:put_slot)
  @set_slot OpcodeSpec.family_members(:set_slot)
  @false_branch OpcodeSpec.family_members(:false_branch)
  @true_branch OpcodeSpec.family_members(:true_branch)
  @goto OpcodeSpec.family_members(:goto)
  @finally_control OpcodeSpec.family_members(:finally_control)
  @small_int_push OpcodeSpec.small_int_push_names()

  defguard is_call(name) when name in @call
  defguard is_get_slot(name) when name in @get_slot
  defguard is_put_slot(name) when name in @put_slot
  defguard is_set_slot(name) when name in @set_slot
  defguard is_false_branch(name) when name in @false_branch
  defguard is_true_branch(name) when name in @true_branch
  defguard is_goto(name) when name in @goto
  defguard is_finally_control(name) when name in @finally_control
  defguard is_small_int_push(name) when name in @small_int_push

  def call?(name), do: name in @call
  def get_slot?(name), do: name in @get_slot
  def put_slot?(name), do: name in @put_slot
  def set_slot?(name), do: name in @set_slot
  def false_branch?(name), do: OpcodeSpec.control_flow_family(name) == {:branch, false}
  def true_branch?(name), do: OpcodeSpec.control_flow_family(name) == {:branch, true}
  def goto?(name), do: OpcodeSpec.control_flow_family(name) == :goto
  def finally_control?(name), do: OpcodeSpec.control_flow_family(name) == :finally_control

  def small_int_push(name), do: OpcodeSpec.small_int_push(name)
end
