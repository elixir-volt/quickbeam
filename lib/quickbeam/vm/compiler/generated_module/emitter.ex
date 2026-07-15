defmodule QuickBEAM.VM.Compiler.GeneratedModule.Emitter do
  @moduledoc """
  Emits bounded slot-specific module binaries from Erlang abstract forms.

  The emitter validates the template envelope, replaces its fixed placeholder
  module, invokes the Erlang forms compiler, and applies the generated import
  policy before returning an artifact.
  """

  alias QuickBEAM.VM.Compiler.Contract
  alias QuickBEAM.VM.Compiler.GeneratedModule.{Artifact, ImportPolicy, Template}

  @max_form_count 5_000
  @max_form_bytes 8 * 1024 * 1024
  @entry_export {:run, 3}
  @placeholder_module Template.placeholder_module()
  @artifact_key_bytes Contract.artifact_key_bytes()

  @doc "Emits one validated artifact for an assigned static module slot."
  @spec emit(binary(), module(), Template.t()) :: {:ok, Artifact.t()} | {:error, term()}
  def emit(key, module, %Template{forms: forms}) do
    with :ok <- validate_key(key),
         :ok <- validate_module(module),
         {:ok, forms} <- prepare_forms(forms, module),
         {:ok, binary} <- compile_forms(forms, module),
         :ok <- ImportPolicy.validate(binary) do
      Artifact.new(module, binary)
    end
  end

  def emit(_key, _module, input), do: {:error, {:invalid_compiler_template, input}}

  defp prepare_forms(forms, module) when is_list(forms) do
    with :ok <- validate_form_count(forms),
         :ok <- validate_form_bytes(forms),
         :ok <- validate_top_level_forms(forms),
         :ok <- validate_module_attribute(forms),
         :ok <- validate_exports(forms) do
      {:ok, Enum.map(forms, &replace_module_attribute(&1, module))}
    end
  end

  defp prepare_forms(forms, _module), do: {:error, {:invalid_compiler_forms, forms}}

  defp validate_form_count(forms) when length(forms) <= @max_form_count, do: :ok

  defp validate_form_count(forms),
    do: {:error, {:compiler_resource_limit, :forms, length(forms), @max_form_count}}

  defp validate_form_bytes(forms) do
    size = :erlang.external_size(forms)

    if size <= @max_form_bytes,
      do: :ok,
      else: {:error, {:compiler_resource_limit, :form_bytes, size, @max_form_bytes}}
  end

  defp validate_top_level_forms(forms) do
    case Enum.find(forms, &(not allowed_top_level_form?(&1))) do
      nil -> :ok
      form -> {:error, {:unsupported_compiler_form, form}}
    end
  end

  defp allowed_top_level_form?({:attribute, _line, name, _value})
       when name in [:module, :export, :file],
       do: true

  defp allowed_top_level_form?({:function, _line, name, arity, clauses}),
    do: is_atom(name) and is_integer(arity) and arity >= 0 and is_list(clauses)

  defp allowed_top_level_form?({:eof, _line}), do: true
  defp allowed_top_level_form?(_form), do: false

  defp validate_module_attribute(forms) do
    modules = for {:attribute, _line, :module, module} <- forms, do: module

    case modules do
      [@placeholder_module] -> :ok
      _modules -> {:error, {:invalid_compiler_module_attributes, modules}}
    end
  end

  defp validate_exports(forms) do
    exports = for {:attribute, _line, :export, exports} <- forms, do: exports

    case exports do
      [[@entry_export]] -> :ok
      _exports -> {:error, {:invalid_compiler_exports, exports}}
    end
  end

  defp replace_module_attribute({:attribute, line, :module, _placeholder}, module),
    do: {:attribute, line, :module, module}

  defp replace_module_attribute(form, _module), do: form

  defp compile_forms(forms, module) do
    case :compile.forms(forms, [:binary, :deterministic, :return_errors, :return_warnings]) do
      {:ok, ^module, binary} ->
        {:ok, binary}

      {:ok, ^module, binary, []} ->
        {:ok, binary}

      {:ok, ^module, _binary, warnings} ->
        {:error, {:generated_module_warnings, warnings}}

      {:error, errors, warnings} ->
        {:error, {:generated_module_compile_failed, errors, warnings}}

      other ->
        {:error, {:generated_module_compile_failed, other}}
    end
  end

  defp validate_key(key)
       when is_binary(key) and byte_size(key) == @artifact_key_bytes,
       do: :ok

  defp validate_key(key), do: {:error, {:invalid_artifact_key, key}}

  defp validate_module(module) do
    if module in Contract.pool_modules(),
      do: :ok,
      else: {:error, {:invalid_compiler_module, module}}
  end
end
