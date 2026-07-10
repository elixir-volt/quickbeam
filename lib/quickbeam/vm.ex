defmodule QuickBEAM.VM do
  @moduledoc """
  Compile and validate QuickJS bytecode for execution by the BEAM engine.

  Programs are immutable and version-locked; each evaluation owns its frames,
  heap, Promise state, host operations, and resource limits.
  """

  alias QuickBEAM.VM.{ABI, Decoder, Evaluator, Function, Program, Verifier}

  @type program :: QuickBEAM.VM.Program.t()

  @max_bytecode_bytes 16 * 1024 * 1024
  @default_timeout 5_000

  @doc """
  Compiles JavaScript with the vendored QuickJS compiler and returns a verified
  immutable program.

  A bare temporary native runtime is used until the dedicated compiler pool is
  introduced. Use `decode/2` when bytecode has already been compiled.
  """
  @spec compile(String.t(), keyword()) :: {:ok, program()} | {:error, term()}
  def compile(source, opts \\ []) when is_binary(source) and is_list(opts) do
    {runtime_options, opts} = Keyword.pop(opts, :runtime_options, [])
    {filename, decode_options} = Keyword.pop(opts, :filename)
    runtime_options = Keyword.put(runtime_options, :apis, false)

    with :ok <- validate_filename(filename),
         {:ok, runtime} <- QuickBEAM.start(runtime_options) do
      try do
        with {:ok, bytecode} <- QuickBEAM.compile(runtime, source),
             {:ok, program} <- decode(bytecode, decode_options) do
          {:ok, maybe_put_filename(program, filename)}
        end
      after
        QuickBEAM.stop(runtime)
      end
    end
  end

  @doc "Decodes and verifies bytecode from this exact QuickJS build."
  @spec decode(binary(), keyword()) :: {:ok, program()} | {:error, term()}
  def decode(bytecode, opts \\ []) when is_binary(bytecode) and is_list(opts) do
    {max_bytecode_bytes, verifier_options} =
      Keyword.pop(opts, :max_bytecode_bytes, @max_bytecode_bytes)

    with :ok <- validate_max_bytecode_bytes(max_bytecode_bytes),
         :ok <- within_bytecode_limit(bytecode, max_bytecode_bytes),
         {:ok, program} <- Decoder.decode(bytecode),
         :ok <- Verifier.verify(program, verifier_options) do
      {:ok, program}
    end
  end

  defp validate_max_bytecode_bytes(limit)
       when is_integer(limit) and limit > 0 and limit <= @max_bytecode_bytes,
       do: :ok

  defp validate_max_bytecode_bytes(limit),
    do: {:error, {:invalid_option, :max_bytecode_bytes, limit}}

  defp within_bytecode_limit(bytecode, limit) when byte_size(bytecode) <= limit, do: :ok

  defp within_bytecode_limit(bytecode, _limit),
    do: {:error, {:limit_exceeded, :bytecode_bytes, byte_size(bytecode)}}

  defp validate_filename(nil), do: :ok
  defp validate_filename(filename) when is_binary(filename), do: :ok
  defp validate_filename(filename), do: {:error, {:invalid_option, :filename, filename}}

  defp maybe_put_filename(program, nil), do: program

  defp maybe_put_filename(program, filename) when is_binary(filename),
    do: update_filename(program, filename)

  defp update_filename(%Function{} = function, filename) do
    constants = Enum.map(function.constants, &update_filename(&1, filename))
    %{function | filename: filename, constants: constants}
  end

  defp update_filename(%{root: root} = program, filename),
    do: %{program | root: update_filename(root, filename)}

  defp update_filename(value, _filename), do: value

  @doc """
  Evaluates a verified program in an isolated BEAM process.

  Supported options include `:vars`, asynchronous `:handlers`, `:timeout`,
  `:max_steps`, and `:max_stack_depth`. `isolation: :caller` is available for
  trusted diagnostics.
  """
  @spec eval(Program.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def eval(%Program{} = program, opts \\ []) when is_list(opts) do
    with :ok <- Verifier.verify(program),
         {:ok, options} <- evaluation_options(opts) do
      case options.isolation do
        :caller -> Evaluator.eval(program, Map.to_list(options.interpreter))
        :process -> eval_isolated(program, options)
      end
    end
  end

  defp evaluation_options(opts) do
    allowed = [:handlers, :isolation, :max_stack_depth, :max_steps, :timeout, :vars]

    case Keyword.keys(opts) -- allowed do
      [] -> validate_evaluation_options(opts)
      [unknown | _] -> {:error, {:unknown_option, unknown}}
    end
  end

  defp validate_evaluation_options(opts) do
    isolation = Keyword.get(opts, :isolation, :process)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_steps = Keyword.get(opts, :max_steps, 5_000_000)
    max_stack_depth = Keyword.get(opts, :max_stack_depth, 1_000)
    vars = Keyword.get(opts, :vars, %{})
    handlers = Keyword.get(opts, :handlers, %{})

    cond do
      isolation not in [:caller, :process] ->
        {:error, {:invalid_option, :isolation, isolation}}

      timeout != :infinity and (not is_integer(timeout) or timeout <= 0) ->
        {:error, {:invalid_option, :timeout, timeout}}

      not is_integer(max_steps) or max_steps <= 0 ->
        {:error, {:invalid_option, :max_steps, max_steps}}

      not is_integer(max_stack_depth) or max_stack_depth <= 0 ->
        {:error, {:invalid_option, :max_stack_depth, max_stack_depth}}

      not is_map(vars) ->
        {:error, {:invalid_option, :vars, vars}}

      not is_map(handlers) or
          not Enum.all?(handlers, fn {name, handler} ->
            is_binary(name) and is_function(handler, 1)
          end) ->
        {:error, {:invalid_option, :handlers, handlers}}

      true ->
        {:ok,
         %{
           isolation: isolation,
           timeout: timeout,
           interpreter: %{
             handlers: handlers,
             max_steps: max_steps,
             max_stack_depth: max_stack_depth,
             vars: vars
           }
         }}
    end
  end

  defp eval_isolated(program, options) do
    caller = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_interpret(program, options.interpreter)
        send(caller, {reply_ref, result})
      end)

    await_evaluation(pid, monitor_ref, reply_ref, options.timeout)
  end

  defp safe_interpret(program, options) do
    case Evaluator.eval(program, Map.to_list(options)) do
      {:suspended, _continuation} -> {:error, {:unsupported, :async_wait}}
      result -> result
    end
  rescue
    exception -> {:error, {:interpreter_crash, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:interpreter_crash, {kind, reason}, __STACKTRACE__}}
  end

  defp await_evaluation(pid, monitor_ref, reply_ref, :infinity) do
    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:evaluation_process_exit, reason}}
    end
  end

  defp await_evaluation(pid, monitor_ref, reply_ref, timeout) do
    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:evaluation_process_exit, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)
        await_down(monitor_ref, pid)
        {:error, {:limit_exceeded, :timeout, timeout}}
    end
  end

  defp await_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  @doc "Returns the exact vendored QuickJS bytecode ABI fingerprint."
  defdelegate fingerprint(), to: ABI

  @doc "Returns the vendored QuickJS bytecode version."
  defdelegate bytecode_version(), to: ABI
end
