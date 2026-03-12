defmodule NPMSemver do
  @moduledoc """
  npm-compatible semantic versioning.

  Parses and matches version ranges using npm's semver syntax:
  `^1.2.3`, `~1.2.3`, `>=1.0.0 <2.0.0`, `1.x`, `1.0.0 - 2.0.0`, `||` unions.

  ## Examples

      iex> NPMSemver.matches?("1.2.3", "^1.0.0")
      true

      iex> NPMSemver.matches?("2.0.0", "^1.0.0")
      false

      iex> NPMSemver.matches?("1.5.0", ">=1.2.3 <2.0.0")
      true

      iex> NPMSemver.matches?("1.2.4", "~1.2.3")
      true

      iex> NPMSemver.matches?("2.1.3", "2.x.x")
      true

  Test fixtures ported from [node-semver](https://github.com/npm/node-semver).
  """

  alias NPMSemver.{Range, Version}

  @doc """
  Check if a version satisfies a range.

      iex> NPMSemver.matches?("1.8.1", "^1.2.3")
      true

      iex> NPMSemver.matches?("0.1.2", "^0.1")
      true
  """
  @spec matches?(String.t(), String.t(), keyword()) :: boolean()
  def matches?(version_string, range_string, opts \\ []) do
    with {:ok, version} <- Version.parse(version_string, opts),
         {:ok, range} <- Range.parse(range_string, opts) do
      Range.satisfies?(range, version, opts)
    else
      _ -> false
    end
  end

  @doc """
  Parse a version string into a `NPMSemver.Version` struct.

      iex> {:ok, v} = NPMSemver.parse_version("1.2.3-beta.1")
      iex> {v.major, v.minor, v.patch, v.pre}
      {1, 2, 3, ["beta", 1]}
  """
  @spec parse_version(String.t(), keyword()) :: {:ok, Version.t()} | :error
  def parse_version(string, opts \\ []) do
    Version.parse(string, opts)
  end

  @doc """
  Parse a range string into a `NPMSemver.Range` struct.

      iex> {:ok, _range} = NPMSemver.parse_range("^1.2.3")
  """
  @spec parse_range(String.t(), keyword()) :: {:ok, Range.t()} | :error
  def parse_range(string, opts \\ []) do
    Range.parse(string, opts)
  end

  @doc """
  Find the highest version in a list that satisfies the range.

      iex> NPMSemver.max_satisfying(["1.0.0", "1.5.0", "2.0.0"], "^1.0.0")
      "1.5.0"

      iex> NPMSemver.max_satisfying(["0.1.0", "0.2.0"], "^1.0.0")
      nil
  """
  @spec max_satisfying([String.t()], String.t(), keyword()) :: String.t() | nil
  def max_satisfying(versions, range_string, opts \\ []) do
    case Range.parse(range_string, opts) do
      {:ok, range} -> do_max_satisfying(versions, range, opts)
      _ -> nil
    end
  end

  defp do_max_satisfying(versions, range, opts) do
    versions
    |> Enum.filter(&version_satisfies?(&1, range, opts))
    |> Enum.sort(fn a, b ->
      {:ok, va} = Version.parse(a, opts)
      {:ok, vb} = Version.parse(b, opts)
      Version.compare(va, vb) == :gt
    end)
    |> List.first()
  end

  defp version_satisfies?(v, range, opts) do
    case Version.parse(v, opts) do
      {:ok, ver} -> Range.satisfies?(range, ver, opts)
      _ -> false
    end
  end

  @doc """
  Convert an npm range string to a `HexSolver` constraint.

  Returns an opaque constraint value that can be used with `HexSolver.run/4`
  and returned from `HexSolver.Registry` callbacks.

      iex> {:ok, _constraint} = NPMSemver.to_hex_constraint("^1.2.3")
  """
  @spec to_hex_constraint(String.t(), keyword()) :: {:ok, HexSolver.constraint()} | :error
  def to_hex_constraint(range_string, opts \\ []) do
    case to_elixir_requirement(range_string, opts) do
      {:ok, req_string} -> HexSolver.parse_constraint(req_string)
      :error -> :error
    end
  end

  @doc """
  Convert an npm range string to a `hex_solver`-compatible Elixir requirement string.

      iex> NPMSemver.to_elixir_requirement("^1.2.3")
      {:ok, ">= 1.2.3 and < 2.0.0-0"}

      iex> NPMSemver.to_elixir_requirement("~1.2.3")
      {:ok, ">= 1.2.3 and < 1.3.0-0"}

      iex> NPMSemver.to_elixir_requirement(">=1.0.0 <2.0.0 || >=3.0.0")
      {:ok, ">= 1.0.0 and < 2.0.0 or >= 3.0.0"}
  """
  @spec to_elixir_requirement(String.t(), keyword()) :: {:ok, String.t()} | :error
  def to_elixir_requirement(range_string, opts \\ []) do
    case Range.parse(range_string, opts) do
      {:ok, range} -> {:ok, Range.to_elixir_string(range)}
      :error -> :error
    end
  end
end
