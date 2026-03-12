defmodule HexSolver.PackageRange do
  @moduledoc false

  alias HexSolver.PackageRange
  alias HexSolver.Constraints.Range

  defstruct repo: nil,
            name: nil,
            constraint: nil

  def to_string(%PackageRange{name: "$root"}), do: "your app"
  def to_string(%PackageRange{name: "$lock"}), do: "the lock"

  def to_string(%PackageRange{repo: nil, name: name, constraint: constraint}),
    do: "#{name}#{constraint(constraint)}"

  def to_string(%PackageRange{repo: repo, name: name, constraint: constraint}),
    do: "#{repo}/#{name}#{constraint(constraint)}"

  defp constraint(%Range{min: nil, max: nil}), do: ""
  defp constraint(constraint), do: " #{constraint}"

  defimpl String.Chars do
    defdelegate to_string(package_range), to: HexSolver.PackageRange
  end

  defimpl Inspect do
    def inspect(%{repo: nil, name: name, constraint: constraint}, _opts),
      do: "#PackageRange<#{name} #{constraint}>"

    def inspect(%{repo: repo, name: name, constraint: constraint}, _opts),
      do: "#PackageRange<#{repo}/#{name} #{constraint}>"
  end
end
