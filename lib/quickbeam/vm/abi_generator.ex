defmodule QuickBEAM.VM.ABIGenerator do
  @moduledoc """
  Extracts bytecode ABI metadata from the vendored QuickJS C sources.

  The generated version, tags, opcodes, atoms, and fingerprint keep decoding
  coupled to the exact engine build that produced serialized bytecode.
  """

  @opcode_pattern ~r/^\s*DEF\(\s*([A-Za-z0-9_]+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([A-Za-z0-9_]+)\s*\)/m
  @atom_pattern ~r/^\s*DEF\(\s*([A-Za-z0-9_]+)\s*,\s*"([^"]*)"\s*\)/m

  def version!(source) do
    case Regex.run(~r/^#define\s+BC_VERSION\s+(\d+)$/m, source) do
      [_, version] -> String.to_integer(version)
      _ -> raise "BC_VERSION not found in vendored quickjs.c"
    end
  end

  def tags!(source) do
    with [_, body] <- Regex.run(~r/typedef enum BCTagEnum\s*\{(.*?)\}\s*BCTagEnum;/s, source) do
      body
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({%{}, 0}, fn entry, {tags, previous} ->
        case Regex.run(~r/^BC_TAG_([A-Z0-9_]+)(?:\s*=\s*(\d+))?$/, entry) do
          [_, name] ->
            value = previous + 1
            {Map.put(tags, tag_name(name), value), value}

          [_, name, explicit] ->
            value = String.to_integer(explicit)
            {Map.put(tags, tag_name(name), value), value}

          _ ->
            raise "unsupported bytecode tag definition: #{inspect(entry)}"
        end
      end)
      |> elem(0)
    else
      _ -> raise "BCTagEnum not found in vendored quickjs.c"
    end
  end

  def opcodes!(header) do
    rows =
      @opcode_pattern
      |> Regex.scan(header)
      |> Enum.with_index()
      |> Map.new(fn {[_, name, size, pops, pushes, format], opcode} ->
        {opcode,
         {String.to_atom(name), String.to_integer(size), String.to_integer(pops),
          String.to_integer(pushes), String.to_atom(format)}}
      end)

    if map_size(rows) == 0 or map_size(rows) > 256 do
      raise "invalid opcode table size: #{map_size(rows)}"
    end

    rows
  end

  def atoms!(header) do
    @atom_pattern
    |> Regex.scan(header)
    |> Enum.with_index(1)
    |> Map.new(fn {[_, _name, value], index} -> {index, value} end)
  end

  def fingerprint(version, decoder_version, sources) do
    source_digests = Enum.map(sources, &:crypto.hash(:sha256, &1))
    payload = :erlang.term_to_binary({decoder_version, version, source_digests})
    payload |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp tag_name(name), do: name |> String.downcase() |> String.to_atom()
end
