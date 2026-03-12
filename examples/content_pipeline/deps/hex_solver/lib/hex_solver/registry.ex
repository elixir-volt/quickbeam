defmodule HexSolver.Registry do
  @moduledoc """
  The registry is used by the solver to discover package versions and their dependencies.
  """

  @doc """
  Returns all versions of the given package sorted from lowest to highest or `:error` if the package
  does not exist.
  """
  @callback versions(HexSolver.repo(), HexSolver.package()) :: {:ok, [Version.t()]} | :error

  @doc """
  Returns all dependencies of the given package version or `:error` if the package or version
  does not exist.
  """
  @callback dependencies(HexSolver.repo(), HexSolver.package(), Version.t()) ::
              {:ok, [HexSolver.dependency()]} | :error

  @doc """
  Called when the solver first discovers a set of packages so that the registry can be lazily
  preloaded.
  """
  @callback prefetch([{HexSolver.repo(), HexSolver.package()}]) :: :ok
end
