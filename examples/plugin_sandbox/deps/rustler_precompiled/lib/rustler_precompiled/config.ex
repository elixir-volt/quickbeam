defmodule RustlerPrecompiled.Config do
  @moduledoc false

  # This is an internal struct to represent valid config options.
  defstruct [
    :otp_app,
    :module,
    :base_url,
    :version,
    :crate,
    :base_cache_dir,
    :load_data,
    :force_build?,
    :targets,
    :nif_versions,
    variants: %{},
    max_retries: 3
  ]

  @default_targets ~w(
    aarch64-apple-darwin
    aarch64-unknown-linux-gnu
    aarch64-unknown-linux-musl
    arm-unknown-linux-gnueabihf
    riscv64gc-unknown-linux-gnu
    x86_64-apple-darwin
    x86_64-pc-windows-gnu
    x86_64-pc-windows-msvc
    x86_64-unknown-linux-gnu
    x86_64-unknown-linux-musl
  )

  @available_nif_versions ~w(2.14 2.15 2.16 2.17)
  @default_nif_versions ~w(2.15)

  def default_targets, do: @default_targets
  def available_targets, do: RustlerPrecompiled.Config.AvailableTargets.list()

  def available_nif_versions, do: @available_nif_versions
  def default_nif_versions, do: @default_nif_versions

  def new(opts) do
    version = Keyword.fetch!(opts, :version)
    otp_app = opts |> Keyword.fetch!(:otp_app) |> validate_otp_app!()
    base_url = opts |> Keyword.fetch!(:base_url) |> validate_base_url!()

    targets =
      opts
      |> Keyword.get(:targets, @default_targets)
      |> validate_list!(:targets, available_targets())

    nif_versions =
      opts
      |> Keyword.get(:nif_versions, @default_nif_versions)
      |> validate_list!(:nif_versions, @available_nif_versions)

    %__MODULE__{
      otp_app: otp_app,
      base_url: base_url,
      module: Keyword.fetch!(opts, :module),
      version: version,
      force_build?: pre_release?(version) or Keyword.fetch!(opts, :force_build),
      crate: opts[:crate],
      # Default to `0` like `Rustler`.
      load_data: opts[:load_data] || 0,
      base_cache_dir: opts[:base_cache_dir],
      targets: targets,
      nif_versions: nif_versions,
      variants: validate_variants!(targets, Keyword.get(opts, :variants, %{})),
      max_retries: validate_max_retries!(Keyword.get(opts, :max_retries, 3))
    }
  end

  defp validate_otp_app!(nil), do: raise_for_nil_field_value(:otp_app)

  defp validate_otp_app!(otp_app) do
    if is_atom(otp_app) do
      otp_app
    else
      raise "`:otp_app` is required to be an atom for `RustlerPrecompiled` options"
    end
  end

  defp validate_base_url!(nil), do: raise_for_nil_field_value(:base_url)

  defp validate_base_url!(base_url) when is_binary(base_url) do
    validate_base_url!({base_url, []})
  end

  defp validate_base_url!({base_url, headers}) when is_binary(base_url) and is_list(headers) do
    case :uri_string.parse(base_url) do
      %{} ->
        if Enum.all?(headers, &match?({key, value} when is_binary(key) and is_binary(value), &1)) do
          {base_url, headers}
        else
          raise "`:base_url` headers for `RustlerPrecompiled` must be a list of `{binary(),binary()}`"
        end

      {:error, :invalid_uri, error} ->
        raise "`:base_url` for `RustlerPrecompiled` is invalid: #{inspect(to_string(error))}"
    end
  end

  defp validate_base_url!({module, function}) when is_atom(module) and is_atom(function) do
    Code.ensure_compiled!(module)

    if Kernel.function_exported?(module, function, 1) do
      {module, function}
    else
      raise "`:base_url` for `RustlerPrecompiled` is a function that does not exist: `#{inspect(module)}.#{function}/1`"
    end
  end

  defp validate_list!(nil, option, _valid_values), do: raise_for_nil_field_value(option)

  defp validate_list!([_ | _] = values, option, valid_values) do
    uniq_values = Enum.uniq(values)

    case uniq_values -- valid_values do
      [] ->
        uniq_values

      invalid_values ->
        raise """
        `:#{option}` contains #{option} that are not supported:

        #{inspect(invalid_values, pretty: true)}
        """
    end
  end

  defp validate_list!(_values, option, _valid_values) do
    raise "`:#{option}` is required to be a list of supported #{option}"
  end

  defp validate_max_retries!(nil), do: raise_for_nil_field_value(:max_retries)
  defp validate_max_retries!(num) when num in 0..15, do: num

  defp validate_max_retries!(other) do
    raise "`:max_retries` is required to be an integer of value between 0 and 15. Got #{inspect(other)}"
  end

  defp raise_for_nil_field_value(field) do
    raise "`#{inspect(field)}` is required for `RustlerPrecompiled`"
  end

  defp pre_release?(version), do: "dev" in Version.parse!(version).pre

  defp validate_variants!(_, nil), do: %{}

  defp validate_variants!(targets, variants) when is_map(variants) do
    variants_targets = Map.keys(variants)

    for target <- variants_targets do
      if target not in targets do
        raise "`:variants` contains a target that is not in the list of valid targets: #{inspect(target)}"
      end

      possibilities = Map.fetch!(variants, target)

      for {name, fun} <- possibilities do
        if not is_atom(name) do
          raise "`:variants` expects a keyword list as values, but found a key that is not an atom: #{inspect(name)}"
        end

        if not (is_function(fun, 0) or is_function(fun, 1)) do
          raise "`:variants` expects a keyword list as values with functions to detect if a given variant is to be activated"
        end
      end
    end

    variants
  end
end
