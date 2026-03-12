defmodule RustlerPrecompiled do
  @moduledoc """
  Download and use precompiled NIFs safely with checksums.

  Rustler Precompiled is a tool for library maintainers that rely on Rustler.
  It helps by removing the need to have the Rust compiler installed in the
  user's machine.

  Check the [Precompilation Guide](PRECOMPILATION_GUIDE.md) for details.

  ## Example

      defmodule MyApp.MyNative do
        use RustlerPrecompiled,
          otp_app: :my_app,
          crate: "my_app_nif",
          base_url: "https://github.com/me/my_project/releases/download/v0.1.0",
          version: "0.1.0"
      end

  ## Options

    * `:otp_app` - The OTP app name that the dynamic library will be loaded from.

    * `:crate` - The name of Rust crate if different from the `:otp_app`. This is optional.

    * `:base_url` - Location where to find the NIFs from. This should be one of the following:

      * A URL to a directory containing the NIFs. The name of the NIF will be appended to it
        and a GET request will be made. Works well with public GitHub releases.

      * A tuple of `{URL, headers}`. The headers should be a list of key-value pairs.
        This is useful when the NIFs are hosted in a private server.

      * A tuple of `{module, function}` where the `function` is an atom representing the function
        name in that module. It's expected a function of arity 1, where the NIF file name is given,
        and it should return a URL or a tuple of `{URL, headers}`.
        This should be used for all cases not covered by the above.
        For example when multiple requests have to be made, like when using a private GitHub release
        through the GitHub API, or when the URLs don't resemble a simple directory.

    * `:version` - The version of precompiled assets (it is part of the NIF filename).

    * `:force_build` - Force the build with `Rustler`. This is `false` by default, but
      if your `:version` is a pre-release (like "2.1.0-dev"), this option will always
      be set `true`.
      You can also configure this option by setting an application env like this:

          config :rustler_precompiled, :force_build, your_otp_app: true

      It is important to add the ":rustler" package to your dependencies in order to force
      the build. To do that, just add it to your `mix.exs` file:

          {:rustler, ">= 0.0.0", optional: true}

      In case you want to force the build for all packages using RustlerPrecompiled, you
      can set the application config `:force_build_all`, or the env var
      `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL` (see details below):

          config :rustler_precompiled, force_build_all: true

    * `:targets` - A list of targets [supported by
      Rust](https://doc.rust-lang.org/rustc/platform-support.html) for which
      precompiled assets are available. By default the following targets are
      configured:

    #{Enum.map_join(RustlerPrecompiled.Config.default_targets(), "\n", &"    - `#{&1}`")}

    * `:nif_versions` - A list of OTP NIF versions for which precompiled assets are
      available. A NIF version is usually compatible with two OTP minor versions, and an older
      NIF is usually compatible with newer OTPs. The available versions are the following:

      * `2.14` - for OTP 21 and above.
      * `2.15` - for OTP 22 and above.
      * `2.16` - for OTP 24 and above.
      * `2.17` - for OTP 26 and above.

      By default the following NIF versions are configured:

    #{Enum.map_join(RustlerPrecompiled.Config.default_nif_versions(), "\n", &"    - `#{&1}`")}

      Check the compatibiliy table between Elixir and OTP in:
      https://hexdocs.pm/elixir/compatibility-and-deprecations.html#compatibility-between-elixir-and-erlang-otp

    * `:max_retries` - The maximum of retries before giving up. Defaults to `3`.
      Retries can be disabled with `0`.

    * `:variants` - A map with alternative versions of a given target. This is useful to
      support specific versions of dependencies, such as an old glibc version, or to support
      restrict CPU features, like AVX on x86_64.

      The order of variants matters, because the first one that returns `true` is going to be
      selected. Example:

          %{"x86_64-unknown-linux-gnu" => [old_glibc: fn _config -> has_old_glibc?() end]}

  In case "force build" is used, all options except the ones use by RustlerPrecompiled
  are going to be passed down to `Rustler`.
  So if you need to configure the build, check the `Rustler` options.

  ## Environment variables

  This project reads some system environment variables. They are all optional, but they
  can change the behaviour of this library at **compile time** of your project.

  They are:

    * `HTTP_PROXY` or `http_proxy` - Sets the HTTP proxy configuration.

    * `HTTPS_PROXY` or `https_proxy` - Sets the HTTPS proxy configuration.

    * `HEX_CACERTS_PATH` - Sets the path for a custom CA certificates file.
      If unset, defaults to `CAStore.file_path/0`.

    * `MIX_XDG` - If present, sets the OS as `:linux` for the `:filename.basedir/3` when getting
      an user cache dir.

    * `TARGET_ARCH` - The CPU target architecture. This is useful for when building your Nerves
      project, where your host CPU is different from your target CPU.

      Note that Nerves sets this value automatically when building your project.

      Examples: `arm`, `aarch64`, `x86_64`, `riscv64`.

    * `TARGET_ABI` - The target ABI (e.g., `gnueabihf`, `musl`). This is set by Nerves as well.

    * `TARGET_VENDOR` - The target vendor (e.g., `unknown`, `apple`, `pc`). This is **not** set by Nerves.
      If any of the `TARGET_` env vars is set, but `TARGET_VENDOR` is empty, then we change the
      target vendor to `unknown` that is the default value for Linux systems.

    * `TARGET_OS` - The target operational system. This is always `linux` for Nerves.

    * `RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH` - The global cache path directory. If set, it will ignore
      the default cache path resolution, thus ignoring `MIX_XDG`, and will try to fetch the artifacts
      from that path. In case the desired artifact is not found, a download is going to start.

      This variable is important for systems that cannot perform a download at compile time, like inside
      NixOS. It will require people to previously download the artifacts to that path.

    * `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL` - If set to "1" or "true", it will override the `:force_build`
      configuration for all packages, and will force the build for them all.
      You can set the `:force_build_all` configuration to `true` to have the same effect.

  Note that all packages using `RustlerPrecompiled` will be affected by these environment variables.

  For more details about Nerves env vars, see https://hexdocs.pm/nerves/environment-variables.html

  """
  defmacro __using__(opts) do
    force =
      if Code.ensure_loaded?(Rustler) do
        quote do
          use Rustler, only_rustler_opts
        end
      else
        quote do
          raise "Rustler dependency is needed to force the build. " <>
                  "Add it to your `mix.exs` file: `{:rustler, \">= 0.0.0\", optional: true}`"
        end
      end

    quote do
      require Logger

      opts = unquote(opts)

      otp_app = Keyword.fetch!(opts, :otp_app)

      opts =
        if Application.compile_env(
             :rustler_precompiled,
             :force_build_all,
             System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL") in ["1", "true"]
           ) do
          Keyword.put(opts, :force_build, true)
        else
          Keyword.put_new(
            opts,
            :force_build,
            Application.compile_env(:rustler_precompiled, [:force_build, otp_app])
          )
        end

      case RustlerPrecompiled.__using__(__MODULE__, opts) do
        {:force_build, only_rustler_opts} ->
          unquote(force)

        {:ok, config} ->
          @on_load :load_rustler_precompiled
          @rustler_precompiled_load_from config.load_from
          @rustler_precompiled_load_data config.load_data

          @doc false
          def load_rustler_precompiled do
            # Remove any old modules that may be loaded so we don't get
            # {:error, {:upgrade, 'Upgrade not supported by this NIF library.'}}
            :code.purge(__MODULE__)
            {otp_app, path} = @rustler_precompiled_load_from

            load_path =
              otp_app
              |> Application.app_dir(path)
              |> to_charlist()

            :erlang.load_nif(load_path, @rustler_precompiled_load_data)
          end

        {:error, precomp_error} ->
          raise precomp_error
      end
    end
  end

  # A helper function to extract the logic from __using__ macro.
  @doc false
  def __using__(module, opts) do
    config =
      opts
      |> Keyword.put_new(:module, module)
      |> RustlerPrecompiled.Config.new()

    case build_metadata(config) do
      {:ok, metadata} ->
        # We need to write metadata in order to run Mix tasks.
        with {:error, error} <- write_metadata(module, metadata) do
          require Logger

          Logger.warning(
            "Cannot write metadata file for module #{inspect(module)}. Reason: #{inspect(error)}. " <>
              "This is only an issue if you need to use the rustler_precompiled mix tasks for publishing a package."
          )
        end

        if config.force_build? do
          rustler_opts =
            Keyword.drop(opts, [
              :base_url,
              :version,
              :force_build,
              :targets,
              :nif_versions,
              :max_retries,
              :variants
            ])

          {:force_build, rustler_opts}
        else
          with {:error, precomp_error} <-
                 RustlerPrecompiled.download_or_reuse_nif_file(config, metadata) do
            message = """
            Error while downloading precompiled NIF: #{precomp_error}.

            You can force the project to build from scratch with:

                config :rustler_precompiled, :force_build, #{config.otp_app}: true

            In order to force the build, you also need to add Rustler as a dependency in your `mix.exs`:

                {:rustler, ">= 0.0.0", optional: true}
            """

            {:error, message}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  ## Implementation below

  alias RustlerPrecompiled.Config
  require Logger

  @checksum_algo :sha256
  @checksum_algorithms [@checksum_algo]

  @native_dir "priv/native"

  @doc deprecated: "Use available_nifs/1 instead"
  def available_nif_urls(nif_module) when is_atom(nif_module) do
    available_nifs(nif_module)
    |> Enum.map(fn {_lib_name, {url, _headers}} -> url end)
  end

  @doc """
  Returns URLs for NIFs based on its module name as a list of tuples: `[{lib_name, {url, headers}}]`.

  The module name is the one that defined the NIF and this information
  is stored in a metadata file.
  """
  def available_nifs(nif_module) when is_atom(nif_module) do
    nif_module
    |> metadata_file()
    |> read_map_from_file()
    |> nifs_from_metadata()
    |> case do
      {:ok, nifs_with_urls} ->
        nifs_with_urls

      {:error, wrong_meta} ->
        raise "metadata about current target for the module #{inspect(nif_module)} is not available. " <>
                "Please compile the project again with: `mix compile --force` " <>
                "Metadata found: #{inspect(wrong_meta, limit: :infinity, pretty: true)}"
    end
  end

  @doc false
  def nif_urls_from_metadata(metadata) when is_map(metadata) do
    with {:ok, nifs} <- nifs_from_metadata(metadata) do
      {:ok, Enum.map(nifs, fn {_lib_name, {url, _headers}} -> url end)}
    end
  end

  @doc false
  def nifs_from_metadata(metadata) when is_map(metadata) do
    case metadata do
      %{
        targets: targets,
        base_url: base_url,
        basename: basename,
        nif_versions: nif_versions,
        version: version
      } ->
        all_tar_gzs =
          for target_triple <- targets, nif_version <- nif_versions do
            tar_gz_urls(
              base_url,
              basename,
              version,
              nif_version,
              target_triple,
              metadata[:variants]
            )
          end

        {:ok, List.flatten(all_tar_gzs)}

      wrong_meta ->
        {:error, wrong_meta}
    end
  end

  defp maybe_variants_tar_gz_urls(nil, _, _, _), do: []

  defp maybe_variants_tar_gz_urls(variants, base_url, target_triple, lib_name)
       when is_map_key(variants, target_triple) do
    variants = Map.fetch!(variants, target_triple)

    for variant <- variants do
      lib_name = lib_name_with_ext(target_triple, lib_name <> "--" <> Atom.to_string(variant))
      {lib_name, tar_gz_file_url(base_url, lib_name)}
    end
  end

  defp maybe_variants_tar_gz_urls(_, _, _, _), do: []

  @doc deprecated: "Use current_target_nifs/1 instead"
  def current_target_nif_urls(nif_module) when is_atom(nif_module) do
    nif_module
    |> current_target_nifs()
    |> Enum.map(fn {_lib_name, {url, _headers}} -> url end)
  end

  @doc """
  Returns the file URLs to be downloaded for current target as a list of tuples: `[{lib_name, {url, headers}}]`.

  It is in the plural because a target may have some variants for it.
  It receives the NIF module.
  """
  def current_target_nifs(nif_module) when is_atom(nif_module) do
    metadata =
      nif_module
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{base_url: base_url, target: target} ->
        [nif_version, target_triple] = parts_from_nif_target(target)

        tar_gz_urls(
          base_url,
          metadata[:basename],
          metadata[:version],
          nif_version,
          target_triple,
          metadata[:variants]
        )

      _ ->
        raise "metadata about current target for the module #{inspect(nif_module)} is not available. " <>
                "Please compile the project again with: `mix compile --force`"
    end
  end

  defp tar_gz_urls(base_url, basename, version, nif_version, target_triple, variants) do
    lib_name = lib_name(basename, version, nif_version, target_triple)
    lib_name_with_ext = lib_name_with_ext(target_triple, lib_name)

    [
      {lib_name_with_ext, tar_gz_file_url(base_url, lib_name_with_ext(target_triple, lib_name))}
      | maybe_variants_tar_gz_urls(variants, base_url, target_triple, lib_name)
    ]
  end

  @doc """
  Returns the target triple for download or compile and load.

  This function is translating and adding more info to the system
  architecture returned by Elixir/Erlang to one used by Rust.

  The returned string has the following format:

      "nif-NIF_VERSION-ARCHITECTURE-VENDOR-OS-ABI"

  ## Examples

      iex> RustlerPrecompiled.target()
      {:ok, "nif-2.16-x86_64-unknown-linux-gnu"}

      iex> RustlerPrecompiled.target()
      {:ok, "nif-2.15-aarch64-apple-darwin"}

  """
  def target(
        config \\ target_config(),
        available_targets \\ Config.default_targets(),
        available_nif_versions \\ Config.available_nif_versions()
      ) do
    arch_os =
      case config.os_type do
        {:unix, _} ->
          config.target_system
          |> normalize_arch_os()
          |> system_arch_to_string()

        {:win32, _} ->
          existing_target =
            config.target_system
            |> system_arch_to_string()

          # For when someone is setting "TARGET_*" vars on Windows
          if existing_target in available_targets do
            existing_target
          else
            # 32 or 64 bits
            arch =
              case config.word_size do
                4 -> "i686"
                8 -> "x86_64"
                _ -> "unknown"
              end

            config.target_system
            |> Map.put_new(:arch, arch)
            |> Map.put_new(:vendor, "pc")
            |> Map.put_new(:os, "windows")
            |> Map.put_new(:abi, "msvc")
            |> system_arch_to_string()
          end
      end

    cond do
      arch_os not in available_targets ->
        {:error,
         "precompiled NIF is not available for this target: #{inspect(arch_os)}.\n" <>
           "The available targets are:\n - #{Enum.join(available_targets, "\n - ")}"}

      config.nif_version not in available_nif_versions ->
        {:error,
         "precompiled NIF is not available for this NIF version: #{inspect(config.nif_version)}.\n" <>
           "The available NIF versions are:\n - #{Enum.join(available_nif_versions, "\n - ")}"}

      true ->
        {:ok, "nif-#{config.nif_version}-#{arch_os}"}
    end
  end

  defp target_config(available_nif_versions \\ Config.available_nif_versions()) do
    current_nif_version = :erlang.system_info(:nif_version) |> List.to_string()

    nif_version =
      case find_compatible_nif_version(current_nif_version, available_nif_versions) do
        {:ok, vsn} ->
          vsn

        :error ->
          # In case of error, use the current so we can tell the user.
          current_nif_version
      end

    current_system_arch = system_arch()

    %{
      os_type: :os.type(),
      target_system: maybe_override_with_env_vars(current_system_arch),
      word_size: :erlang.system_info(:wordsize),
      nif_version: nif_version
    }
  end

  # In case one is using this lib in a newer OTP version, we try to
  # find the latest compatible NIF version.
  @doc false
  def find_compatible_nif_version(vsn, available) do
    if vsn in available do
      {:ok, vsn}
    else
      [major, minor | _] = parse_version(vsn)

      available
      |> Enum.map(&parse_version/1)
      |> Enum.filter(fn
        [^major, available_minor | _] when available_minor <= minor -> true
        [_ | _] -> false
      end)
      |> case do
        [] -> :error
        match -> {:ok, match |> Enum.max() |> Enum.join(".")}
      end
    end
  end

  defp parse_version(vsn) do
    vsn |> String.split(".") |> Enum.map(&String.to_integer/1)
  end

  # Returns a map with `:arch`, `:vendor`, `:os` and maybe `:abi`.
  defp system_arch do
    base =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.split("-")

    triple_keys =
      case length(base) do
        4 ->
          [:arch, :vendor, :os, :abi]

        3 ->
          [:arch, :vendor, :os]

        _ ->
          # It's too complicated to find out, and we won't support this for now.
          []
      end

    triple_keys
    |> Enum.zip(base)
    |> Enum.into(%{})
  end

  # The idea is to support systems like Nerves.
  # See: https://hexdocs.pm/nerves/compiling-non-beam-code.html#target-cpu-arch-os-and-abi
  @doc false
  def maybe_override_with_env_vars(original_sys_arch, get_env \\ &System.get_env/1) do
    envs_with_keys = [
      arch: "TARGET_ARCH",
      vendor: "TARGET_VENDOR",
      os: "TARGET_OS",
      abi: "TARGET_ABI"
    ]

    updated_system_arch =
      Enum.reduce(envs_with_keys, original_sys_arch, fn {key, env_key}, acc ->
        if env_value = get_env.(env_key) do
          Map.put(acc, key, env_value)
        else
          acc
        end
      end)

    # Only replace vendor if remains the same but some other env changed the config.
    if original_sys_arch != updated_system_arch and
         original_sys_arch.vendor == updated_system_arch.vendor and
         updated_system_arch.os == "linux" do
      Map.put(updated_system_arch, :vendor, "unknown")
    else
      updated_system_arch
    end
  end

  defp normalize_arch_os(target_system) do
    cond do
      target_system.os =~ "darwin" ->
        arch = with "arm" <- target_system.arch, do: "aarch64"

        %{target_system | arch: arch, os: "darwin"}

      target_system.os =~ "linux" ->
        arch = normalize_arch(target_system.arch)

        vendor =
          with vendor when vendor in ~w(pc redhat suse alpine) <- target_system.vendor,
               do: "unknown"

        %{target_system | arch: arch, vendor: vendor}

      target_system.os =~ "freebsd" ->
        arch = normalize_arch(target_system.arch)

        vendor = with "portbld" <- target_system.vendor, do: "unknown"

        %{target_system | arch: arch, vendor: vendor, os: "freebsd"}

      true ->
        target_system
    end
  end

  defp normalize_arch("amd64"), do: "x86_64"
  defp normalize_arch("riscv64"), do: "riscv64gc"
  defp normalize_arch(arch), do: arch

  defp system_arch_to_string(system_arch) do
    values =
      for key <- [:arch, :vendor, :os, :abi],
          value = system_arch[key],
          do: value

    Enum.join(values, "-")
  end

  # Calculates metadata based in the TARGET and options
  # from `config`.
  # In case target cannot be resolved and "force build" is enabled,
  # returns only the basic metadata.
  @doc false
  def build_metadata(%Config{} = config) do
    basic_metadata = %{
      base_url: config.base_url,
      crate: config.crate,
      otp_app: config.otp_app,
      targets: config.targets,
      variants: variants_for_metadata(config.variants),
      nif_versions: config.nif_versions,
      version: config.version
    }

    case target(target_config(config.nif_versions), config.targets, config.nif_versions) do
      {:ok, target} ->
        basename = config.crate || config.otp_app

        [nif_version, target_triple] = parts_from_nif_target(target)

        lib_name =
          "#{lib_name(basename, config.version, nif_version, target_triple)}#{variant_suffix(target_triple, config)}"

        file_name = lib_name_with_ext(target, lib_name)

        # `cache_base_dir` is a "private" option used only in tests.
        cache_dir = cache_dir(config.base_cache_dir, "precompiled_nifs")
        cached_tar_gz = Path.join(cache_dir, file_name)

        {:ok,
         Map.merge(basic_metadata, %{
           cached_tar_gz: cached_tar_gz,
           basename: basename,
           lib_name: lib_name,
           file_name: file_name,
           target: target
         })}

      {:error, _} = error ->
        if config.force_build? do
          {:ok, basic_metadata}
        else
          error
        end
    end
  end

  defp variants_for_metadata(variants) do
    Map.new(variants, fn {target, values} -> {target, Keyword.keys(values)} end)
  end

  # Extract the target without the nif-NIF-VERSION part
  defp parts_from_nif_target(nif_target) do
    ["nif", nif_version, triple] = String.split(nif_target, "-", parts: 3)
    [nif_version, triple]
  end

  defp variant_suffix(target, %{variants: variants} = config) when is_map_key(variants, target) do
    variants = Map.fetch!(variants, target)

    callback = fn {_name, func} ->
      if is_function(func, 1) do
        func.(config)
      else
        func.()
      end
    end

    case Enum.find(variants, callback) do
      {name, _} ->
        "--" <> Atom.to_string(name)

      nil ->
        ""
    end
  end

  defp variant_suffix(_, _), do: ""

  # Perform the download or load of the precompiled NIF
  # It will look in the "priv/native/otp_app" first, and if
  # that file doesn't exist, it will try to fetch from cache.
  # In case there is no valid cached file, then it will try
  # to download the NIF from the provided base URL.
  #
  # The `metadata` is a map built by `build_metadata/1` and
  # has details about what is the current target and where
  # to save the downloaded tar.gz.
  @doc false
  def download_or_reuse_nif_file(%Config{} = config, metadata) when is_map(metadata) do
    name = config.otp_app

    native_dir = Application.app_dir(name, @native_dir)

    lib_name = Map.fetch!(metadata, :lib_name)
    cached_tar_gz = Map.fetch!(metadata, :cached_tar_gz)
    cache_dir = Path.dirname(cached_tar_gz)

    file_name = Map.fetch!(metadata, :file_name)
    lib_file = Path.join(native_dir, file_name)

    base_url = config.base_url
    nif_module = config.module

    result = %{
      load?: true,
      load_from: {name, Path.join("priv/native", lib_name)},
      load_data: config.load_data
    }

    if File.exists?(cached_tar_gz) do
      # Remove existing NIF file so we don't have processes using it.
      # See: https://github.com/rusterlium/rustler/blob/46494d261cbedd3c798f584459e42ab7ee6ea1f4/rustler_mix/lib/rustler/compiler.ex#L134
      File.rm(lib_file)

      with :ok <- check_file_integrity(cached_tar_gz, nif_module),
           :ok <- :erl_tar.extract(cached_tar_gz, [:compressed, cwd: Path.dirname(lib_file)]) do
        Logger.debug("Copying NIF from cache and extracting to #{lib_file}")
        {:ok, result}
      end
    else
      dirname = Path.dirname(lib_file)
      tar_gz_url = tar_gz_file_url(base_url, lib_name_with_ext(cached_tar_gz, lib_name))

      with :ok <- File.mkdir_p(cache_dir),
           :ok <- File.mkdir_p(dirname),
           {:ok, tar_gz} <-
             with_retry(fn -> download_nif_artifact(tar_gz_url) end, config.max_retries),
           :ok <- File.write(cached_tar_gz, tar_gz),
           :ok <- check_file_integrity(cached_tar_gz, nif_module),
           :ok <-
             :erl_tar.extract({:binary, tar_gz}, [:compressed, cwd: Path.dirname(lib_file)]) do
        Logger.debug("NIF cached at #{cached_tar_gz} and extracted to #{lib_file}")

        {:ok, result}
      end
    end
  end

  defp checksum_map(nif_module) when is_atom(nif_module) do
    nif_module
    |> checksum_file()
    |> read_map_from_file()
  end

  defp check_file_integrity(file_path, nif_module) when is_atom(nif_module) do
    nif_module
    |> checksum_map()
    |> check_integrity_from_map(file_path, nif_module)
  end

  # It receives the map of %{ "filename" => "algo:checksum" } with the file path
  @doc false
  def check_integrity_from_map(checksum_map, file_path, nif_module) do
    with {:ok, {algo, hash}} <- find_checksum(checksum_map, file_path, nif_module),
         :ok <- validate_checksum_algo(algo),
         do: compare_checksum(file_path, algo, hash)
  end

  defp find_checksum(checksum_map, file_path, nif_module) do
    basename = Path.basename(file_path)

    case Map.fetch(checksum_map, basename) do
      {:ok, algo_with_hash} ->
        [algo, hash] = String.split(algo_with_hash, ":")
        algo = String.to_existing_atom(algo)

        {:ok, {algo, hash}}

      :error ->
        {:error,
         "the precompiled NIF file does not exist in the checksum file. " <>
           "Please consider run: `mix rustler_precompiled.download #{inspect(nif_module)} --only-local` to generate the checksum file."}
    end
  end

  defp validate_checksum_algo(algo) do
    if algo in @checksum_algorithms do
      :ok
    else
      {:error,
       "checksum algorithm is not supported: #{inspect(algo)}. " <>
         "The supported ones are:\n - #{Enum.join(@checksum_algorithms, "\n - ")}"}
    end
  end

  defp compare_checksum(file_path, algo, expected_checksum) do
    case File.read(file_path) do
      {:ok, content} ->
        file_hash =
          algo
          |> :crypto.hash(content)
          |> Base.encode16(case: :lower)

        if file_hash == expected_checksum do
          :ok
        else
          {:error, "the integrity check failed because the checksum of files does not match"}
        end

      {:error, reason} ->
        {:error,
         "cannot read the file for checksum comparison: #{inspect(file_path)}. " <>
           "Reason: #{inspect(reason)}"}
    end
  end

  defp cache_dir(sub_dir) do
    global_cache_path = System.get_env("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH")

    if global_cache_path do
      Logger.info(
        "Using global cache for rustler precompiled artifacts. Path: #{global_cache_path}"
      )

      global_cache_path
    else
      cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
      :filename.basedir(:user_cache, Path.join("rustler_precompiled", sub_dir), cache_opts)
    end
  end

  # This arity is only used in test context. It should be private because
  # we can't provide this option in the `mix rustler_precompiled.download` task.
  defp cache_dir(basedir, sub_dir) do
    if basedir do
      Path.join(basedir, sub_dir)
    else
      cache_dir(sub_dir)
    end
  end

  defp lib_prefix(target) do
    if String.contains?(target, "windows") do
      ""
    else
      "lib"
    end
  end

  defp lib_name(basename, version, nif_version, target_triple) do
    "#{lib_prefix(target_triple)}#{basename}-v#{version}-nif-#{nif_version}-#{target_triple}"
  end

  defp lib_name_with_ext(target, lib_name) do
    ext =
      if String.contains?(target, "windows") do
        "dll"
      else
        "so"
      end

    "#{lib_name}.#{ext}.tar.gz"
  end

  defp tar_gz_file_url({module, function_name}, file_name)
       when is_atom(module) and is_atom(function_name) do
    apply(module, function_name, [file_name])
  end

  defp tar_gz_file_url({base_url, request_headers}, file_name) do
    uri = URI.parse(base_url)

    uri =
      Map.update!(uri, :path, fn path ->
        Path.join(path || "", file_name)
      end)

    {to_string(uri), request_headers}
  end

  defp tar_gz_file_url(base_url, file_name) do
    tar_gz_file_url({base_url, []}, file_name)
  end

  defp download_nif_artifact(url) when is_binary(url) do
    download_nif_artifact({url, []})
  end

  defp download_nif_artifact({url, request_headers}) do
    url = String.to_charlist(url)
    Logger.debug("Downloading NIF from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    http_proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
    http_proxy_auth = configure_proxy(http_proxy, :proxy, "HTTP_PROXY")

    https_proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")
    https_proxy_auth = configure_proxy(https_proxy, :https_proxy, "HTTPS_PROXY")

    # Use HTTPS proxy auth if available, otherwise fall back to HTTP proxy auth
    proxy_auth = https_proxy_auth || http_proxy_auth

    # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
    # respects the user provided ca certs via Hex env var
    cacertfile = System.get_env("HEX_CACERTS_PATH", CAStore.file_path())

    http_options =
      [
        ssl: [
          verify: :verify_peer,
          cacertfile: cacertfile |> String.to_charlist(),
          # We need to increase depth because the default value is 1.
          # See: https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/ssl
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
      |> maybe_add_proxy_auth(proxy_auth)

    options = [body_format: :binary]

    request_headers =
      Enum.map(request_headers, fn {k, v} when is_binary(k) -> {String.to_charlist(k), v} end)

    case :httpc.request(:get, {url, request_headers}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      other ->
        {:error, "couldn't fetch NIF from #{url}: #{inspect(other)}"}
    end
  end

  defp configure_proxy(proxy, proxy_type, env_name) when is_binary(proxy) do
    case URI.parse(proxy) do
      %{host: host, port: port, userinfo: userinfo}
      when is_binary(host) and is_integer(port) ->
        Logger.debug("Using #{env_name}: #{redact_userinfo(proxy)}")
        :httpc.set_options([{proxy_type, {{String.to_charlist(host), port}, []}}])
        parse_proxy_auth(userinfo)

      _ ->
        nil
    end
  end

  defp configure_proxy(_proxy, _proxy_type, _env_name), do: nil

  @doc false
  def parse_proxy_auth(nil), do: nil
  def parse_proxy_auth(""), do: nil

  def parse_proxy_auth(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {String.to_charlist(user), String.to_charlist(pass)}
      [user] -> {String.to_charlist(user), ~c""}
    end
  end

  defp maybe_add_proxy_auth(http_options, nil), do: http_options

  defp maybe_add_proxy_auth(http_options, proxy_auth),
    do: [{:proxy_auth, proxy_auth} | http_options]

  @doc false
  def redact_userinfo(url) do
    uri = URI.parse(url)

    if uri.userinfo do
      %{uri | userinfo: "[REDACTED]"} |> to_string()
    else
      url
    end
  end

  # Download a list of files from URLs and calculate its checksum.
  # Returns a list with details of the download and the checksum of each file.
  @doc false
  def download_nif_artifacts_with_checksums!(nifs_with_urls, options \\ []) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)
    attempts = max_retries(options)

    download_results =
      for {lib_name, url} <- nifs_with_urls,
          do: {lib_name, with_retry(fn -> download_nif_artifact(url) end, attempts)}

    cache_dir = cache_dir("precompiled_nifs")
    :ok = File.mkdir_p(cache_dir)

    Enum.flat_map(download_results, fn result ->
      with {:download, {lib_name, download_result}} <- {:download, result},
           {:download_result, {:ok, body}} <- {:download_result, download_result},
           hash <- :crypto.hash(@checksum_algo, body),
           path <- Path.join(cache_dir, lib_name),
           {:file, :ok} <- {:file, File.write(path, body)} do
        checksum = Base.encode16(hash, case: :lower)

        Logger.debug(
          "NIF cached at #{path} with checksum #{inspect(checksum)} (#{@checksum_algo})"
        )

        [
          %{
            lib_name: lib_name,
            path: path,
            checksum: checksum,
            checksum_algo: @checksum_algo
          }
        ]
      else
        {:file, error} ->
          raise "could not write downloaded file to disk. Reason: #{inspect(error)}"

        {context, result} ->
          if ignore_unavailable? do
            Logger.debug(
              "Skip an unavailable NIF artifact. " <>
                "Context: #{inspect(context)}. Reason: #{inspect(result)}"
            )

            []
          else
            raise "could not finish the download of NIF artifacts. " <>
                    "Context: #{inspect(context)}. Reason: #{inspect(result)}"
          end
      end
    end)
  end

  defp max_retries(options) do
    value = Keyword.get(options, :max_retries, 3)

    if value not in 0..15,
      do: raise("attempts should be between 0 and 15. Got: #{inspect(value)}")

    value
  end

  defp with_retry(fun, attempts) when attempts in 0..15 do
    first_try = fun.()

    Enum.reduce_while(1..attempts//1, first_try, fn count, partial_result ->
      case partial_result do
        {:ok, _} ->
          {:halt, partial_result}

        err ->
          Logger.info("Attempt #{count} failed with #{inspect(err)}")

          wait_in_ms = :rand.uniform(count * 2_000)
          Process.sleep(wait_in_ms)

          {:cont, fun.()}
      end
    end)
  end

  defp read_map_from_file(file) do
    with {:ok, contents} <- File.read(file),
         {%{} = contents, _} <- Code.eval_string(contents) do
      contents
    else
      _ -> %{}
    end
  end

  defp write_metadata(nif_module, metadata) do
    metadata_file = metadata_file(nif_module)
    existing = read_map_from_file(metadata_file)

    if Map.equal?(metadata, existing) do
      :ok
    else
      dir = Path.dirname(metadata_file)

      with :ok <- File.mkdir_p(dir) do
        File.write(metadata_file, inspect(metadata, limit: :infinity, pretty: true))
      end
    end
  end

  defp metadata_file(nif_module) when is_atom(nif_module) do
    rustler_precompiled_cache = cache_dir("metadata")
    Path.join(rustler_precompiled_cache, "metadata-#{nif_module}.exs")
  end

  # Write the checksum file with all NIFs available.
  # It receives the module name and checksums.
  @doc false
  def write_checksum!(nif_module, checksums) when is_atom(nif_module) do
    metadata =
      nif_module
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{otp_app: _name} ->
        file = checksum_file(nif_module)

        pairs =
          for %{path: path, checksum: checksum, checksum_algo: algo} <- checksums, into: %{} do
            basename = Path.basename(path)
            checksum = "#{algo}:#{checksum}"
            {basename, checksum}
          end

        lines =
          for {filename, checksum} <- Enum.sort(pairs) do
            ~s(  "#{filename}" => #{inspect(checksum, limit: :infinity)},\n)
          end

        File.write!(file, ["%{\n", lines, "}\n"])

      _ ->
        raise "could not find the OTP app for #{inspect(nif_module)} in the metadata file. " <>
                "Please compile the project again with: `mix compile --force`."
    end
  end

  defp checksum_file(nif_module) do
    # Saves the file in the project root.
    Path.join(File.cwd!(), "checksum-#{nif_module}.exs")
  end
end
