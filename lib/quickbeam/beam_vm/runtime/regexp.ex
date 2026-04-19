defmodule QuickBEAM.BeamVM.Runtime.RegExp do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime.Property

  proto "test" do
    test(this, args)
  end

  proto "exec" do
    exec(this, args)
  end

  proto "toString" do
    regexp_to_string(this)
  end

  def nif_exec(bytecode, str, last_index) when is_binary(bytecode) and is_binary(str) do
    raw_bc = utf8_to_latin1(bytecode)
    # Unicode regexes expect UTF-8 input; non-unicode expect Latin-1
    flags =
      if byte_size(bytecode) >= 2,
        do: :binary.at(bytecode, 0) + :binary.at(bytecode, 1) * 256,
        else: 0

    is_unicode = Bitwise.band(flags, 0x10) != 0
    raw_str = if is_unicode, do: str, else: utf8_to_latin1(str)

    case QuickBEAM.Native.regexp_exec(raw_bc, raw_str, last_index) do
      nil ->
        nil

      captures when is_list(captures) ->
        Enum.map(captures, fn
          {start, end_off} -> {start, end_off - start}
          nil -> nil
        end)
    end
  end

  def nif_exec(_, _, _), do: nil

  defp test({:regexp, bytecode, _source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    nif_exec(bytecode, s, 0) != nil
  end

  defp test(_, _), do: false

  defp exec({:regexp, bytecode, _source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    case nif_exec(bytecode, s, 0) do
      nil ->
        nil

      captures ->
        strings =
          Enum.map(captures, fn
            {start, len} -> String.slice(s, start, len)
            nil -> :undefined
          end)

        match_start =
          case hd(captures) do
            {start, _} -> start
            _ -> 0
          end

        result_list = strings
        ref = make_ref()

        map =
          strings
          |> Enum.with_index()
          |> Enum.into(%{}, fn {v, i} -> {Integer.to_string(i), v} end)
          |> Map.merge(%{
            "index" => match_start,
            "input" => s,
            "groups" => :undefined,
            "length" => length(strings),
            "toString" => {:builtin, "toString", fn _, _ ->
              Enum.map_join(result_list, ",", fn
                :undefined -> ""
                v -> QuickBEAM.BeamVM.Runtime.stringify(v)
              end)
            end}
          })

        Heap.put_obj(ref, map)
        {:obj, ref}
    end
  end

  defp exec(_, _), do: nil

  defp regexp_to_string({:regexp, bytecode, source}) do
    flags = Property.regexp_flags(bytecode)
    "/#{source}/#{flags}"
  end

  defp regexp_to_string(_), do: "/(?:)/"

  defp utf8_to_latin1(bin) do
    bin
    |> :unicode.characters_to_list(:utf8)
    |> Enum.map(fn cp -> Bitwise.band(cp, 0xFF) end)
    |> :erlang.list_to_binary()
  rescue
    _ -> bin
  end
end
