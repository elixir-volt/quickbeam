defmodule QuickBEAM.JS do
  @moduledoc false

  @ts_dir Path.join([__DIR__, "../../priv/ts"]) |> Path.expand()

  for ts <- Path.wildcard(Path.join(@ts_dir, "*.ts")),
      not String.ends_with?(ts, ".d.ts") do
    @external_resource ts
  end

  defmodule Compiler do
    @moduledoc false

    def standalone(ts_dir, names) do
      for name <- names do
        path = Path.join(ts_dir, "#{name}.ts")
        source = File.read!(path)

        OXC.transform!(source, Path.basename(path))
        |> then(&"(() => {\n#{&1}\n})();\n")
      end
    end

    def bundle(ts_dir, barrel) do
      barrel_source = File.read!(Path.join(ts_dir, barrel))
      {:ok, specifiers} = OXC.imports(barrel_source, barrel)

      import_names =
        specifiers
        |> Enum.filter(&String.starts_with?(&1, "./"))
        |> Enum.map(&String.trim_leading(&1, "./"))

      all_names = Enum.uniq([Path.rootname(barrel) | import_names])

      files =
        for name <- all_names do
          path = Path.join(ts_dir, "#{name}.ts")
          {"#{name}.ts", File.read!(path)}
        end

      OXC.bundle!(files)
    end
  end

  @browser_js Compiler.standalone(
                @ts_dir,
                ~w[url crypto-subtle compression buffer process class-list style]
              ) ++
                [Compiler.bundle(@ts_dir, "web-apis.ts")] ++
                Compiler.standalone(@ts_dir, ~w[dom-events performance])

  @beam_js Compiler.standalone(@ts_dir, ~w[beam-api])

  @node_js Compiler.standalone(
             @ts_dir,
             ~w[node-process node-path node-fs node-os node-child-process]
           )

  def browser_js, do: @browser_js
  def beam_js, do: @beam_js
  def node_js, do: @node_js
end
