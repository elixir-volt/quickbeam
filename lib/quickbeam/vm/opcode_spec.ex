defmodule QuickBEAM.VM.OpcodeSpec do
  @moduledoc "Authoritative opcode metadata facade used by decoding, analysis, and compiler dispatch."

  alias QuickBEAM.VM.Opcodes

  @type opcode :: non_neg_integer()
  @type opcode_name :: atom()

  @families %{
    call: [:call, :call0, :call1, :call2, :call3],
    get_slot: [
      :get_arg,
      :get_arg0,
      :get_arg1,
      :get_arg2,
      :get_arg3,
      :get_loc,
      :get_loc0,
      :get_loc1,
      :get_loc2,
      :get_loc3,
      :get_loc8
    ],
    put_slot: [
      :put_loc,
      :put_loc0,
      :put_loc1,
      :put_loc2,
      :put_loc3,
      :put_loc8,
      :put_arg,
      :put_arg0,
      :put_arg1,
      :put_arg2,
      :put_arg3
    ],
    set_slot: [
      :set_loc,
      :set_loc0,
      :set_loc1,
      :set_loc2,
      :set_loc3,
      :set_loc8,
      :set_arg,
      :set_arg0,
      :set_arg1,
      :set_arg2,
      :set_arg3
    ],
    false_branch: [:if_false, :if_false8],
    true_branch: [:if_true, :if_true8],
    goto: [:goto, :goto8, :goto16],
    finally_control: [:catch, :gosub, :goto, :goto8, :goto16]
  }

  @small_int_push %{
    push_minus1: -1,
    push_0: 0,
    push_1: 1,
    push_2: 2,
    push_3: 3,
    push_4: 4,
    push_5: 5,
    push_6: 6,
    push_7: 7
  }

  @opcode_rows Opcodes.table()
  @opcode_names for {_num, {name, _size, _pops, _pushes, _format}} <- @opcode_rows, do: name
  @opcode_formats for {_num, {_name, _size, _pops, _pushes, format}} <- @opcode_rows, do: format

  if length(@opcode_names) != length(Enum.uniq(@opcode_names)) do
    raise "duplicate opcode names in QuickBEAM.VM.OpcodeSpec"
  end

  missing_formats = Enum.uniq(Enum.filter(@opcode_formats, &(Opcodes.format_info(&1) == nil)))

  if missing_formats != [] do
    raise "missing opcode format metadata: #{inspect(missing_formats)}"
  end

  @short_form_formats [:none_loc, :none_arg, :none_var_ref, :none_int, :npopx]
  @short_form_opcodes for {num, {_name, _size, _pops, _pushes, format}} <- @opcode_rows,
                          format in @short_form_formats,
                          do: num

  @invalid_short_forms for num <- @short_form_opcodes,
                           {name, _size, _pops, _pushes, _format} = Map.fetch!(@opcode_rows, num),
                           {canonical, _operands} = Opcodes.expand_short_form(name, [], 0),
                           canonical != name and Opcodes.num(canonical) == nil,
                           do: {num, name, canonical}

  if @invalid_short_forms != [] do
    raise "invalid opcode short-form expansions: #{inspect(@invalid_short_forms)}"
  end

  @call Map.fetch!(@families, :call)
  @get_slot Map.fetch!(@families, :get_slot)
  @put_slot Map.fetch!(@families, :put_slot)
  @set_slot Map.fetch!(@families, :set_slot)
  @small_int_push_names Map.keys(@small_int_push)

  @lowering_groups %{
    stack:
      @small_int_push_names ++
        [
          :push_i32,
          :push_i16,
          :push_i8,
          :push_true,
          :push_false,
          :null,
          :undefined,
          :push_empty_string,
          :push_bigint_i32,
          :push_atom_value,
          :push_this,
          :push_const,
          :push_const8,
          :fclosure,
          :fclosure8,
          :private_symbol,
          :dup,
          :dup1,
          :dup2,
          :dup3,
          :insert2,
          :insert3,
          :insert4,
          :drop,
          :nip,
          :nip1,
          :swap,
          :swap2,
          :rot3l,
          :rot3r,
          :rot4l,
          :rot5l,
          :perm3,
          :perm4,
          :perm5,
          :nop
        ],
    locals:
      @get_slot ++
        @put_slot ++
        @set_slot ++
        [
          :get_loc0_loc1,
          :get_loc_check,
          :set_loc_uninitialized,
          :put_loc_check,
          :put_loc_check_init,
          :close_loc,
          :inc_loc,
          :dec_loc,
          :add_loc
        ],
    calls:
      @call ++
        [
          :call_constructor,
          :tail_call,
          :call_method,
          :tail_call_method,
          :apply,
          :apply_eval,
          :eval,
          :import,
          :return,
          :return_undef
        ],
    objects: [
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
    ],
    arithmetic: [
      :dec,
      :inc,
      :post_dec,
      :post_inc,
      :neg,
      :plus,
      :not,
      :lnot,
      :typeof,
      :is_undefined,
      :is_null,
      :is_undefined_or_null,
      :typeof_is_undefined,
      :typeof_is_function,
      :mul,
      :div,
      :mod,
      :add,
      :sub,
      :shl,
      :sar,
      :shr,
      :lt,
      :lte,
      :gt,
      :gte,
      :eq,
      :neq,
      :strict_eq,
      :strict_neq,
      :band,
      :bxor,
      :bor,
      :pow
    ],
    control: [
      :if_false,
      :if_true,
      :goto,
      :catch,
      :gosub,
      :ret,
      :nip_catch,
      :throw,
      :throw_error,
      :if_false8,
      :if_true8,
      :goto8,
      :goto16
    ],
    iterators: [
      :for_in_start,
      :for_of_start,
      :for_await_of_start,
      :for_in_next,
      :for_of_next,
      :iterator_check_object,
      :iterator_get_value_done,
      :iterator_close,
      :iterator_next,
      :iterator_call,
      :rest
    ],
    classes: [
      :init_ctor,
      :define_method,
      :define_method_computed,
      :define_class,
      :define_class_computed,
      :add_brand,
      :check_brand
    ],
    generators: [:initial_yield, :yield, :yield_star, :async_yield_star, :await, :return_async],
    with_scope: [
      :with_get_var,
      :with_put_var,
      :with_delete_var,
      :with_make_ref,
      :with_get_ref,
      :with_get_ref_undef
    ],
    globals: [
      :get_var_undef,
      :get_var,
      :put_var,
      :put_var_init,
      :get_ref_value,
      :put_ref_value,
      :define_var,
      :check_define_var,
      :define_func,
      :delete_var,
      :get_var_ref,
      :get_var_ref0,
      :get_var_ref1,
      :get_var_ref2,
      :get_var_ref3,
      :get_var_ref_check,
      :put_var_ref,
      :put_var_ref0,
      :put_var_ref1,
      :put_var_ref2,
      :put_var_ref3,
      :put_var_ref_check,
      :put_var_ref_check_init,
      :set_var_ref,
      :set_var_ref0,
      :set_var_ref1,
      :set_var_ref2,
      :set_var_ref3,
      :make_loc_ref,
      :make_arg_ref,
      :make_var_ref_ref,
      :make_var_ref
    ]
  }

  @symbolic_lowering_opcodes [:define_static_method]
  @lowering_pairs for {family, names} <- @lowering_groups, name <- names, do: {name, family}
  @unknown_lowering_opcodes for {name, family} <- @lowering_pairs,
                                Opcodes.num(name) == nil and
                                  name not in @symbolic_lowering_opcodes,
                                do: {name, family}

  if @unknown_lowering_opcodes != [] do
    raise "lowering families reference unknown opcodes: #{inspect(@unknown_lowering_opcodes)}"
  end

  if length(@lowering_pairs) != length(Enum.uniq_by(@lowering_pairs, &elem(&1, 0))) do
    duplicates =
      @lowering_pairs
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    raise "duplicate opcode lowering families: #{inspect(duplicates)}"
  end

  @lowering_families Map.new(@lowering_pairs)

  def table, do: @opcode_rows
  def all_opcodes, do: Opcodes.all_opcodes()
  def info(opcode), do: Opcodes.info(opcode)
  def num(name), do: Opcodes.num(name)
  def format_info(format), do: Opcodes.format_info(format)

  def name(opcode) do
    case info(opcode) do
      {name, _size, _pops, _pushes, _format} -> {:ok, name}
      nil -> {:error, {:unknown_opcode, opcode}}
    end
  end

  def stack_effect(opcode) do
    case info(opcode) do
      {_name, _size, pops, pushes, _format} -> {:ok, {pops, pushes}}
      nil -> {:error, {:unknown_opcode, opcode}}
    end
  end

  def symbolic_stack_effect({:call, argc}), do: {:ok, {1 + argc, 1}}
  def symbolic_stack_effect({:call_method, argc}), do: {:ok, {2 + argc, 1}}
  def symbolic_stack_effect({:call_constructor, argc}), do: {:ok, {2 + argc, 1}}
  def symbolic_stack_effect({:get_var, _name}), do: {:ok, {0, 1}}
  def symbolic_stack_effect({:get_var_undef, _name}), do: {:ok, {0, 1}}
  def symbolic_stack_effect({:put_var, _name}), do: {:ok, {1, 0}}
  def symbolic_stack_effect({:array_from, count}), do: {:ok, {count, 1}}
  def symbolic_stack_effect({:define_field, _name}), do: {:ok, {2, 1}}
  def symbolic_stack_effect({:get_field, _name}), do: {:ok, {1, 1}}
  def symbolic_stack_effect({:get_field2, _name}), do: {:ok, {1, 2}}
  def symbolic_stack_effect({:put_field, _name}), do: {:ok, {2, 0}}
  def symbolic_stack_effect({:define_static_method, _name}), do: {:ok, {2, 0}}
  def symbolic_stack_effect({:set_name, _name}), do: {:ok, {1, 1}}
  def symbolic_stack_effect({:define_method, _name, _flags}), do: {:ok, {2, 1}}
  def symbolic_stack_effect({:define_class, _name, _flags}), do: {:ok, {2, 2}}
  def symbolic_stack_effect({:define_method_computed, _flags}), do: {:ok, {3, 1}}
  def symbolic_stack_effect({:close_loc, _idx}), do: {:ok, {0, 0}}
  def symbolic_stack_effect({:set_loc_uninitialized, _idx}), do: {:ok, {0, 0}}
  def symbolic_stack_effect(:set_home_object), do: {:ok, {2, 2}}
  def symbolic_stack_effect(:check_ctor), do: {:ok, {0, 0}}
  def symbolic_stack_effect(:check_ctor_return), do: {:ok, {1, 2}}
  def symbolic_stack_effect(:add_brand), do: {:ok, {2, 0}}
  def symbolic_stack_effect(:private_in), do: {:ok, {2, 1}}
  def symbolic_stack_effect(:for_of_start), do: {:ok, {1, 3}}
  def symbolic_stack_effect({:for_of_next, _idx}), do: {:ok, {0, 2}}
  def symbolic_stack_effect({:with_get_var, _name, _label}), do: {:ok, {1, 1}}
  def symbolic_stack_effect({:with_put_var, _name, _label}), do: {:ok, {2, 1}}
  def symbolic_stack_effect({:with_delete_var, _name, _label}), do: {:ok, {1, 1}}
  def symbolic_stack_effect(:check_brand), do: {:ok, {2, 2}}
  def symbolic_stack_effect(:get_private_field), do: {:ok, {2, 1}}
  def symbolic_stack_effect(:put_private_field), do: {:ok, {3, 0}}
  def symbolic_stack_effect(:define_private_field), do: {:ok, {3, 1}}
  def symbolic_stack_effect({:private_symbol, _name}), do: {:ok, {0, 1}}
  def symbolic_stack_effect(:set_name_computed), do: {:ok, {2, 2}}
  def symbolic_stack_effect({:catch, _label}), do: {:ok, {0, 1}}
  def symbolic_stack_effect({:gosub, _label}), do: {:ok, {0, 0}}
  def symbolic_stack_effect(:nip_catch), do: {:ok, {2, 1}}
  def symbolic_stack_effect(:ret), do: {:ok, {1, 0}}
  def symbolic_stack_effect({:eval, argc, _scope}), do: {:ok, {1 + argc, 1}}
  def symbolic_stack_effect({op, _label}) when op in [:jump, :gosub], do: {:ok, {0, 0}}

  def symbolic_stack_effect({op, _label}) when op in [:jump_if_false, :jump_if_true],
    do: {:ok, {1, 0}}

  def symbolic_stack_effect({:throw_error, _type, _atom}), do: {:ok, {0, 0}}
  def symbolic_stack_effect({:rest, _start}), do: {:ok, {0, 1}}
  def symbolic_stack_effect(_instruction), do: :error

  def short_form_operands(opcode, arg_count), do: Opcodes.short_form_operands(opcode, arg_count)

  def family(name, family), do: name in Map.fetch!(@families, family)
  def family_members(family), do: Map.fetch!(@families, family)

  def control_flow_family(name) do
    cond do
      family(name, :false_branch) -> {:branch, false}
      family(name, :true_branch) -> {:branch, true}
      family(name, :goto) -> :goto
      family(name, :finally_control) -> :finally_control
      true -> nil
    end
  end

  def small_int_push(name), do: Map.fetch(@small_int_push, name)
  def small_int_push_names, do: @small_int_push_names
  def lowering_family(name), do: Map.get(@lowering_families, name)
end
