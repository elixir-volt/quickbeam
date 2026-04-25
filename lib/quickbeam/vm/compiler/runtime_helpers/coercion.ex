defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Coercion do
  @moduledoc "Entry-point context setup, type coercion, capture cells, and async support."

  import Bitwise, only: [bnot: 1]

  alias QuickBEAM.VM.{Builtin, GlobalEnv, Heap, Interpreter}
  alias QuickBEAM.VM.Environment.Captures
  alias QuickBEAM.VM.Interpreter.{Context, Values}

  @tdz :__tdz__

  def entry_ctx do
    case Heap.get_ctx() do
      %Context{} = ctx ->
        Context.mark_dirty(ctx)

      map when is_map(map) ->
        map |> context_struct() |> Context.mark_dirty()

      _ ->
        %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}
        |> Context.mark_dirty()
    end
  end

  def ensure_initialized_local!(_ctx \\ nil, val) do
    if val == @tdz do
      throw(
        {:js_throw,
         Heap.make_error("Cannot access variable before initialization", "ReferenceError")}
      )
    end

    val
  end

  def undefined?(_ctx \\ nil, val), do: val == :undefined
  def null?(_ctx \\ nil, val), do: val == nil
  def typeof_is_undefined(_ctx \\ nil, val), do: val == :undefined or val == nil
  def typeof_is_function(_ctx \\ nil, val), do: Builtin.callable?(val)

  def strict_neq(_ctx \\ nil, a, b), do: not Values.strict_eq(a, b)

  def bit_not(_ctx \\ nil, a), do: Values.to_int32(bnot(Values.to_int32(a)))
  def lnot(_ctx \\ nil, a), do: not Values.truthy?(a)

  def inc(_ctx \\ nil, a), do: Values.add(a, 1)
  def dec(_ctx \\ nil, a), do: Values.sub(a, 1)

  def post_inc(_ctx \\ nil, a) do
    num = Values.to_number(a)
    {Values.add(num, 1), num}
  end

  def post_dec(_ctx \\ nil, a) do
    num = Values.to_number(a)
    {Values.sub(num, 1), num}
  end

  def ensure_capture_cell(_ctx \\ nil, cell, val), do: Captures.ensure(cell, val)
  def close_capture_cell(_ctx \\ nil, cell, val), do: Captures.close(cell, val)
  def sync_capture_cell(_ctx \\ nil, cell, val), do: Captures.sync(cell, val)

  def await(_ctx \\ nil, val), do: Interpreter.resolve_awaited(val)

  def context_struct(%Context{} = ctx), do: ctx

  def context_struct(map) when is_map(map) do
    struct(Context, Map.merge(Map.from_struct(%Context{}), map))
  end

  def context_atoms(%{atoms: atoms}), do: atoms
  def context_atoms(_), do: {}
  def context_globals(%{globals: globals}), do: globals
  def context_globals(_), do: GlobalEnv.base_globals()
  def context_current_func(%{current_func: current_func}), do: current_func
  def context_current_func(_), do: :undefined
  def context_arg_buf(%{arg_buf: arg_buf}), do: arg_buf
  def context_arg_buf(_), do: {}
  def context_this(%{this: this}), do: this
  def context_this(_), do: :undefined
  def context_new_target(%{new_target: new_target}), do: new_target
  def context_new_target(_), do: :undefined
  def context_gas(%{gas: gas}), do: gas
  def context_gas(_), do: Context.default_gas()

  def ensure_context(%Context{} = ctx), do: ctx
  def ensure_context(map) when is_map(map), do: context_struct(map)

  def ensure_context(_),
    do: %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}

  def context_home_object(ctx, current_func) do
    case Map.get(ctx, :home_object, :undefined) do
      :undefined -> QuickBEAM.VM.ObjectModel.Functions.current_home_object(current_func)
      home_object -> home_object
    end
  end

  def context_super(ctx) do
    case Map.get(ctx, :super, :undefined) do
      :undefined ->
        QuickBEAM.VM.ObjectModel.Class.get_super(
          context_home_object(ctx, context_current_func(ctx))
        )

      super ->
        super
    end
  end
end
