defmodule Mix.Tasks.RustlerPrecompiled.Download do
  @shortdoc "Download precompiled NIFs and build the checksums"

  @moduledoc """
  A task responsible for downloading the precompiled NIFs for a given module.

  This task must only be used by package creators who want to ship the
  precompiled NIFs. The goal is to download the precompiled packages and
  generate a checksum to check-in alongside the project in the the Hex repository.
  This is done by passing the `--all` flag.

  You can also use the `--only-local` flag to download only the precompiled
  package for use during development.

  You can use the `--ignore-unavailable` flag to ignore any NIFs that are not available.
  This is useful when you are developing a new NIF that does not support all platforms.

  This task also accept the `--print` flag to print the checksums.

  Since v0.7.2 we configure the app invoking this mix task by default. This means that
  the app you are invoking this task from will be compiled and run the "release" configuration.
  We need to compile the app to make sure the module name is correct.
  To avoid that, use the `--no-config` flag.
  """

  use Mix.Task

  @switches [
    all: :boolean,
    only_local: :boolean,
    print: :boolean,
    no_config: :boolean,
    ignore_unavailable: :boolean
  ]

  @impl true
  def run([module_name | flags]) do
    module = String.to_atom("Elixir.#{module_name}")

    {options, _args, _invalid} = OptionParser.parse(flags, strict: @switches)

    unless options[:no_config] do
      Mix.Task.run("app.config", [])
    end

    case Code.ensure_compiled(module) do
      {:module, _module} ->
        :ok

      {:error, error} ->
        IO.puts(
          "Could not ensure that module is compiled. Be sure that the name is correct. Reason: #{inspect(error)}"
        )
    end

    nifs_with_urls =
      cond do
        options[:all] ->
          RustlerPrecompiled.available_nifs(module)

        options[:only_local] ->
          RustlerPrecompiled.current_target_nifs(module)

        true ->
          raise "you need to specify either \"--all\" or \"--only-local\" flags"
      end

    result = RustlerPrecompiled.download_nif_artifacts_with_checksums!(nifs_with_urls, options)

    if Keyword.get(options, :print, true) do
      result
      |> Enum.map(fn map ->
        {Path.basename(Map.fetch!(map, :path)), Map.fetch!(map, :checksum)}
      end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {file, checksum} -> "#{checksum}  #{file}" end)
      |> IO.puts()
    end

    RustlerPrecompiled.write_checksum!(module, result)
  end

  @impl true
  def run([]) do
    raise "the module name and a flag is expected. Use \"--all\" or \"--only-local\" flags"
  end
end
