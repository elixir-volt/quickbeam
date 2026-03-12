defmodule NPMSemver.Version do
  @moduledoc """
  npm-compatible semver version parsing and comparison.
  """

  import NimbleParsec

  defstruct [:major, :minor, :patch, pre: [], build: []]

  @type t :: %__MODULE__{
          major: non_neg_integer(),
          minor: non_neg_integer(),
          patch: non_neg_integer(),
          pre: [String.t() | integer()],
          build: [String.t()]
        }

  identifier = ascii_string([?0..?9, ?a..?z, ?A..?Z, ?-], min: 1)

  pre_release =
    ignore(string("-"))
    |> concat(
      identifier
      |> repeat(ignore(string(".")) |> concat(identifier))
    )
    |> tag(:pre)

  build_metadata =
    ignore(string("+"))
    |> concat(
      identifier
      |> repeat(ignore(string(".")) |> concat(identifier))
    )
    |> tag(:build)

  version =
    integer(min: 1)
    |> ignore(string("."))
    |> integer(min: 1)
    |> ignore(string("."))
    |> integer(min: 1)
    |> optional(pre_release)
    |> optional(build_metadata)
    |> eos()

  defparsecp(:parse_version, version)

  @doc """
  Parse a version string.

  In loose mode, accepts `v`-prefixed versions and pre-release tags
  without the `-` separator (e.g., `1.2.3beta`).
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | :error
  def parse(string, opts \\ []) do
    string = String.trim(string)
    loose = Keyword.get(opts, :loose, false)

    string = if loose, do: String.trim_leading(string, "v"), else: string
    string = if loose, do: normalize_loose_pre(string), else: string

    case parse_version(string) do
      {:ok, parts, "", _, _, _} -> {:ok, build_version(parts)}
      _ -> :error
    end
  end

  defp normalize_loose_pre(string) do
    {core, rest} = split_at_build(string)

    core =
      case String.split(core, "-", parts: 2) do
        [_base, _pre] ->
          core

        [base] ->
          case Regex.run(~r/^(\d+\.\d+\.\d+)([a-zA-Z].*)$/, base) do
            [_, ver, pre] -> "#{ver}-#{pre}"
            nil -> base
          end
      end

    case rest do
      nil -> core
      build -> "#{core}+#{build}"
    end
  end

  defp split_at_build(string) do
    case String.split(string, "+", parts: 2) do
      [core, build] -> {core, build}
      [core] -> {core, nil}
    end
  end

  defp build_version(parts) do
    {ints, rest} = Enum.split_while(parts, &is_integer/1)
    [major, minor, patch] = ints

    {pre, rest} =
      case rest do
        [{:pre, pre_parts} | r] -> {Enum.map(pre_parts, &coerce_pre_part/1), r}
        _ -> {[], rest}
      end

    build =
      case rest do
        [{:build, build_parts}] -> build_parts
        _ -> []
      end

    %__MODULE__{major: major, minor: minor, patch: patch, pre: pre, build: build}
  end

  defp coerce_pre_part(part) when is_binary(part) do
    case Integer.parse(part) do
      {n, ""} -> n
      _ -> part
    end
  end

  @doc "Compare two versions. Returns `:lt`, `:eq`, or `:gt`."
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    case compare_core(a, b) do
      :eq ->
        case {a.pre, b.pre} do
          {[], []} -> :eq
          {[], _} -> :gt
          {_, []} -> :lt
          {pre_a, pre_b} -> compare_pre(pre_a, pre_b)
        end

      other ->
        other
    end
  end

  defp compare_core(a, b) do
    cond do
      a.major != b.major -> if a.major > b.major, do: :gt, else: :lt
      a.minor != b.minor -> if a.minor > b.minor, do: :gt, else: :lt
      a.patch != b.patch -> if a.patch > b.patch, do: :gt, else: :lt
      true -> :eq
    end
  end

  defp compare_pre([], []), do: :eq
  defp compare_pre([], _), do: :lt
  defp compare_pre(_, []), do: :gt

  defp compare_pre([a | rest_a], [b | rest_b]) do
    case compare_pre_part(a, b) do
      :eq -> compare_pre(rest_a, rest_b)
      other -> other
    end
  end

  defp compare_pre_part(a, b) when is_integer(a) and is_integer(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  defp compare_pre_part(a, b) when is_integer(a) and is_binary(b), do: :lt
  defp compare_pre_part(a, b) when is_binary(a) and is_integer(b), do: :gt

  defp compare_pre_part(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  @doc "Format a version struct back to a string."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = v) do
    core = "#{v.major}.#{v.minor}.#{v.patch}"

    core =
      case v.pre do
        [] -> core
        pre -> core <> "-" <> Enum.map_join(pre, ".", &Kernel.to_string/1)
      end

    case v.build do
      [] -> core
      build -> core <> "+" <> Enum.join(build, ".")
    end
  end

  defimpl String.Chars do
    def to_string(version), do: NPMSemver.Version.to_string(version)
  end
end
