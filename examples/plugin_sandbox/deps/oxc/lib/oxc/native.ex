defmodule OXC.Native do
  use Rustler, otp_app: :oxc, crate: "oxc_ex_nif"

  @spec parse(String.t(), String.t()) :: {:ok, map()} | {:error, list()}
  def parse(_source, _filename), do: :erlang.nif_error(:nif_not_loaded)

  @spec valid(String.t(), String.t()) :: boolean()
  def valid(_source, _filename), do: :erlang.nif_error(:nif_not_loaded)

  @spec transform(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          boolean()
        ) ::
          {:ok, String.t() | map()} | {:error, list()}
  def transform(
        _source,
        _filename,
        _jsx_runtime,
        _jsx_factory,
        _jsx_fragment,
        _import_source,
        _target,
        _sourcemap
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @spec minify(String.t(), String.t(), boolean()) :: {:ok, String.t()} | {:error, list()}
  def minify(_source, _filename, _mangle), do: :erlang.nif_error(:nif_not_loaded)

  @spec bundle([{String.t(), String.t()}], keyword()) ::
          {:ok, String.t() | map()} | {:error, [String.t()]}
  def bundle(_files, _opts), do: :erlang.nif_error(:nif_not_loaded)

  @spec imports(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def imports(_source, _filename), do: :erlang.nif_error(:nif_not_loaded)
end
