defmodule QuickBEAM.VM.Compiler do
  @moduledoc """
  Supervises and orchestrates the optional bounded BEAM compiler tier.

  Add this module to a supervision tree before selecting `engine: :compiler`:

      children = [
        {QuickBEAM.VM.Compiler, capacity: 8}
      ]

  Compiler execution remains explicit. Unsupported instructions deopt into the
  interpreter; compilation, capacity, loading, and lease failures are returned
  as typed compiler errors and never invoke native QuickJS.
  """

  alias QuickBEAM.VM.Compiler.{Context, Contract, GeneratedModule, ModulePool}
  alias QuickBEAM.VM.Compiler.Lowering.PureV1
  alias QuickBEAM.VM.{Evaluator, Execution, Frame, Function, Interpreter, Program}

  @type result :: {:ok, term()} | {:error, term()} | {:suspended, term()}
  @type frame_action :: {:deopt, term()} | {:skip, struct(), struct()} | {:error, term()}

  @doc "Returns a child specification for the singleton generated-module pool."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: ModulePool,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Starts the singleton compiler pool with the production generated-module backend."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    opts =
      opts
      |> Keyword.put_new(:backend, GeneratedModule)
      |> Keyword.put_new(:task_supervisor, QuickBEAM.VM.TaskSupervisor)

    ModulePool.start_link(opts)
  end

  @doc "Evaluates a verified program through one compiled pure block and explicit deoptimization."
  @spec eval(Program.t(), keyword()) :: result()
  def eval(%Program{} = program, opts \\ []) when is_list(opts) do
    program
    |> start(opts)
    |> Evaluator.drive()
  end

  @doc "Evaluates through the compiler while collecting the standard deterministic counters."
  @spec eval_with_metrics(Program.t(), keyword()) :: {result(), map() | nil}
  def eval_with_metrics(%Program{} = program, opts \\ []) when is_list(opts) do
    reference = make_ref()
    result = eval(program, Keyword.put(opts, :measurement_target, {self(), reference}))

    receive do
      {:quickbeam_vm_measurement, ^reference, metrics} -> {result, metrics}
    after
      0 -> {result, nil}
    end
  end

  @doc "Starts compiled execution and returns a raw owner-local machine result."
  @spec start(Program.t(), keyword()) :: term()
  def start(%Program{root: %Function{}} = program, opts \\ []) when is_list(opts) do
    {frame, execution} = Interpreter.initialize(program, opts)
    pool = Keyword.get(opts, :compiler_pool, ModulePool)
    context = %Context{pool: pool, program: program}
    execution = %{execution | compiler_context: context}

    frame
    |> Map.put(:compiler_entered, true)
    |> execute_frame(execution)
    |> resume_action(execution)
  end

  @doc "Compiles and invokes one entry block for a canonical bytecode frame."
  @spec execute_frame(struct(), struct()) :: frame_action()
  def execute_frame(
        %Frame{function: %Function{id: function_id} = function} = frame,
        %Execution{compiler_context: %Context{pool: pool} = context} = execution
      ) do
    with :ok <- ensure_pool_available(pool) do
      case Map.fetch(context.decisions, function_id) do
        {:ok, :skip} ->
          {:skip, frame, execution}

        {:ok, {:compile, key, template}} ->
          invoke_frame(pool, key, template, frame, execution)

        :error ->
          prepare_frame(function, frame, execution)
      end
    end
  end

  defp prepare_frame(
         %Function{} = function,
         frame,
         %Execution{
           compiler_context: %Context{
             program: %Program{root: %Function{} = root} = program,
             min_nested_instructions: nested_minimum
           }
         } = execution
       ) do
    minimum = if function.id == root.id, do: 0, else: nested_minimum

    case PureV1.prepare(function, minimum) do
      {:ok, template, _count} ->
        with {:ok, key} <- Contract.artifact_key(program, function, profile: :pure_v1) do
          execution = cache_decision(execution, function.id, {:compile, key, template})
          invoke_frame(execution.compiler_context.pool, key, template, frame, execution)
        end

      {:skip, _count} ->
        {:skip, frame, cache_decision(execution, function.id, :skip)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invoke_frame(pool, key, template, frame, execution) do
    with {:ok, lease} <- ModulePool.checkout(pool, key, template) do
      try do
        GeneratedModule.invoke(pool, lease, frame, execution)
      after
        safe_checkin(pool, lease)
      end
    end
  end

  defp cache_decision(%Execution{compiler_context: context} = execution, function_id, decision) do
    if map_size(context.decisions) < context.max_decisions do
      context = %{context | decisions: Map.put(context.decisions, function_id, decision)}
      %{execution | compiler_context: context}
    else
      execution
    end
  end

  defp resume_action({:deopt, deopt}, _execution), do: Interpreter.resume_deopt_raw(deopt)

  defp resume_action({:skip, frame, execution}, _initial),
    do: Interpreter.run_frame(frame, execution)

  defp resume_action({status, _value, %Execution{}} = result, _execution)
       when status in [:ok, :error], do: result

  defp resume_action({:suspended, _continuation} = result, _execution), do: result

  defp resume_action({:error, reason}, execution),
    do: {:error, {:compiler_error, reason}, execution}

  defp resume_action(action, execution),
    do: {:error, {:compiler_error, {:invalid_generated_action, action}}, execution}

  defp ensure_pool_available(pool) when is_pid(pool) do
    if Process.alive?(pool), do: :ok, else: {:error, {:compiler_pool_unavailable, pool}}
  end

  defp ensure_pool_available(pool) when is_atom(pool) do
    if is_pid(Process.whereis(pool)), do: :ok, else: {:error, {:compiler_pool_unavailable, pool}}
  end

  defp ensure_pool_available(pool), do: {:error, {:compiler_pool_unavailable, pool}}

  defp safe_checkin(pool, lease) do
    ModulePool.checkin(pool, lease)
  catch
    :exit, _reason -> :ok
  end
end
