defmodule QuickBEAM.VM.Value do
  @moduledoc "Type definitions and guards for JS values in the BEAM VM."

  alias QuickBEAM.VM.Bytecode

  @type heap_ref :: reference() | pos_integer()
  @type object :: {:obj, heap_ref()}
  @type closure :: {:closure, map(), Bytecode.Function.t()}
  @type builtin :: {:builtin, binary(), function() | map()}
  @type bound :: {:bound, non_neg_integer(), term(), term(), list()}
  @type symbol :: {:symbol, binary()} | {:symbol, binary(), reference()}
  @type bigint :: {:bigint, integer()}
  @type js_value ::
          nil
          | :undefined
          | :nan
          | :infinity
          | :neg_infinity
          | boolean()
          | number()
          | binary()
          | object()
          | closure()
          | builtin()
          | bound()
          | symbol()
          | bigint()

  defguard is_object(v) when is_tuple(v) and tuple_size(v) == 2 and elem(v, 0) == :obj

  defguard is_symbol(v)
           when is_tuple(v) and (tuple_size(v) == 2 or tuple_size(v) == 3) and
                  elem(v, 0) == :symbol

  defguard is_bigint(v) when is_tuple(v) and tuple_size(v) == 2 and elem(v, 0) == :bigint
  defguard is_closure(v) when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :closure
  defguard is_builtin(v) when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :builtin
  defguard is_nullish(v) when v == nil or v == :undefined
end
