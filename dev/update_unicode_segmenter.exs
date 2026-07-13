Mix.install([{:npm, "~> 0.7.5"}])

version =
  case System.argv() do
    [version] -> version
    _ -> Mix.raise("usage: elixir dev/update_unicode_segmenter.exs VERSION")
  end

:ok = NPM.install(%{"unicode-segmenter" => version}, [])

package_dir = Path.join(NPM.node_modules_dir!(), "unicode-segmenter")
package = package_dir |> Path.join("package.json") |> File.read!() |> Jason.decode!()

unless package["version"] == version do
  Mix.raise("expected unicode-segmenter #{version}, resolved #{package["version"]}")
end

project_dir = Path.expand("..", __DIR__)
vendor_dir = Path.join(project_dir, "priv/vendor/unicode-segmenter")

for file <- ~w[core.js _grapheme_data.js grapheme.js intl-adapter.js LICENSE] do
  File.cp!(Path.join(package_dir, file), Path.join(vendor_dir, file))
end

wrapper_path = Path.join(vendor_dir, "quickbeam.js")
wrapper = File.read!(wrapper_path)
wrapper = Regex.replace(~r/unicode-segmenter \S+\./, wrapper, "unicode-segmenter #{version}.")
File.write!(wrapper_path, wrapper)

Mix.shell().info("Updated vendored unicode-segmenter to #{version}")
