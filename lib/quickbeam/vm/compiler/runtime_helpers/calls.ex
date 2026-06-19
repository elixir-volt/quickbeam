defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Calls do
  @moduledoc "Call, construction, and direct-eval helpers for BEAM-compiled JavaScript."

  alias QuickBEAM.VM.{Heap, Invocation, Names, RuntimeState}
  alias QuickBEAM.VM.Compiler.Runner
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.{Bindings, Context, Errors}
  alias QuickBEAM.VM.Environment.Captures, as: EnvCaptures
  alias QuickBEAM.VM.Execution.ConstructorStack
  alias QuickBEAM.VM.Interpreter.Context, as: InterpreterContext
  alias QuickBEAM.VM.Semantics.{Construction, Eval}

  @doc "Constructs a JavaScript value from compiled code."
  def construct_runtime(ctx, ctor, new_target, args),
    do: Invocation.construct_runtime(ctx, ctor, new_target, args)

  def construct_runtime(ctx, ctor, new_target, args, call_pc) do
    ConstructorStack.with_stack(Errors.compiled_stack(ctx, call_pc), fn ->
      construct_runtime(ctx, ctor, new_target, args)
    end)
  end

  def construct_runtime(ctor, new_target, args),
    do: Invocation.construct_runtime(ctor, new_target, args)

  def check_ctor_return(ctx, value) do
    case Construction.check_ctor_return(value) do
      {:ok, replace_with_this?, checked_value} ->
        {replace_with_this?, checked_value}

      {:error, message} ->
        throw(
          {:js_throw,
           Errors.make_error_with_ctx(ctx, message, "TypeError", ConstructorStack.get())}
        )
    end
  end

  def init_ctor(ctx) do
    current_func = Context.current_func(ctx)

    raw =
      case current_func do
        {:closure, _, %QuickBEAM.VM.Function{} = fun} -> fun
        %QuickBEAM.VM.Function{} = fun -> fun
        other -> other
      end

    parent = Heap.get_parent_ctor(raw)
    args = Tuple.to_list(Context.arg_buf(ctx))

    already_bound_this? = match?({:obj, _}, Context.this(ctx))

    pending_this =
      case Context.this(ctx) do
        {:uninitialized, {:obj, _} = object} -> object
        {:obj, _} = object -> object
        other -> other
      end

    parent_ctx = InterpreterContext.mark_dirty(%{Context.ensure(ctx) | this: pending_this})

    result =
      case parent do
        nil ->
          pending_this

        %QuickBEAM.VM.Function{} = fun ->
          invoke_parent(
            {:closure, %{}, fun},
            args,
            pending_this,
            Context.new_target(ctx),
            parent_ctx,
            Context.gas(ctx)
          )

        {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
          invoke_parent(
            closure,
            args,
            pending_this,
            Context.new_target(ctx),
            parent_ctx,
            Context.gas(ctx)
          )

        {:builtin, _name, callback} when is_function(callback, 2) ->
          callback.(args, pending_this)

        _ ->
          pending_this
      end

    result =
      case result do
        {:obj, _} = object -> object
        _ -> pending_this
      end

    if already_bound_this? and parent != nil do
      throw({:js_throw, Heap.make_error("this is already initialized", "ReferenceError")})
    end

    RuntimeState.install(InterpreterContext.mark_dirty(%{parent_ctx | this: result}))
    result
  end

  @doc "Invokes a JavaScript callable from compiled code."
  def invoke_runtime(ctx, fun, args), do: Invocation.invoke_runtime(ctx, fun, args)
  def invoke_runtime(fun, args), do: Invocation.invoke_runtime(fun, args)

  def eval_or_call(ctx, fun, [code | _] = args) when is_binary(code) do
    if intrinsic_eval?(fun, ctx) do
      eval_source(ctx, code)
    else
      Invocation.invoke_runtime(ctx, fun, args)
    end
  end

  def eval_or_call(ctx, fun, args), do: Invocation.invoke_runtime(ctx, fun, args)

  def eval_or_call_scope(ctx, fun, [code | _] = args, locals, captures) when is_binary(code) do
    if intrinsic_eval?(fun, ctx) do
      scoped_globals = Map.merge(ctx.globals, local_globals(locals, captures))
      pre_globals = Heap.get_persistent_globals() || %{}
      result = eval_source(%{ctx | globals: scoped_globals}, code)
      sync_eval_locals(locals, captures, pre_globals)
      result
    else
      Invocation.invoke_runtime(ctx, fun, args)
    end
  end

  def eval_or_call_scope(ctx, fun, args, _locals, _captures), do: eval_or_call(ctx, fun, args)

  def invoke_method_runtime(ctx, fun, this_object, args),
    do: Invocation.invoke_method_runtime(ctx, fun, this_object, args)

  def invoke_method_runtime(fun, this_object, args),
    do: Invocation.invoke_method_runtime(fun, this_object, args)

  @doc "Invokes a tail-position JavaScript method from compiled code."
  def invoke_tail_method(ctx, fun, this_object, args),
    do: Invocation.invoke_method_runtime(ctx, fun, this_object, args)

  @doc "Applies a superclass constructor for `super(...)`."
  def apply_super(ctx, fun, new_target, args),
    do: Invocation.construct_runtime(ctx, fun, new_target, args)

  def apply_super(fun, new_target, args), do: Invocation.construct_runtime(fun, new_target, args)

  defp invoke_parent(parent, args, pending_this, new_target, parent_ctx, gas) do
    case Runner.invoke_constructor(parent, args, pending_this, new_target, parent_ctx) do
      {:ok, value} -> value
      :error -> Invocation.invoke_with_receiver(parent, args, gas, pending_this)
    end
  end

  defp intrinsic_eval?(fun, ctx) do
    fun == ctx.globals["eval"] or Eval.intrinsic_eval?(fun)
  end

  defp eval_source(ctx, code) do
    case Eval.simple_delete_identifier(code, Context.globals(ctx)) do
      {:ok, result} -> result
      :error -> compile_eval_source(ctx, code)
    end
  end

  defp compile_eval_source(ctx, code) do
    Eval.reject_class_field_initializer_eval!(ctx, code)
    eval_code = Eval.normalize_class_field_initializer_eval_code(ctx, code)

    case Eval.class_field_initializer_eval_ast(ctx, eval_code) do
      {:ok, {value, globals}} ->
        Eval.commit_class_field_initializer_eval_globals(Context.globals(ctx), globals)
        install_eval_globals(ctx, globals)
        value

      {:ok, :unsupported} ->
        compile_eval_source_program(ctx, eval_code)

      :continue ->
        compile_eval_source_program(ctx, eval_code)
    end
  end

  defp compile_eval_source_program(ctx, eval_code) do
    case compile_eval_program(ctx, strict_eval_code(ctx, eval_code)) do
      {:ok, program} ->
        run_eval_program(ctx, program)

      {:source_error, {:parse_error, errors}} ->
        throw({:js_throw, Heap.make_error(parse_error_message(errors), "SyntaxError")})

      {:source_error, message} ->
        throw({:js_throw, Heap.make_error(inspect(message), "SyntaxError")})
    end
  end

  defp install_eval_globals(ctx, globals) do
    case RuntimeState.current() do
      map when is_map(map) ->
        RuntimeState.install(%{map | globals: Map.merge(Context.globals(ctx), globals)})

      _ ->
        :ok
    end
  end

  defp strict_eval_code(ctx, code) do
    if Bindings.current_strict_mode?(ctx), do: "\"use strict\";\n" <> code, else: code
  end

  defp compile_eval_program(%{runtime_pid: runtime_pid}, code) when is_pid(runtime_pid),
    do: compile_native_eval_program(runtime_pid, code)

  defp compile_eval_program(%{runtime_pid: runtime_pid}, code)
       when is_atom(runtime_pid) and not is_nil(runtime_pid),
       do: compile_native_eval_program(runtime_pid, code)

  defp compile_eval_program(_ctx, code), do: compile_source_eval_program(code)

  defp compile_native_eval_program(runtime_pid, code) do
    case QuickBEAM.Runtime.compile(runtime_pid, code, "<eval>") do
      {:ok, bytecode} ->
        case QuickBEAM.VM.BytecodeParser.decode(bytecode) do
          {:ok, program} -> {:ok, program}
          {:error, _decode_reason} -> compile_source_eval_program(code)
        end

      {:error, %QuickBEAM.JS.Error{} = error} ->
        throw({:js_throw, error})

      {:error, reason} ->
        throw({:js_throw, Heap.make_error(inspect(reason), "SyntaxError")})
    end
  end

  defp compile_source_eval_program(code) do
    case QuickBEAM.JS.Compiler.compile(code) do
      {:ok, program} -> {:ok, program}
      {:error, reason} -> {:source_error, reason}
    end
  end

  defp run_eval_program(ctx, program) do
    reject_eval_lexical_conflicts!(ctx, program.value)

    arguments = Bindings.get_var(ctx, "arguments")
    globals = Map.put(ctx.globals, "arguments", arguments)

    case QuickBEAM.VM.Interpreter.eval(
           program.value,
           [],
           %{
             gas: ctx.gas,
             runtime_pid: ctx.runtime_pid,
             globals: globals,
             this: ctx.this,
             arg_buf: ctx.arg_buf,
             current_func: ctx.current_func,
             new_target: ctx.new_target
           },
           program.atoms
         ) do
      {:ok, value} -> value
      {:error, {:js_throw, value}} -> throw({:js_throw, value})
      _ -> :undefined
    end
  end

  defp reject_eval_lexical_conflicts!(ctx, %QuickBEAM.VM.Function{} = eval_fun) do
    unless Bindings.current_strict_mode?(ctx) do
      Eval.reject_lexical_conflicts!(ctx, Eval.declared_local_names(eval_fun), false)
    end
  end

  defp local_globals(locals, captures) do
    locals
    |> Enum.zip(captures)
    |> Map.new(fn {local, capture} ->
      {local_name(local), EnvCaptures.read(capture, :undefined)}
    end)
    |> Map.reject(fn {name, _value} -> is_nil(name) end)
  end

  defp sync_eval_locals(locals, captures, pre_globals) do
    post_globals = Heap.get_persistent_globals() || %{}

    local_names =
      locals
      |> Enum.map(&local_name/1)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    locals
    |> Enum.zip(captures)
    |> Enum.each(fn {local, capture} ->
      with name when is_binary(name) <- local_name(local),
           true <- Map.has_key?(post_globals, name),
           true <- Map.get(pre_globals, name, :__missing__) != Map.fetch!(post_globals, name) do
        EnvCaptures.sync(capture, Map.fetch!(post_globals, name))
      else
        _ -> :ok
      end
    end)

    restored_globals =
      Enum.reduce(local_names, post_globals, fn name, globals ->
        case Map.fetch(pre_globals, name) do
          {:ok, value} -> Map.put(globals, name, value)
          :error -> Map.delete(globals, name)
        end
      end)

    Heap.put_persistent_globals(restored_globals)
    restore_eval_global_object(locals, pre_globals, post_globals)
  end

  defp restore_eval_global_object(locals, pre_globals, post_globals) do
    local_names =
      locals
      |> Enum.map(&local_name/1)
      |> Enum.filter(&is_binary/1)

    case Map.get(pre_globals, "globalThis") do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) ->
            restored =
              Enum.reduce(local_names, map, fn name, acc ->
                if Map.has_key?(post_globals, name) do
                  case Map.fetch(pre_globals, name) do
                    {:ok, value} -> Map.put(acc, name, value)
                    :error -> Map.delete(acc, name)
                  end
                else
                  acc
                end
              end)

            Heap.put_obj(ref, restored)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp local_name(%{name: name}), do: Names.resolve_display_name(name)
  defp local_name(%{"name" => name}) when is_binary(name), do: name
  defp local_name(name) when is_binary(name), do: name
  defp local_name(_), do: nil

  defp parse_error_message([%{message: message} | _]), do: message
  defp parse_error_message(_errors), do: "Syntax error"
end
