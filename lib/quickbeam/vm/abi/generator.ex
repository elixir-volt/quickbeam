defmodule QuickBEAM.VM.ABI.Generator do
  @moduledoc """
  Extracts bytecode ABI metadata from the vendored QuickJS C sources.

  The generated version, tags, opcodes, atoms, and fingerprint keep decoding
  coupled to the exact engine build that produced serialized bytecode.
  """

  alias QuickBEAM.VM.ABI.Source

  @doc "Returns the vendored QuickJS bytecode version."
  @spec version!(String.t()) :: pos_integer()
  def version!(source) do
    source
    |> Source.define!("BC_VERSION")
    |> unsigned_integer!("BC_VERSION")
  end

  @doc "Returns the bytecode tag table from the vendored QuickJS source."
  @spec tags!(String.t()) :: %{atom() => non_neg_integer()}
  def tags!(source) do
    source
    |> Source.enum_entries!("BCTagEnum")
    |> Enum.reduce({%{}, 0}, fn entry, {tags, previous} ->
      {name, value} = tag!(entry, previous)
      {Map.put(tags, name, value), value}
    end)
    |> elem(0)
  end

  @doc "Returns the opcode table from the vendored QuickJS opcode header."
  @spec opcodes!(String.t()) :: %{non_neg_integer() => tuple()}
  def opcodes!(header) do
    rows =
      header
      |> Source.macro_arguments("DEF")
      |> Enum.with_index()
      |> Map.new(fn {arguments, opcode} -> {opcode, opcode!(arguments)} end)

    if map_size(rows) == 0 or map_size(rows) > 256 do
      raise ArgumentError, "invalid opcode table size: #{map_size(rows)}"
    end

    rows
  end

  @doc "Returns the predefined atom table from the vendored QuickJS atom header."
  @spec atoms!(String.t()) :: %{pos_integer() => String.t()}
  def atoms!(header) do
    header
    |> Source.macro_arguments("DEF")
    |> Enum.with_index(1)
    |> Map.new(fn {arguments, index} -> {index, atom_value!(arguments)} end)
  end

  @doc "Returns a digest binding generated metadata to its exact source inputs."
  @spec fingerprint(non_neg_integer(), non_neg_integer(), [binary()]) :: String.t()
  def fingerprint(version, decoder_version, sources) do
    source_digests = Enum.map(sources, &:crypto.hash(:sha256, &1))
    payload = :erlang.term_to_binary({decoder_version, version, source_digests})
    payload |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp tag!(entry, previous) do
    case String.split(entry, "=", parts: 2) do
      [name] -> {tag_name!(name), previous + 1}
      [name, value] -> {tag_name!(name), unsigned_integer!(String.trim(value), entry)}
    end
  end

  defp tag_name!(name) do
    case String.trim(name) do
      "BC_TAG_" <> suffix -> suffix |> identifier!(:tag) |> String.downcase() |> String.to_atom()
      _other -> raise ArgumentError, "unsupported bytecode tag definition: #{inspect(name)}"
    end
  end

  defp opcode!([name, size, pops, pushes, format]) do
    {
      name |> identifier!(:opcode) |> String.to_atom(),
      unsigned_integer!(size, name),
      unsigned_integer!(pops, name),
      unsigned_integer!(pushes, name),
      format |> identifier!(:opcode_format) |> String.to_atom()
    }
  end

  defp opcode!(arguments),
    do: raise(ArgumentError, "unsupported opcode definition: #{inspect(arguments)}")

  defp atom_value!([name, value]) do
    identifier!(name, :atom)
    quoted_string!(value, name)
  end

  defp atom_value!(arguments),
    do: raise(ArgumentError, "unsupported atom definition: #{inspect(arguments)}")

  defp quoted_string!(value, context) do
    value = String.trim(value)

    case value do
      <<?", rest::binary>> when byte_size(rest) > 0 ->
        if String.ends_with?(rest, "\"") do
          binary_part(rest, 0, byte_size(rest) - 1)
        else
          raise ArgumentError, "unterminated string for #{context}"
        end

      _other ->
        raise ArgumentError, "expected string for #{context}, got: #{inspect(value)}"
    end
  end

  defp unsigned_integer!(value, context) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _other -> raise ArgumentError, "expected unsigned integer for #{context}: #{inspect(value)}"
    end
  end

  defp identifier!(value, context) do
    value = String.trim(value)

    if value != "" and Enum.all?(String.to_charlist(value), &identifier_character?/1) do
      value
    else
      raise ArgumentError, "invalid #{context} identifier: #{inspect(value)}"
    end
  end

  defp identifier_character?(character) when character in ?a..?z, do: true
  defp identifier_character?(character) when character in ?A..?Z, do: true
  defp identifier_character?(character) when character in ?0..?9, do: true
  defp identifier_character?(?_), do: true
  defp identifier_character?(_character), do: false
end
