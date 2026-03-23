defmodule QuickBEAM.Script do
  @moduledoc false

  alias QuickBEAM.JS.Bundler

  def read(path) do
    case File.read(path) do
      {:ok, source} ->
        cond do
          has_imports?(source, path) ->
            Bundler.bundle_file(path)

          typescript?(path) ->
            OXC.transform(source, Path.basename(path))

          true ->
            {:ok, source}
        end

      {:error, _} = error ->
        error
    end
  end

  defp typescript?(path), do: String.ends_with?(path, ".ts") or String.ends_with?(path, ".tsx")

  defp has_imports?(source, path) do
    case OXC.imports(source, Path.basename(path)) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end
end
