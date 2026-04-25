defmodule QuickBEAM.VM.Invocation.Context do
  @moduledoc "Fast-context snapshot and restoration: serialises the interpreter context into/out of process dictionary for JIT calls."

  alias QuickBEAM.VM.{Bytecode, Heap, Runtime}
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.ObjectModel.{Class, Functions}

  @fast_ctx_key :qb_fast_ctx
  @missing :__qb_missing__

  def snapshot_fast_ctx, do: Process.get(@fast_ctx_key, @missing)

  def restore_fast_ctx(@missing), do: Process.delete(@fast_ctx_key)
  def restore_fast_ctx(snapshot), do: Process.put(@fast_ctx_key, snapshot)

  def put_fast_ctx(ctx) do
    current_func = Map.get(ctx, :current_func, :undefined)
    home_object = Functions.current_home_object(current_func)

    Process.put(
      @fast_ctx_key,
      {
        Map.get(ctx, :atoms, {}),
        Map.get(ctx, :globals, %{}),
        current_func,
        Map.get(ctx, :arg_buf, {}),
        Map.get(ctx, :this, :undefined),
        Map.get(ctx, :new_target, :undefined),
        home_object,
        current_super(home_object)
      }
    )
  end

  def fast_ctx, do: Process.get(@fast_ctx_key, @missing)

  def attach_method_state(
        %Context{current_func: %Bytecode.Function{need_home_object: false}} = ctx
      ),
      do: ctx

  def attach_method_state(
        %Context{current_func: {:closure, _, %Bytecode.Function{need_home_object: false}}} = ctx
      ),
      do: ctx

  def attach_method_state(%Context{current_func: current_func} = ctx) do
    home_object = Functions.current_home_object(current_func)

    ctx
    |> Map.merge(%{home_object: home_object, super: current_super(home_object)})
    |> Context.mark_dirty()
  end

  def current_atoms do
    case fast_ctx() do
      {atoms, _globals, _current_func, _arg_buf, _this, _new_target, _home_object, _super} ->
        atoms

      _ ->
        case Heap.get_ctx() do
          %{atoms: atoms} -> atoms
          _ -> Heap.get_atoms()
        end
    end
  end

  def current_globals do
    case fast_ctx() do
      {_atoms, globals, _current_func, _arg_buf, _this, _new_target, _home_object, _super} ->
        globals

      _ ->
        case Heap.get_ctx() do
          %{globals: globals} -> globals
          _ -> Runtime.global_bindings()
        end
    end
  end

  def current_func do
    case fast_ctx() do
      {_atoms, _globals, current_func, _arg_buf, _this, _new_target, _home_object, _super} ->
        current_func

      _ ->
        case Heap.get_ctx() do
          %{current_func: current_func} -> current_func
          _ -> :undefined
        end
    end
  end

  def current_arg_buf do
    case fast_ctx() do
      {_atoms, _globals, _current_func, arg_buf, _this, _new_target, _home_object, _super} ->
        arg_buf

      _ ->
        case Heap.get_ctx() do
          %{arg_buf: arg_buf} -> arg_buf
          _ -> {}
        end
    end
  end

  def current_this do
    case fast_ctx() do
      {_atoms, _globals, _current_func, _arg_buf, this, _new_target, _home_object, _super} ->
        this

      _ ->
        case Heap.get_ctx() do
          %{this: this} -> this
          _ -> :undefined
        end
    end
  end

  def current_new_target do
    case fast_ctx() do
      {_atoms, _globals, _current_func, _arg_buf, _this, new_target, _home_object, _super} ->
        new_target

      _ ->
        case Heap.get_ctx() do
          %{new_target: new_target} -> new_target
          _ -> :undefined
        end
    end
  end

  def current_home_object(current_func \\ current_func())

  def current_home_object(%Bytecode.Function{need_home_object: false}), do: :undefined

  def current_home_object({:closure, _, %Bytecode.Function{need_home_object: false}}),
    do: :undefined

  def current_home_object(current_func) do
    case fast_ctx() do
      {_atoms, _globals, _current_func, _arg_buf, _this, _new_target, home_object, _super} ->
        home_object

      _ ->
        Functions.current_home_object(current_func)
    end
  end

  def current_super(home_object \\ current_home_object())
  def current_super(:undefined), do: :undefined
  def current_super(nil), do: :undefined

  def current_super(home_object) do
    case fast_ctx() do
      {_atoms, _globals, _current_func, _arg_buf, _this, _new_target, cached_home_object, super}
      when cached_home_object == home_object ->
        super

      _ ->
        Class.get_super(home_object)
    end
  end

  def missing, do: @missing
end
