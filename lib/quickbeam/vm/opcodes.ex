defmodule QuickBEAM.VM.Opcodes do
  @moduledoc """
  QuickJS opcode metadata generated from the vendored `quickjs-opcode.h`.
  """

  alias QuickBEAM.VM.ABI

  @opcodes ABI.opcodes()
  @tags ABI.tags()
  @name_to_num Map.new(@opcodes, fn {number, {name, _, _, _, _}} -> {name, number} end)
  @js_atom_end map_size(ABI.predefined_atoms()) + 1

  @format_info %{
    none: :zero,
    none_int: :zero,
    none_loc: :zero,
    none_arg: :zero,
    none_var_ref: :zero,
    u8: {:bytes, 1},
    i8: {:bytes, 1},
    loc8: {:bytes, 1},
    const8: {:bytes, 1},
    label8: {:bytes, 1},
    u16: {:bytes, 2},
    i16: {:bytes, 2},
    label16: {:bytes, 2},
    npop: {:bytes, 2},
    npopx: :zero,
    npop_u16: {:bytes, 4},
    loc: {:bytes, 2},
    arg: {:bytes, 2},
    var_ref: {:bytes, 2},
    u32: {:bytes, 4},
    u32x2: {:bytes, 8},
    i32: {:bytes, 4},
    const: {:bytes, 4},
    label: {:bytes, 4},
    atom: {:bytes, 4},
    atom_u8: {:bytes, 5},
    atom_u16: {:bytes, 6},
    atom_label_u8: {:bytes, 9},
    atom_label_u16: {:bytes, 10},
    label_u16: {:bytes, 6}
  }

  @missing_formats @opcodes
                   |> Map.values()
                   |> Enum.map(&elem(&1, 4))
                   |> Enum.uniq()
                   |> Enum.reject(&Map.has_key?(@format_info, &1))

  if @missing_formats != [] do
    raise "missing QuickJS operand formats: #{inspect(@missing_formats)}"
  end

  for {name, value} <- @tags do
    @doc false
    def unquote(:"bc_tag_#{name}")(), do: unquote(value)
  end

  @doc "Returns the vendored QuickJS serialized-bytecode version."
  def bc_version, do: ABI.bytecode_version()

  @doc "Returns the first dynamic atom index in serialized bytecode."
  def js_atom_end, do: @js_atom_end

  @doc "Returns all final-bytecode opcode metadata indexed by opcode byte."
  def table, do: @opcodes

  @doc "Returns metadata for an opcode byte."
  def info(number) when is_integer(number), do: Map.get(@opcodes, number)

  @doc "Returns the opcode byte for a name."
  def num(name) when is_atom(name), do: Map.get(@name_to_num, name)

  @doc "Returns all opcode names mapped to their bytes."
  def all_opcodes, do: @name_to_num

  @doc "Returns operand format width metadata."
  def format_info(format), do: Map.get(@format_info, format)

  @short_forms %{
    push_minus1: {:push_i32, [-1]},
    push_0: {:push_i32, [0]},
    push_1: {:push_i32, [1]},
    push_2: {:push_i32, [2]},
    push_3: {:push_i32, [3]},
    push_4: {:push_i32, [4]},
    push_5: {:push_i32, [5]},
    push_6: {:push_i32, [6]},
    push_7: {:push_i32, [7]},
    get_loc0: {:get_loc, [0]},
    get_loc1: {:get_loc, [1]},
    get_loc2: {:get_loc, [2]},
    get_loc3: {:get_loc, [3]},
    put_loc0: {:put_loc, [0]},
    put_loc1: {:put_loc, [1]},
    put_loc2: {:put_loc, [2]},
    put_loc3: {:put_loc, [3]},
    set_loc0: {:set_loc, [0]},
    set_loc1: {:set_loc, [1]},
    set_loc2: {:set_loc, [2]},
    set_loc3: {:set_loc, [3]},
    get_arg0: {:get_arg, [0]},
    get_arg1: {:get_arg, [1]},
    get_arg2: {:get_arg, [2]},
    get_arg3: {:get_arg, [3]},
    put_arg0: {:put_arg, [0]},
    put_arg1: {:put_arg, [1]},
    put_arg2: {:put_arg, [2]},
    put_arg3: {:put_arg, [3]},
    set_arg0: {:set_arg, [0]},
    set_arg1: {:set_arg, [1]},
    set_arg2: {:set_arg, [2]},
    set_arg3: {:set_arg, [3]},
    get_var_ref0: {:get_var_ref, [0]},
    get_var_ref1: {:get_var_ref, [1]},
    get_var_ref2: {:get_var_ref, [2]},
    get_var_ref3: {:get_var_ref, [3]},
    put_var_ref0: {:put_var_ref, [0]},
    put_var_ref1: {:put_var_ref, [1]},
    put_var_ref2: {:put_var_ref, [2]},
    put_var_ref3: {:put_var_ref, [3]},
    set_var_ref0: {:set_var_ref, [0]},
    set_var_ref1: {:set_var_ref, [1]},
    set_var_ref2: {:set_var_ref, [2]},
    set_var_ref3: {:set_var_ref, [3]},
    call0: {:call, [0]},
    call1: {:call, [1]},
    call2: {:call, [2]},
    call3: {:call, [3]},
    push_empty_string: {:push_atom_value, [:empty_string]},
    get_loc0_loc1: {:get_loc0_loc1, [0, 1]}
  }

  @passthrough_aliases %{
    get_loc8: :get_loc,
    put_loc8: :put_loc,
    set_loc8: :set_loc,
    get_loc_check8: :get_loc_check,
    put_loc_check8: :put_loc_check
  }

  @doc "Expands compact opcode encodings into canonical instructions."
  def expand_short_form(name, args, arg_count \\ 0) do
    case Map.get(@short_forms, name) do
      nil ->
        case Map.get(@passthrough_aliases, name) do
          nil -> {name, args}
          canonical -> {canonical, args}
        end

      {canonical, constant_args} ->
        if canonical in [:get_loc, :put_loc, :set_loc, :get_loc0_loc1] do
          {canonical, Enum.map(constant_args, &(&1 + arg_count))}
        else
          {canonical, constant_args}
        end
    end
  end

  @doc false
  def short_form_operands(opcode, arg_count) when is_integer(opcode) do
    case Map.get(@opcodes, opcode) do
      {name, _size, _pops, _pushes, _format} ->
        {_canonical, operands} = expand_short_form(name, [], arg_count)
        operands

      nil ->
        []
    end
  end
end
