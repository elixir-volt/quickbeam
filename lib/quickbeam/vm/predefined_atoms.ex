defmodule QuickBEAM.VM.PredefinedAtoms do
  @moduledoc "QuickJS predefined atom table, generated at compile time from quickjs-atom.h"

  @header_path Application.app_dir(:quickbeam, "priv/c_src/quickjs-atom.h")
  @external_resource @header_path

  @table @header_path
         |> File.stream!()
         |> Stream.filter(&match?("DEF(" <> _, &1))
         |> Stream.with_index(1)
         |> Map.new(fn {line, idx} ->
           {idx, line |> String.split("\"") |> Enum.at(1)}
         end)

  @doc "Looks up a predefined atom by index."
  def lookup(idx) when is_map_key(@table, idx), do: Map.fetch!(@table, idx)
  def lookup(_), do: nil

  @doc "Returns the number of predefined atoms."
  def count, do: map_size(@table)
end
