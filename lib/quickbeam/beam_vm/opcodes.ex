defmodule QuickBEAM.BeamVM.Opcodes do
  @moduledoc false
  # Generated from quickjs-opcode.h
  # Each entry: {name, byte_size, n_pop, n_push, format}

  # BC_TAG values (top-level serialization tags, not opcodes)
  @bc_tag_null 1
  @bc_tag_undefined 2
  @bc_tag_bool_false 3
  @bc_tag_bool_true 4
  @bc_tag_int32 5
  @bc_tag_float64 6
  @bc_tag_string 7
  @bc_tag_object 8
  @bc_tag_array 9
  @bc_tag_big_int 10
  @bc_tag_template_object 11
  @bc_tag_function_bytecode 12
  @bc_tag_module 13
  @bc_tag_typed_array 14
  @bc_tag_array_buffer 15
  @bc_tag_shared_array_buffer 16
  @bc_tag_regexp 17
  @bc_tag_date 18
  @bc_tag_object_value 19
  @bc_tag_object_reference 20
  @bc_tag_map 21
  @bc_tag_set 22
  @bc_tag_symbol 23

  def bc_tag_null, do: @bc_tag_null
  def bc_tag_undefined, do: @bc_tag_undefined
  def bc_tag_bool_false, do: @bc_tag_bool_false
  def bc_tag_bool_true, do: @bc_tag_bool_true
  def bc_tag_int32, do: @bc_tag_int32
  def bc_tag_float64, do: @bc_tag_float64
  def bc_tag_string, do: @bc_tag_string
  def bc_tag_object, do: @bc_tag_object
  def bc_tag_array, do: @bc_tag_array
  def bc_tag_big_int, do: @bc_tag_big_int
  def bc_tag_function_bytecode, do: @bc_tag_function_bytecode
  def bc_tag_module, do: @bc_tag_module
  def bc_tag_regexp, do: @bc_tag_regexp

  @bc_version 24
  def bc_version, do: @bc_version

  # Opcode format types — determine how operand bytes are decoded
  # :none / :none_int / :none_loc / :none_arg / :none_var_ref → 0 extra bytes
  # :u8 / :i8 / :loc8 / :const8 / :label8 → 1 byte
  # :u16 / :i16 / :label16 → 2 bytes
  # :npop / :npopx → 1 byte (argc)
  # :npop_u16 → 1 byte + 2 bytes
  # :loc / :arg / :var_ref → LEB128
  # :u32 → LEB128
  # :u32x2 → LEB128 + LEB128
  # :i32 → SLEB128
  # :const → LEB128
  # :label → LEB128
  # :atom → LEB128 (atom table index)
  # :atom_u8 → LEB128 + 1 byte
  # :atom_u16 → LEB128 + 2 bytes
  # :atom_label_u8 → LEB128 + LEB128 + 1 byte
  # :atom_label_u16 → LEB128 + LEB128 + 2 bytes
  # :label_u16 → LEB128 + 2 bytes

  # Format → :zero | {:bytes, pos_integer} | :leb128 | :mixed
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
    npop: {:bytes, 1},
    npopx: :zero,
    npop_u16: :npop_u16,
    loc: :leb128,
    arg: :leb128,
    var_ref: :leb128,
    u32: :leb128,
    u32x2: :leb128_leb128,
    i32: :sleb128,
    const: :leb128,
    label: :leb128,
    atom: :leb128,
    atom_u8: :atom_u8,
    atom_u16: :atom_u16,
    atom_label_u8: :atom_label_u8,
    atom_label_u16: :atom_label_u16,
    label_u16: :label_u16
  }

  # Full opcode table: {opcode_number, name, byte_size, n_pop, n_push, format}
  # Parsed from quickjs-opcode.h — order matters, index = opcode number
  @opcodes %{
    0 => {:invalid, 1, 0, 0, :none},
    1 => {:push_i32, 5, 0, 1, :i32},
    2 => {:push_const, 5, 0, 1, :const},
    3 => {:fclosure, 5, 0, 1, :const},
    4 => {:push_atom_value, 5, 0, 1, :atom},
    5 => {:private_symbol, 5, 0, 1, :atom},
    6 => {:undefined, 1, 0, 1, :none},
    7 => {:null, 1, 0, 1, :none},
    8 => {:push_this, 1, 0, 1, :none},
    9 => {:push_false, 1, 0, 1, :none},
    10 => {:push_true, 1, 0, 1, :none},
    11 => {:object, 1, 0, 1, :none},
    12 => {:special_object, 2, 0, 1, :u8},
    13 => {:rest, 3, 0, 1, :u16},
    14 => {:drop, 1, 1, 0, :none},
    15 => {:nip, 1, 2, 1, :none},
    16 => {:nip1, 1, 3, 2, :none},
    17 => {:dup, 1, 1, 2, :none},
    18 => {:dup1, 1, 2, 3, :none},
    19 => {:dup2, 1, 2, 4, :none},
    20 => {:dup3, 1, 3, 6, :none},
    21 => {:insert2, 1, 2, 3, :none},
    22 => {:insert3, 1, 3, 4, :none},
    23 => {:insert4, 1, 4, 5, :none},
    24 => {:perm3, 1, 3, 3, :none},
    25 => {:perm4, 1, 4, 4, :none},
    26 => {:perm5, 1, 5, 5, :none},
    27 => {:swap, 1, 2, 2, :none},
    28 => {:swap2, 1, 4, 4, :none},
    29 => {:rot3l, 1, 3, 3, :none},
    30 => {:rot3r, 1, 3, 3, :none},
    31 => {:rot4l, 1, 4, 4, :none},
    32 => {:rot5l, 1, 5, 5, :none},
    33 => {:call_constructor, 3, 2, 1, :npop},
    34 => {:call, 3, 1, 1, :npop},
    35 => {:tail_call, 3, 1, 0, :npop},
    36 => {:call_method, 3, 2, 1, :npop},
    37 => {:tail_call_method, 3, 2, 0, :npop},
    38 => {:array_from, 3, 0, 1, :npop},
    39 => {:apply, 3, 3, 1, :u16},
    40 => {:return, 1, 1, 0, :none},
    41 => {:return_undef, 1, 0, 0, :none},
    42 => {:check_ctor_return, 1, 1, 2, :none},
    43 => {:check_ctor, 1, 0, 0, :none},
    44 => {:init_ctor, 1, 0, 1, :none},
    45 => {:check_brand, 1, 2, 2, :none},
    46 => {:add_brand, 1, 2, 0, :none},
    47 => {:return_async, 1, 1, 0, :none},
    48 => {:throw, 1, 1, 0, :none},
    49 => {:throw_error, 6, 0, 0, :atom_u8},
    50 => {:eval, 5, 1, 1, :npop_u16},
    51 => {:apply_eval, 3, 2, 1, :u16},
    52 => {:regexp, 1, 2, 1, :none},
    53 => {:get_super, 1, 1, 1, :none},
    54 => {:import, 1, 2, 1, :none},
    55 => {:get_var_undef, 5, 0, 1, :atom},
    56 => {:get_var, 5, 0, 1, :atom},
    57 => {:put_var, 5, 1, 0, :atom},
    58 => {:put_var_init, 5, 1, 0, :atom},
    59 => {:get_ref_value, 1, 2, 3, :none},
    60 => {:put_ref_value, 1, 3, 0, :none},
    61 => {:define_var, 6, 0, 0, :atom_u8},
    62 => {:check_define_var, 6, 0, 0, :atom_u8},
    63 => {:define_func, 6, 1, 0, :atom_u8},
    64 => {:get_field, 5, 1, 1, :atom},
    65 => {:get_field2, 5, 1, 2, :atom},
    66 => {:put_field, 5, 2, 0, :atom},
    67 => {:get_private_field, 1, 2, 1, :none},
    68 => {:put_private_field, 1, 3, 0, :none},
    69 => {:define_private_field, 1, 3, 1, :none},
    70 => {:get_array_el, 1, 2, 1, :none},
    71 => {:get_array_el2, 1, 2, 2, :none},
    72 => {:put_array_el, 1, 3, 0, :none},
    73 => {:get_super_value, 1, 3, 1, :none},
    74 => {:put_super_value, 1, 4, 0, :none},
    75 => {:define_field, 5, 2, 1, :atom},
    76 => {:set_name, 5, 1, 1, :atom},
    77 => {:set_name_computed, 1, 2, 2, :none},
    78 => {:set_proto, 1, 2, 1, :none},
    79 => {:set_home_object, 1, 2, 2, :none},
    80 => {:define_array_el, 1, 3, 2, :none},
    81 => {:append, 1, 3, 2, :none},
    82 => {:copy_data_properties, 2, 3, 3, :u8},
    83 => {:define_method, 6, 2, 1, :atom_u8},
    84 => {:define_method_computed, 2, 3, 1, :u8},
    85 => {:define_class, 6, 2, 2, :atom_u8},
    86 => {:define_class_computed, 6, 3, 3, :atom_u8},
    87 => {:get_loc, 3, 0, 1, :loc},
    88 => {:put_loc, 3, 1, 0, :loc},
    89 => {:set_loc, 3, 1, 1, :loc},
    90 => {:get_arg, 3, 0, 1, :arg},
    91 => {:put_arg, 3, 1, 0, :arg},
    92 => {:set_arg, 3, 1, 1, :arg},
    93 => {:get_var_ref, 3, 0, 1, :var_ref},
    94 => {:put_var_ref, 3, 1, 0, :var_ref},
    95 => {:set_var_ref, 3, 1, 1, :var_ref},
    96 => {:set_loc_uninitialized, 3, 0, 0, :loc},
    97 => {:get_loc_check, 3, 0, 1, :loc},
    98 => {:put_loc_check, 3, 1, 0, :loc},
    99 => {:put_loc_check_init, 3, 1, 0, :loc},
    100 => {:get_var_ref_check, 3, 0, 1, :var_ref},
    101 => {:put_var_ref_check, 3, 1, 0, :var_ref},
    102 => {:put_var_ref_check_init, 3, 1, 0, :var_ref},
    103 => {:close_loc, 3, 0, 0, :loc},
    104 => {:if_false, 5, 1, 0, :label},
    105 => {:if_true, 5, 1, 0, :label},
    106 => {:goto, 5, 0, 0, :label},
    107 => {:catch, 5, 0, 1, :label},
    108 => {:gosub, 5, 0, 0, :label},
    109 => {:ret, 1, 1, 0, :none},
    110 => {:nip_catch, 1, 2, 1, :none},
    111 => {:to_object, 1, 1, 1, :none},
    112 => {:to_propkey, 1, 1, 1, :none},
    113 => {:to_propkey2, 1, 2, 2, :none},
    114 => {:with_get_var, 10, 1, 0, :atom_label_u8},
    115 => {:with_put_var, 10, 2, 1, :atom_label_u8},
    116 => {:with_delete_var, 10, 1, 0, :atom_label_u8},
    117 => {:with_make_ref, 10, 1, 0, :atom_label_u8},
    118 => {:with_get_ref, 10, 1, 0, :atom_label_u8},
    119 => {:with_get_ref_undef, 10, 1, 0, :atom_label_u8},
    120 => {:make_loc_ref, 7, 0, 2, :atom_u16},
    121 => {:make_arg_ref, 7, 0, 2, :atom_u16},
    122 => {:make_var_ref_ref, 7, 0, 2, :atom_u16},
    123 => {:make_var_ref, 5, 0, 2, :atom},
    124 => {:for_in_start, 1, 1, 1, :none},
    125 => {:for_of_start, 1, 1, 3, :none},
    126 => {:for_await_of_start, 1, 1, 3, :none},
    127 => {:for_in_next, 1, 1, 3, :none},
    128 => {:for_of_next, 2, 3, 5, :u8},
    129 => {:iterator_check_object, 1, 1, 1, :none},
    130 => {:iterator_get_value_done, 1, 1, 2, :none},
    131 => {:iterator_close, 1, 3, 0, :none},
    132 => {:iterator_next, 1, 4, 4, :none},
    133 => {:iterator_call, 2, 4, 5, :u8},
    134 => {:initial_yield, 1, 0, 0, :none},
    135 => {:yield, 1, 1, 2, :none},
    136 => {:yield_star, 1, 1, 2, :none},
    137 => {:async_yield_star, 1, 1, 2, :none},
    138 => {:await, 1, 1, 1, :none},
    139 => {:neg, 1, 1, 1, :none},
    140 => {:plus, 1, 1, 1, :none},
    141 => {:dec, 1, 1, 1, :none},
    142 => {:inc, 1, 1, 1, :none},
    143 => {:post_dec, 1, 1, 2, :none},
    144 => {:post_inc, 1, 1, 2, :none},
    145 => {:dec_loc, 2, 0, 0, :loc8},
    146 => {:inc_loc, 2, 0, 0, :loc8},
    147 => {:add_loc, 2, 1, 0, :loc8},
    148 => {:not, 1, 1, 1, :none},
    149 => {:lnot, 1, 1, 1, :none},
    150 => {:typeof, 1, 1, 1, :none},
    151 => {:delete, 1, 2, 1, :none},
    152 => {:delete_var, 5, 0, 1, :atom},
    153 => {:mul, 1, 2, 1, :none},
    154 => {:div, 1, 2, 1, :none},
    155 => {:mod, 1, 2, 1, :none},
    156 => {:add, 1, 2, 1, :none},
    157 => {:sub, 1, 2, 1, :none},
    158 => {:shl, 1, 2, 1, :none},
    159 => {:sar, 1, 2, 1, :none},
    160 => {:shr, 1, 2, 1, :none},
    161 => {:band, 1, 2, 1, :none},
    162 => {:bxor, 1, 2, 1, :none},
    163 => {:bor, 1, 2, 1, :none},
    164 => {:pow, 1, 2, 1, :none},
    165 => {:lt, 1, 2, 1, :none},
    166 => {:lte, 1, 2, 1, :none},
    167 => {:gt, 1, 2, 1, :none},
    168 => {:gte, 1, 2, 1, :none},
    169 => {:instanceof, 1, 2, 1, :none},
    170 => {:in, 1, 2, 1, :none},
    171 => {:eq, 1, 2, 1, :none},
    172 => {:neq, 1, 2, 1, :none},
    173 => {:strict_eq, 1, 2, 1, :none},
    174 => {:strict_neq, 1, 2, 1, :none},
    175 => {:is_undefined_or_null, 1, 1, 1, :none},
    176 => {:private_in, 1, 2, 1, :none},
    177 => {:push_bigint_i32, 5, 0, 1, :i32},
    178 => {:nop, 1, 0, 0, :none},
    179 => {:push_minus1, 1, 0, 1, :none_int},
    180 => {:push_0, 1, 0, 1, :none_int},
    181 => {:push_1, 1, 0, 1, :none_int},
    182 => {:push_2, 1, 0, 1, :none_int},
    183 => {:push_3, 1, 0, 1, :none_int},
    184 => {:push_4, 1, 0, 1, :none_int},
    185 => {:push_5, 1, 0, 1, :none_int},
    186 => {:push_6, 1, 0, 1, :none_int},
    187 => {:push_7, 1, 0, 1, :none_int},
    188 => {:push_i8, 2, 0, 1, :i8},
    189 => {:push_i16, 3, 0, 1, :i16},
    190 => {:push_const8, 2, 0, 1, :const8},
    191 => {:fclosure8, 2, 0, 1, :const8},
    192 => {:push_empty_string, 1, 0, 1, :none},
    193 => {:get_loc8, 2, 0, 1, :loc8},
    194 => {:put_loc8, 2, 1, 0, :loc8},
    195 => {:set_loc8, 2, 1, 1, :loc8},
    196 => {:get_loc0_loc1, 1, 0, 2, :none_loc},
    197 => {:get_loc0, 1, 0, 1, :none_loc},
    198 => {:get_loc1, 1, 0, 1, :none_loc},
    199 => {:get_loc2, 1, 0, 1, :none_loc},
    200 => {:get_loc3, 1, 0, 1, :none_loc},
    201 => {:put_loc0, 1, 1, 0, :none_loc},
    202 => {:put_loc1, 1, 1, 0, :none_loc},
    203 => {:put_loc2, 1, 1, 0, :none_loc},
    204 => {:put_loc3, 1, 1, 0, :none_loc},
    205 => {:set_loc0, 1, 1, 1, :none_loc},
    206 => {:set_loc1, 1, 1, 1, :none_loc},
    207 => {:set_loc2, 1, 1, 1, :none_loc},
    208 => {:set_loc3, 1, 1, 1, :none_loc},
    209 => {:get_arg0, 1, 0, 1, :none_arg},
    210 => {:get_arg1, 1, 0, 1, :none_arg},
    211 => {:get_arg2, 1, 0, 1, :none_arg},
    212 => {:get_arg3, 1, 0, 1, :none_arg},
    213 => {:put_arg0, 1, 1, 0, :none_arg},
    214 => {:put_arg1, 1, 1, 0, :none_arg},
    215 => {:put_arg2, 1, 1, 0, :none_arg},
    216 => {:put_arg3, 1, 1, 0, :none_arg},
    217 => {:set_arg0, 1, 1, 1, :none_arg},
    218 => {:set_arg1, 1, 1, 1, :none_arg},
    219 => {:set_arg2, 1, 1, 1, :none_arg},
    220 => {:set_arg3, 1, 1, 1, :none_arg},
    221 => {:get_var_ref0, 1, 0, 1, :none_var_ref},
    222 => {:get_var_ref1, 1, 0, 1, :none_var_ref},
    223 => {:get_var_ref2, 1, 0, 1, :none_var_ref},
    224 => {:get_var_ref3, 1, 0, 1, :none_var_ref},
    225 => {:put_var_ref0, 1, 1, 0, :none_var_ref},
    226 => {:put_var_ref1, 1, 1, 0, :none_var_ref},
    227 => {:put_var_ref2, 1, 1, 0, :none_var_ref},
    228 => {:put_var_ref3, 1, 1, 0, :none_var_ref},
    229 => {:set_var_ref0, 1, 1, 1, :none_var_ref},
    230 => {:set_var_ref1, 1, 1, 1, :none_var_ref},
    231 => {:set_var_ref2, 1, 1, 1, :none_var_ref},
    232 => {:set_var_ref3, 1, 1, 1, :none_var_ref},
    233 => {:get_length, 1, 1, 1, :none},
    234 => {:if_false8, 2, 1, 0, :label8},
    235 => {:if_true8, 2, 1, 0, :label8},
    236 => {:goto8, 2, 0, 0, :label8},
    237 => {:goto16, 3, 0, 0, :label16},
    238 => {:call0, 1, 1, 1, :npopx},
    239 => {:call1, 1, 1, 1, :npopx},
    240 => {:call2, 1, 1, 1, :npopx},
    241 => {:call3, 1, 1, 1, :npopx},
    242 => {:is_undefined, 1, 1, 1, :none},
    243 => {:is_null, 1, 1, 1, :none},
    244 => {:typeof_is_undefined, 1, 1, 1, :none},
    245 => {:typeof_is_function, 1, 1, 1, :none}
  }

  @name_to_num for {num, {name, _, _, _, _}} <- @opcodes, into: %{}, do: {name, num}

  def info(num) when is_integer(num), do: Map.get(@opcodes, num)
  def num(name) when is_atom(name), do: Map.get(@name_to_num, name)

  def format_info(fmt), do: Map.get(@format_info, fmt)

  # Short-form opcodes expand to their canonical form
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
    get_loc0_loc1: {:get_loc0_loc1, []}
  }

  @passthrough_aliases %{
    get_loc8: :get_loc,
    put_loc8: :put_loc,
    set_loc8: :set_loc,
    get_loc_check8: :get_loc_check,
    put_loc_check8: :put_loc_check,
    fclosure8: :fclosure8,
    push_const8: :push_const8,
    push_i8: :push_i8,
    push_i16: :push_i16,
  }

  def expand_short_form(name, args) do
    case Map.get(@short_forms, name) do
      nil ->
        case Map.get(@passthrough_aliases, name) do
          nil -> {name, args}
          canonical -> {canonical, args}
        end
      {canonical, const_args} -> {canonical, const_args}
    end
  end
end
