defmodule QuickBEAM.VM.Compiler.Runner do
  @moduledoc false

  alias QuickBEAM.VM.{Bytecode, GlobalEnv, Heap}
  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.ObjectModel.{Class, Functions}

  def invoke(%Bytecode.Function{} = fun, args), do: invoke(fun, args, nil)
  def invoke({:closure, _, %Bytecode.Function{}} = closure, args), do: invoke(closure, args, nil)
  def invoke(_, _), do: :error

  def invoke(%Bytecode.Function{} = fun, args, base_ctx),
    do: invoke_target(fun, fun, args, %{}, base_ctx)

  def invoke({:closure, _, %Bytecode.Function{} = fun} = closure, args, base_ctx),
    do: invoke_target(closure, fun, args, %{}, base_ctx)

  def invoke(_, _, _), do: :error

  def invoke_with_receiver(%Bytecode.Function{} = fun, args, this_obj),
    do: invoke_with_receiver(fun, args, this_obj, nil)

  def invoke_with_receiver({:closure, _, %Bytecode.Function{}} = closure, args, this_obj),
    do: invoke_with_receiver(closure, args, this_obj, nil)

  def invoke_with_receiver(_, _, _), do: :error

  def invoke_with_receiver(%Bytecode.Function{} = fun, args, this_obj, base_ctx),
    do: invoke_target(fun, fun, args, %{this: this_obj}, base_ctx)

  def invoke_with_receiver(
        {:closure, _, %Bytecode.Function{} = fun} = closure,
        args,
        this_obj,
        base_ctx
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj}, base_ctx)

  def invoke_with_receiver(_, _, _, _), do: :error

  def invoke_constructor(%Bytecode.Function{} = fun, args, this_obj, new_target),
    do: invoke_constructor(fun, args, this_obj, new_target, nil)

  def invoke_constructor(
        {:closure, _, %Bytecode.Function{}} = closure,
        args,
        this_obj,
        new_target
      ),
      do: invoke_constructor(closure, args, this_obj, new_target, nil)

  def invoke_constructor(_, _, _, _), do: :error

  def invoke_constructor(%Bytecode.Function{} = fun, args, this_obj, new_target, base_ctx),
    do: invoke_target(fun, fun, args, %{this: this_obj, new_target: new_target}, base_ctx)

  def invoke_constructor(
        {:closure, _, %Bytecode.Function{} = fun} = closure,
        args,
        this_obj,
        new_target,
        base_ctx
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj, new_target: new_target}, base_ctx)

  def invoke_constructor(_, _, _, _, _), do: :error

  defp invoke_target(current_func, %Bytecode.Function{} = fun, args, ctx_overrides, base_ctx) do
    key = {fun.byte_code, fun.arg_count}
    args = normalize_args(args, fun.arg_count)

    case Heap.get_compiled(key) do
      {:compiled, {mod, name}, atoms} ->
        ctx = invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun, atoms)
        {:ok, apply_compiled({mod, name}, ctx, args)}

      :unsupported ->
        :error

      nil ->
        compile_and_invoke(fun, current_func, args, ctx_overrides, base_ctx, key)
    end
  end

  defp compile_and_invoke(fun, current_func, args, ctx_overrides, base_ctx, key) do
    case Compiler.compile(fun) do
      {:ok, compiled} ->
        atoms = Process.get({:qb_fn_atoms, fun.byte_code}, Heap.get_atoms())
        Heap.put_compiled(key, {:compiled, compiled, atoms})
        ctx = invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun, atoms)
        {:ok, apply_compiled(compiled, ctx, args)}

      {:error, _} ->
        Heap.put_compiled(key, :unsupported)
        :error
    end
  end

  defp apply_compiled({mod, name}, ctx, args), do: apply(mod, name, [ctx | args])

  defp invocation_ctx(base_ctx, current_func, args, %{} = ctx_overrides, fun, atoms)
       when map_size(ctx_overrides) == 0 do
    build_invocation_ctx(base_ctx(base_ctx), current_func, args, fun, atoms)
  end

  defp invocation_ctx(base_ctx, current_func, args, %{this: this_obj}, fun, atoms) do
    build_invocation_ctx(base_ctx(base_ctx), current_func, args, fun, atoms, this: this_obj)
  end

  defp invocation_ctx(
         base_ctx,
         current_func,
         args,
         %{this: this_obj, new_target: new_target},
         fun,
         atoms
       ) do
    build_invocation_ctx(base_ctx(base_ctx), current_func, args, fun, atoms,
      this: this_obj,
      new_target: new_target
    )
  end

  defp invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun, atoms) do
    ctx = build_invocation_ctx(base_ctx(base_ctx), current_func, args, fun, atoms)

    ctx
    |> struct(Map.take(ctx_overrides, [:this, :new_target]))
    |> Context.mark_dirty()
  end

  defp build_invocation_ctx(
         %Context{} = base_ctx,
         current_func,
         args,
         _fun,
         atoms,
         overrides \\ []
       ) do
    {home_object, super} = home_object_and_super(current_func)

    %Context{
      base_ctx
      | atoms: atoms || current_atoms(base_ctx),
        current_func: current_func,
        arg_buf: List.to_tuple(args),
        trace_enabled: trace_enabled(base_ctx),
        home_object: home_object,
        super: super,
        this: Keyword.get(overrides, :this, base_ctx.this),
        new_target: Keyword.get(overrides, :new_target, base_ctx.new_target)
    }
    |> Context.mark_dirty()
  end

  defp base_ctx(%Context{} = ctx), do: ensure_globals(ctx)

  defp base_ctx(nil) do
    %Context{atoms: Heap.get_atoms(), globals: base_globals(), trace_enabled: false}
  end

  defp base_ctx(map) when is_map(map) do
    map
    |> then(&struct(Context, Map.merge(Map.from_struct(%Context{}), &1)))
    |> ensure_globals()
  end

  defp ensure_globals(%Context{globals: globals} = ctx) when globals == %{},
    do: %{ctx | globals: base_globals()}

  defp ensure_globals(%Context{} = ctx), do: ctx

  defp base_globals, do: GlobalEnv.base_globals()

  defp current_atoms(%Context{} = ctx), do: ctx.atoms
  defp current_atoms(map) when is_map(map), do: Map.get(map, :atoms, Heap.get_atoms())
  defp current_atoms(_), do: Heap.get_atoms()

  defp trace_enabled(%Context{} = ctx), do: ctx.trace_enabled
  defp trace_enabled(map) when is_map(map), do: Map.get(map, :trace_enabled, false)
  defp trace_enabled(_), do: false

  defp home_object_and_super(%Bytecode.Function{need_home_object: false}),
    do: {:undefined, :undefined}

  defp home_object_and_super({:closure, _, %Bytecode.Function{need_home_object: false}}),
    do: {:undefined, :undefined}

  defp home_object_and_super(current_func) do
    home_object = Functions.current_home_object(current_func)
    {home_object, current_super(home_object)}
  end

  defp current_super(:undefined), do: :undefined
  defp current_super(nil), do: :undefined
  defp current_super(home_object), do: Class.get_super(home_object)

  defp normalize_args(_args, 0), do: []
  defp normalize_args([a0 | _], 1), do: [a0]
  defp normalize_args([], 1), do: [:undefined]
  defp normalize_args([a0, a1 | _], 2), do: [a0, a1]
  defp normalize_args([a0], 2), do: [a0, :undefined]
  defp normalize_args([], 2), do: [:undefined, :undefined]
  defp normalize_args([a0, a1, a2 | _], 3), do: [a0, a1, a2]
  defp normalize_args([a0, a1], 3), do: [a0, a1, :undefined]
  defp normalize_args([a0], 3), do: [a0, :undefined, :undefined]
  defp normalize_args([], 3), do: [:undefined, :undefined, :undefined]

  defp normalize_args(args, arg_count) do
    args
    |> Enum.take(arg_count)
    |> then(fn args -> args ++ List.duplicate(:undefined, arg_count - length(args)) end)
  end
end
