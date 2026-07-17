defmodule QuickBEAM.VM.Compiler.Code.Import do
  @moduledoc """
  Enforces the generated-module external-call allowlist.

  Initial generated modules may call only the versioned compiler runtime ABI.
  Any new runtime helper or direct Erlang BIF must be added deliberately with
  differential and disassembly coverage.
  """

  alias QuickBEAM.VM.Compiler.Runtime

  @allowed [
    {:erlang, :*, 2},
    {:erlang, :+, 2},
    {:erlang, :-, 1},
    {:erlang, :-, 2},
    {:erlang, :<, 2},
    {:erlang, :"=<", 2},
    {:erlang, :==, 2},
    {:erlang, :>, 2},
    {:erlang, :>=, 2},
    {:erlang, :"/=", 2},
    {:erlang, :element, 2},
    {:erlang, :get_module_info, 1},
    {:erlang, :get_module_info, 2},
    {:erlang, :is_integer, 1},
    {:erlang, :is_number, 1},
    {:erlang, :rem, 2},
    {:erlang, :setelement, 3},
    {Runtime, :version, 0},
    {Runtime, :charge_block, 4},
    {Runtime, :charge_state, 4},
    {Runtime, :deopt, 4},
    {Runtime, :deopt_state, 4},
    {Runtime, :execute_plan, 4},
    {Runtime, :execute_fast_block, 4},
    {Runtime, :execute_stack, 4},
    {Runtime, :execute_local, 4},
    {Runtime, :execute_value, 4},
    {Runtime, :execute_branch, 4},
    {Runtime, :frame_constant, 2},
    {Runtime, :frame_pc, 1},
    {Runtime, :frame_state, 1},
    {Runtime, :frame_this, 1},
    {Runtime, :global_get, 3},
    {Runtime, :global_put, 3},
    {Runtime, :invoke_state, 5},
    {Runtime, :property_get, 3},
    {Runtime, :resolve_atom, 2},
    {Runtime, :truthy?, 1},
    {Runtime, :tuple_put, 3},
    {Runtime, :unary, 2},
    {Runtime, :binary, 3}
  ]
  @allowed_set MapSet.new(@allowed)

  @doc "Returns the closed initial external-call allowlist."
  @spec allowed() :: [{module(), atom(), non_neg_integer()}]
  def allowed, do: @allowed

  @doc "Returns the imports recorded in a generated module binary."
  @spec imports(binary()) :: {:ok, [tuple()]} | {:error, term()}
  def imports(binary) when is_binary(binary) do
    case :beam_lib.chunks(binary, [:imports]) do
      {:ok, {_module, [{:imports, imports}]}} when is_list(imports) ->
        {:ok, Enum.sort(imports)}

      {:error, _module, reason} ->
        {:error, {:invalid_generated_beam, reason}}

      other ->
        {:error, {:invalid_generated_beam_imports, other}}
    end
  end

  @doc "Rejects every generated external call outside the closed allowlist."
  @spec validate(binary()) :: :ok | {:error, term()}
  def validate(binary) do
    with {:ok, imports} <- imports(binary) do
      rejected = imports |> Enum.reject(&MapSet.member?(@allowed_set, &1)) |> Enum.sort()

      case rejected do
        [] -> :ok
        _calls -> {:error, {:disallowed_generated_calls, rejected}}
      end
    end
  end
end
