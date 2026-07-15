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

  alias QuickBEAM.VM.Compiler.{Contract, GeneratedModule, ModulePool}
  alias QuickBEAM.VM.Compiler.Lowering.PureV1
  alias QuickBEAM.VM.{Evaluator, Execution, Interpreter, Program}

  @type result :: {:ok, term()} | {:error, term()} | {:suspended, term()}

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
  def start(%Program{} = program, opts \\ []) when is_list(opts) do
    {frame, execution} = Interpreter.initialize(program, opts)
    pool = Keyword.get(opts, :compiler_pool, ModulePool)

    with :ok <- ensure_pool_available(pool),
         {:ok, template} <- PureV1.lower(program.root),
         {:ok, key} <- Contract.artifact_key(program, program.root, profile: :pure_v1),
         {:ok, lease} <- ModulePool.checkout(pool, key, template) do
      action =
        try do
          GeneratedModule.invoke(pool, lease, frame, execution)
        after
          safe_checkin(pool, lease)
        end

      resume_action(action, execution)
    else
      {:error, reason} -> {:error, {:compiler_error, reason}, execution}
    end
  end

  defp resume_action({:deopt, deopt}, _execution), do: Interpreter.resume_deopt_raw(deopt)

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
