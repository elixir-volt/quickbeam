defmodule QuickBEAM.VM.Function do
  @moduledoc "JavaScript function metadata and pre-resolved VM instructions used by the interpreter and BEAM compiler."

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :name,
    :filename,
    line_num: 1,
    col_num: 1,
    pc2line: <<>>,
    source: <<>>,
    source_positions: nil,
    arg_count: 0,
    var_count: 0,
    defined_arg_count: 0,
    stack_size: 0,
    var_ref_count: 0,
    locals: [],
    closure_vars: [],
    constants: [],
    atoms: nil,
    extra_atoms: [],
    instructions: nil,
    has_prototype: false,
    has_simple_parameter_list: false,
    is_derived_class_constructor: false,
    need_home_object: false,
    func_kind: 0,
    new_target_allowed: false,
    super_call_allowed: false,
    super_allowed: false,
    arguments_allowed: false,
    is_strict_mode: false,
    has_debug_info: false
  ]
end
