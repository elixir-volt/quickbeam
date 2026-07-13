defmodule QuickBEAM.VM.Builtin.Validator do
  @moduledoc "Validates builtin declarations and handler contracts at compile time."

  alias QuickBEAM.VM.Builtin.{AccessorSpec, AliasSpec, FunctionSpec, PropertySpec, Spec}

  @doc "Validates a compiled builtin spec against its declaring module."
  @spec validate!(Spec.t(), Macro.Env.t()) :: :ok
  def validate!(%Spec{} = spec, env) do
    unless is_binary(spec.name) and spec.name != "" do
      compile_error!(env, "builtin name must be a non-empty string")
    end

    unless spec.kind in [:namespace, :constructor, :intrinsic] do
      compile_error!(env, "unsupported builtin kind: #{inspect(spec.kind)}")
    end

    unless is_integer(spec.length) and spec.length >= 0 do
      compile_error!(env, "builtin length must be a non-negative integer")
    end

    unless spec.profiles != [] and Enum.all?(spec.profiles, &is_atom/1) do
      compile_error!(env, "builtin profiles must be a non-empty atom list")
    end

    unless Enum.all?(spec.depends_on, &(is_binary(&1) and &1 != "")) do
      compile_error!(env, "builtin dependencies must be non-empty strings")
    end

    if spec.kind == :constructor and not is_atom(spec.constructor) do
      compile_error!(env, "constructor builtins require a :constructor handler")
    end

    unless is_nil(spec.prototype_parent) or spec.prototype_parent == :null or
             (is_binary(spec.prototype_parent) and spec.prototype_parent in spec.depends_on) do
      compile_error!(env, "prototype parent must be :null or a declared dependency")
    end

    unless is_nil(spec.prototype_role) or spec.prototype_role in [:ordinary, :function] or
             match?({:error, name} when is_binary(name), spec.prototype_role) do
      compile_error!(env, "unsupported prototype role: #{inspect(spec.prototype_role)}")
    end

    entries = spec.statics ++ spec.prototype
    duplicate_keys!(spec.statics, :static, env)
    duplicate_keys!(spec.prototype, :prototype, env)

    handlers =
      entries
      |> Enum.flat_map(&entry_handlers/1)
      |> then(fn handlers ->
        if spec.constructor, do: [spec.constructor | handlers], else: handlers
      end)
      |> Enum.uniq()

    Enum.each(handlers, fn handler ->
      unless is_atom(handler) and Module.defines?(env.module, {handler, 1}, :def) do
        compile_error!(env, "builtin handler #{inspect(handler)}/1 must be a public function")
      end
    end)

    Enum.each(entries, &validate_entry!(&1, env))
  end

  defp entry_handlers(%FunctionSpec{handler: handler}), do: [handler]

  defp entry_handlers(%AccessorSpec{getter: getter, setter: setter}),
    do: Enum.reject([getter, setter], &is_nil/1)

  defp entry_handlers(%PropertySpec{}), do: []
  defp entry_handlers(%AliasSpec{}), do: []

  defp validate_entry!(%FunctionSpec{key: key, length: length} = spec, env) do
    unless is_integer(length) and length >= 0 do
      compile_error!(env, "invalid function length for #{inspect(key)}")
    end

    validate_flags!(spec, env)
  end

  defp validate_entry!(%AccessorSpec{getter: nil, setter: nil, key: key}, env),
    do: compile_error!(env, "accessor #{inspect(key)} requires a getter or setter")

  defp validate_entry!(%AccessorSpec{} = spec, env), do: validate_flags!(spec, env)
  defp validate_entry!(%PropertySpec{} = spec, env), do: validate_flags!(spec, env)
  defp validate_entry!(%AliasSpec{} = spec, env), do: validate_flags!(spec, env)

  defp validate_flags!(spec, env) do
    flags =
      spec
      |> Map.from_struct()
      |> Map.take([:writable, :enumerable, :configurable])

    unless Enum.all?(flags, fn {_key, value} -> is_boolean(value) end) do
      compile_error!(env, "property descriptor flags must be boolean: #{inspect(spec.key)}")
    end
  end

  defp duplicate_keys!(entries, namespace, env) do
    keys = Enum.map(entries, & &1.key)

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      duplicates ->
        compile_error!(env, "duplicate #{namespace} keys: #{inspect(Enum.uniq(duplicates))}")
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
