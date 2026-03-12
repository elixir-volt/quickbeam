if Mix.env() == :dev do
  defmodule HexSolver.Dev do
    @moduledoc false

    def test_registry() do
      registry =
        Map.new(stream_registry(), fn {package, versions} ->
          versions =
            Map.new(versions, fn version ->
              dependencies =
                Map.new(version.dependencies, fn dep ->
                  {dep.package, Map.delete(dep, :package)}
                end)

              {version.version, dependencies}
            end)

          {package, versions}
        end)

      File.write!("test/fixtures/registry.json", Jason.encode!(registry, pretty: true))
    end

    def stream_registry() do
      {:ok, {200, _, names}} = :hex_repo.get_names(hex_config())

      Task.async_stream(
        names,
        fn %{name: package} ->
          {:ok, {200, _, registry}} = :hex_repo.get_package(hex_config(), package)
          {package, registry}
        end,
        ordered: false
      )
      |> Stream.map(fn {:ok, package} -> package end)
    end

    defp hex_config() do
      %{:hex_core.default_config() | http_adapter: {:hex_http_httpc, %{http_options: [ssl: []]}}}
    end
  end
end
