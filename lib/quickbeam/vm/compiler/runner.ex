defmodule QuickBEAM.VM.Compiler.Runner do
  @moduledoc "Compiled-function invocation: sets up call frames, handles `new`, generators, and tail-call dispatch."

  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Compiler.FunctionInfo
  alias QuickBEAM.VM.Compiler.GeneratorIterator
  alias QuickBEAM.VM.Execution.Trace
  alias QuickBEAM.VM.GlobalEnvironment
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.ObjectModel.{Class, Functions}
  alias QuickBEAM.VM.Promise
  alias QuickBEAM.VM.Value

  @doc "Invokes the runtime object represented by this module."
  def invoke(%QuickBEAM.VM.Function{} = fun, args), do: invoke(fun, args, nil)

  def invoke({:closure, _, %QuickBEAM.VM.Function{}} = closure, args),
    do: invoke(closure, args, nil)

  def invoke(_, _), do: :error

  def invoke(%QuickBEAM.VM.Function{} = fun, args, base_ctx),
    do: invoke_target(fun, fun, args, %{}, base_ctx)

  def invoke({:closure, _, %QuickBEAM.VM.Function{} = fun} = closure, args, base_ctx),
    do: invoke_target(closure, fun, args, %{}, base_ctx)

  def invoke(_, _, _), do: :error

  @doc "Helper for compiled-function invocation: sets up call frames, handles `new`, generators, and tail-call dispatch."
  def invoke_with_receiver(%QuickBEAM.VM.Function{} = fun, args, this_obj),
    do: invoke_with_receiver(fun, args, this_obj, nil)

  def invoke_with_receiver({:closure, _, %QuickBEAM.VM.Function{}} = closure, args, this_obj),
    do: invoke_with_receiver(closure, args, this_obj, nil)

  def invoke_with_receiver(_, _, _), do: :error

  def invoke_with_receiver(%QuickBEAM.VM.Function{} = fun, args, this_obj, base_ctx),
    do: invoke_target(fun, fun, args, %{this: this_obj}, base_ctx)

  def invoke_with_receiver(
        {:closure, _, %QuickBEAM.VM.Function{} = fun} = closure,
        args,
        this_obj,
        base_ctx
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj}, base_ctx)

  def invoke_with_receiver(_, _, _, _), do: :error

  @doc "Helper for compiled-function invocation: sets up call frames, handles `new`, generators, and tail-call dispatch."
  def invoke_constructor(%QuickBEAM.VM.Function{} = fun, args, this_obj, new_target),
    do: invoke_constructor(fun, args, this_obj, new_target, nil)

  def invoke_constructor(
        {:closure, _, %QuickBEAM.VM.Function{}} = closure,
        args,
        this_obj,
        new_target
      ),
      do: invoke_constructor(closure, args, this_obj, new_target, nil)

  def invoke_constructor(_, _, _, _), do: :error

  def invoke_constructor(%QuickBEAM.VM.Function{} = fun, args, this_obj, new_target, base_ctx),
    do: invoke_target(fun, fun, args, %{this: this_obj, new_target: new_target}, base_ctx)

  def invoke_constructor(
        {:closure, _, %QuickBEAM.VM.Function{} = fun} = closure,
        args,
        this_obj,
        new_target,
        base_ctx
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj, new_target: new_target}, base_ctx)

  def invoke_constructor(_, _, _, _, _), do: :error

  defp invoke_target(current_func, %QuickBEAM.VM.Function{} = fun, args, ctx_overrides, base_ctx) do
    atoms = Heap.get_fn_atoms(fun, Heap.get_atoms())
    key = {function_code_key(fun), fun.arg_count, :erlang.phash2(fun), :erlang.phash2(atoms)}
    normalized_args = normalize_args(args, fun.arg_count)

    case Heap.get_compiled(key) do
      {:compiled, {mod, name}, _cached_atoms} ->
        ctx = invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun, atoms)
        {:ok, invoke_compiled(fun, {mod, name}, ctx, normalized_args)}

      :unsupported ->
        :error

      nil ->
        compile_and_invoke(
          fun,
          current_func,
          args,
          normalized_args,
          ctx_overrides,
          base_ctx,
          key,
          atoms
        )
    end
  end

  defp compile_and_invoke(
         fun,
         current_func,
         args,
         normalized_args,
         ctx_overrides,
         base_ctx,
         key,
         atoms
       ) do
    case Compiler.compile(fun) do
      {:ok, compiled} ->
        Heap.put_compiled(key, {:compiled, compiled, atoms})
        ctx = invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun, atoms)
        {:ok, invoke_compiled(fun, compiled, ctx, normalized_args)}

      {:error, reason}
      when reason in [:generator_cleanup_resume, :mapped_arguments, :compiler_resource_limit] ->
        ctx = invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun, atoms)
        {:ok, interpreter_fallback(current_func, args, ctx)}

      {:error, _} ->
        Heap.put_compiled(key, :unsupported)
        :error
    end
  end

  defp interpreter_fallback({:closure, _, %QuickBEAM.VM.Function{}} = closure, args, ctx),
    do: Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)

  defp interpreter_fallback(%QuickBEAM.VM.Function{} = fun, args, ctx),
    do: Interpreter.invoke_function_fallback(fun, args, ctx.gas, ctx)

  defp invoke_compiled(%QuickBEAM.VM.Function{func_kind: 1} = fun, _compiled, ctx, args) do
    interpreter_fallback(fun, args, ctx)
  end

  defp invoke_compiled(%QuickBEAM.VM.Function{func_kind: 2}, compiled, ctx, args) do
    compiled_async_invoke(compiled, ctx, args)
  end

  defp invoke_compiled(%QuickBEAM.VM.Function{func_kind: 3} = fun, compiled, ctx, args) do
    compiled_async_gen_invoke(compiled, ctx, args, fun)
  end

  defp invoke_compiled(fun, compiled, ctx, args) do
    Trace.push(fun)

    try do
      apply_compiled(compiled, ctx, args)
    catch
      {:generator_yield, _val, continuation} when is_function(continuation, 1) ->
        build_suspended_generator(continuation)

      {:generator_yield_star, _val, continuation} when is_function(continuation, 1) ->
        build_suspended_generator(continuation)
    after
      Trace.pop()
    end
  end

  defp build_suspended_generator(continuation) do
    gen_ref = make_ref()
    Heap.put_obj(gen_ref, %{state: :suspended, continuation: continuation})
    GeneratorIterator.build(gen_ref)
  end

  defp compiled_async_invoke(compiled, ctx, args) do
    Promise.adopt(apply_compiled(compiled, ctx, args))
  catch
    {:generator_return, val} -> Promise.adopt(val)
    {:js_throw, error} -> Promise.rejected(error)
  end

  defp compiled_async_gen_invoke(compiled, ctx, args, generator_fun) do
    gen_ref = make_ref()

    try do
      apply_compiled(compiled, ctx, args)
    catch
      {:generator_yield, _val, continuation} ->
        Heap.put_obj(gen_ref, %{state: :suspended, continuation: continuation, mode: :initial})
    end

    GeneratorIterator.build_async(gen_ref, generator_fun)
  end

  defp apply_compiled({mod, name}, ctx, args), do: apply(mod, name, [ctx | args])

  defp invocation_ctx(base_ctx, current_func, args, %{} = ctx_overrides, fun, atoms)
       when map_size(ctx_overrides) == 0 do
    build_invocation_ctx(base_ctx(base_ctx), current_func, args, fun, atoms)
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

  defp build_invocation_ctx(%Context{} = base_ctx, current_func, args, fun, atoms),
    do: build_invocation_ctx(base_ctx, current_func, args, fun, atoms, [])

  defp build_invocation_ctx(%Context{} = base_ctx, current_func, args, _fun, atoms, []) do
    {home_object, super} = home_object_and_super(current_func)

    %Context{
      base_ctx
      | atoms: atoms || current_atoms(base_ctx),
        current_func: current_func,
        arg_buf: List.to_tuple(args),
        globals:
          Map.put(
            base_ctx.globals,
            "arguments",
            Heap.wrap_arguments(args,
              strict: strict_function?(current_func),
              callee: current_func
            )
          ),
        trace_enabled: trace_enabled(base_ctx),
        home_object: home_object,
        super: super
    }
    |> Context.mark_dirty()
  end

  defp build_invocation_ctx(
         %Context{} = base_ctx,
         current_func,
         args,
         _fun,
         atoms,
         this: this_obj
       ) do
    {home_object, super} = home_object_and_super(current_func)

    %Context{
      base_ctx
      | atoms: atoms || current_atoms(base_ctx),
        current_func: current_func,
        arg_buf: List.to_tuple(args),
        globals:
          Map.put(
            base_ctx.globals,
            "arguments",
            Heap.wrap_arguments(args,
              strict: strict_function?(current_func),
              callee: current_func
            )
          ),
        trace_enabled: trace_enabled(base_ctx),
        home_object: home_object,
        super: super,
        this: this_obj
    }
    |> Context.mark_dirty()
  end

  defp build_invocation_ctx(
         %Context{} = base_ctx,
         current_func,
         args,
         _fun,
         atoms,
         this: this_obj,
         new_target: new_target
       ) do
    {home_object, super} = home_object_and_super(current_func)

    %Context{
      base_ctx
      | atoms: atoms || current_atoms(base_ctx),
        current_func: current_func,
        arg_buf: List.to_tuple(args),
        globals:
          Map.put(
            base_ctx.globals,
            "arguments",
            Heap.wrap_arguments(args,
              strict: strict_function?(current_func),
              callee: current_func
            )
          ),
        trace_enabled: trace_enabled(base_ctx),
        home_object: home_object,
        super: super,
        this: this_obj,
        new_target: new_target
    }
    |> Context.mark_dirty()
  end

  defp build_invocation_ctx(%Context{} = base_ctx, current_func, args, fun, atoms, overrides) do
    {home_object, super} = home_object_and_super(current_func)

    %Context{
      base_ctx
      | atoms: atoms || current_atoms(base_ctx),
        current_func: current_func,
        arg_buf: List.to_tuple(args),
        globals:
          Map.put(
            base_ctx.globals,
            "arguments",
            Heap.wrap_arguments(args,
              strict: strict_function?(current_func),
              callee: current_func
            )
          ),
        trace_enabled: trace_enabled(base_ctx),
        home_object: home_object,
        super: super,
        this: invocation_this(overrides, base_ctx, fun),
        new_target: Keyword.get(overrides, :new_target, base_ctx.new_target)
    }
    |> Context.mark_dirty()
  end

  defp strict_function?(fun), do: Value.strict_function?(fun)

  defp invocation_this(overrides, _base_ctx, %QuickBEAM.VM.Function{is_strict_mode: true}) do
    if Keyword.has_key?(overrides, :this), do: Keyword.fetch!(overrides, :this), else: :undefined
  end

  defp invocation_this(overrides, base_ctx, _fun),
    do: Keyword.get(overrides, :this, base_ctx.this)

  defp base_ctx(%Context{} = ctx), do: ensure_globals(ctx)

  defp base_ctx(nil) do
    globals = base_globals()

    %Context{
      atoms: Heap.get_atoms(),
      globals: globals,
      this: Map.get(globals, "globalThis", :undefined),
      trace_enabled: false
    }
  end

  defp base_ctx(map) when is_map(map) do
    map
    |> then(&struct(Context, Map.merge(Map.from_struct(%Context{}), &1)))
    |> ensure_globals()
  end

  defp ensure_globals(%Context{globals: globals} = ctx) when globals == %{},
    do: %{ctx | globals: base_globals()}

  defp ensure_globals(%Context{} = ctx), do: ctx

  defp base_globals, do: GlobalEnvironment.base_globals()

  defp current_atoms(%Context{} = ctx), do: ctx.atoms

  defp trace_enabled(%Context{} = ctx), do: ctx.trace_enabled

  defp home_object_and_super(%QuickBEAM.VM.Function{need_home_object: false}),
    do: {:undefined, :undefined}

  defp home_object_and_super({:closure, _, %QuickBEAM.VM.Function{need_home_object: false}}),
    do: {:undefined, :undefined}

  defp home_object_and_super(current_func) do
    home_object = Functions.current_home_object(current_func)
    {home_object, current_super(home_object)}
  end

  defp current_super(:undefined), do: :undefined
  defp current_super(nil), do: :undefined
  defp current_super(home_object), do: Class.get_super(home_object)

  defp function_code_key(fun), do: FunctionInfo.code_key(fun)

  @doc "Normalizes call arguments to the arity expected by compiled code."
  def normalize_args(_args, 0), do: []
  def normalize_args([a0 | _], 1), do: [a0]
  def normalize_args([], 1), do: [:undefined]
  def normalize_args([a0, a1 | _], 2), do: [a0, a1]
  def normalize_args([a0], 2), do: [a0, :undefined]
  def normalize_args([], 2), do: [:undefined, :undefined]
  def normalize_args([a0, a1, a2 | _], 3), do: [a0, a1, a2]
  def normalize_args([a0, a1], 3), do: [a0, a1, :undefined]
  def normalize_args([a0], 3), do: [a0, :undefined, :undefined]
  def normalize_args([], 3), do: [:undefined, :undefined, :undefined]

  def normalize_args([a0, a1, a2, a3 | _], 4), do: [a0, a1, a2, a3]
  def normalize_args([a0, a1, a2], 4), do: [a0, a1, a2, :undefined]
  def normalize_args([a0, a1], 4), do: [a0, a1, :undefined, :undefined]
  def normalize_args([a0], 4), do: [a0, :undefined, :undefined, :undefined]
  def normalize_args([], 4), do: [:undefined, :undefined, :undefined, :undefined]
  def normalize_args([a0, a1, a2, a3, a4 | _], 5), do: [a0, a1, a2, a3, a4]
  def normalize_args([a0, a1, a2, a3], 5), do: [a0, a1, a2, a3, :undefined]
  def normalize_args([a0, a1, a2], 5), do: [a0, a1, a2, :undefined, :undefined]
  def normalize_args([a0, a1], 5), do: [a0, a1, :undefined, :undefined, :undefined]
  def normalize_args([a0], 5), do: [a0, :undefined, :undefined, :undefined, :undefined]
  def normalize_args([], 5), do: [:undefined, :undefined, :undefined, :undefined, :undefined]

  def normalize_args(args, arg_count) do
    args
    |> Enum.take(arg_count)
    |> then(fn args -> args ++ List.duplicate(:undefined, arg_count - length(args)) end)
  end
end
