defmodule QuickBEAM.VM.Builtin.Validator do
  @moduledoc "Validates builtin declarations and handler contracts at compile time."

  alias QuickBEAM.VM.Builtin.Spec
  alias QuickBEAM.VM.Builtin.Spec.Accessor, as: AccessorSpec
  alias QuickBEAM.VM.Builtin.Spec.Alias, as: AliasSpec
  alias QuickBEAM.VM.Builtin.Spec.Function, as: FunctionSpec
  alias QuickBEAM.VM.Builtin.Spec.Property, as: PropertySpec
  alias QuickBEAM.VM.Builtin.Spec.Prototype, as: PrototypeSpec

  @doc "Validates a compiled builtin spec against its declaring module."
  @spec validate!(Spec.t(), Macro.Env.t()) :: :ok
  def validate!(%Spec{} = spec, env) do
    validate_spec!(spec, env)
    %PrototypeSpec{} = prototype = spec.prototype_spec
    validate_prototype!(prototype, spec, env)

    entries = spec.statics ++ spec.prototype
    duplicate_keys!(spec.statics, :static, env)
    duplicate_keys!(spec.prototype, :prototype, env)
    validate_handlers!(entries, prototype, spec, env)
    Enum.each(entries, &validate_entry!(&1, env))
  end

  defp validate_spec!(spec, env) do
    validate!(
      is_binary(spec.name) and spec.name != "",
      env,
      "builtin name must be a non-empty string"
    )

    validate!(spec.kind in [:namespace, :function, :constructor, :intrinsic], env, fn ->
      "unsupported builtin kind: #{inspect(spec.kind)}"
    end)

    validate!(
      is_integer(spec.length) and spec.length >= 0,
      env,
      "builtin length must be a non-negative integer"
    )

    validate!(
      spec.profiles != [] and Enum.all?(spec.profiles, &is_atom/1),
      env,
      "builtin profiles must be a non-empty atom list"
    )

    validate!(
      Enum.all?(spec.depends_on, &(is_binary(&1) and &1 != "")),
      env,
      "builtin dependencies must be non-empty strings"
    )

    validate!(
      spec.kind != :constructor or is_atom(spec.constructor),
      env,
      "constructor builtins require a :constructor handler"
    )
  end

  defp validate_prototype!(prototype, spec, env) do
    valid_parent? =
      prototype.extends in [:default, nil] or
        (is_binary(prototype.extends) and prototype.extends in spec.depends_on)

    validate!(valid_parent?, env, "prototype :extends must name a declared dependency or be nil")

    validate!(prototype.kind in [:ordinary, :array, :function], env, fn ->
      "unsupported prototype kind: #{inspect(prototype.kind)}"
    end)

    validate!(
      is_nil(prototype.default_for) or is_atom(prototype.default_for),
      env,
      "prototype :default_for must be an atom"
    )

    validate!(
      is_nil(prototype.error_type) or is_binary(prototype.error_type),
      env,
      "prototype :error_type must be a string"
    )

    valid_primitive? =
      is_nil(prototype.primitive) or
        match?({kind, _value} when is_atom(kind), prototype.primitive)

    validate!(valid_primitive?, env, "prototype :primitive must be a {kind, value} pair")

    validate!(
      prototype.kind != :function or is_atom(prototype.callable),
      env,
      "function prototypes require a :callable handler"
    )
  end

  defp validate_handlers!(entries, prototype, spec, env) do
    handlers =
      entries
      |> Enum.flat_map(&entry_handlers/1)
      |> maybe_prepend(spec.constructor)
      |> maybe_prepend(if(spec.kind == :function, do: :call))
      |> maybe_prepend(prototype.callable)
      |> Enum.uniq()

    Enum.each(handlers, fn handler ->
      validate!(is_atom(handler) and Module.defines?(env.module, {handler, 1}, :def), env, fn ->
        "builtin handler #{inspect(handler)}/1 must be a public function"
      end)
    end)
  end

  defp maybe_prepend(values, nil), do: values
  defp maybe_prepend(values, value), do: [value | values]

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

  defp validate!(true, _env, _description), do: :ok

  defp validate!(false, env, description) when is_binary(description),
    do: compile_error!(env, description)

  defp validate!(false, env, description), do: compile_error!(env, description.())

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
