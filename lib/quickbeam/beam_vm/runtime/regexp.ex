defmodule QuickBEAM.BeamVM.Runtime.RegExp do
  alias QuickBEAM.BeamVM.Heap

  def proto_property("test"), do: {:builtin, "test", fn args, this -> test(this, args) end}
  def proto_property("exec"), do: {:builtin, "exec", fn args, this -> exec(this, args) end}
  def proto_property("toString"), do: {:builtin, "toString", fn _args, this -> regexp_to_string(this) end}
  def proto_property(_), do: :undefined

  def compile_pattern(source) when is_binary(source) do
    case :persistent_term.get({__MODULE__, source}, nil) do
      nil ->
        case Regex.compile(source) do
          {:ok, re} ->
            :persistent_term.put({__MODULE__, source}, {:ok, re})
            {:ok, re}
          error ->
            error
        end
      cached ->
        cached
    end
  end

  defp test({:regexp, _bytecode, source}, [s | _]) when is_binary(source) and is_binary(s) do
    case compile_pattern(source) do
      {:ok, re} -> Regex.match?(re, s)
      _ -> false
    end
  end
  defp test(_, _), do: false

  defp exec({:regexp, _bytecode, source}, [s | _]) when is_binary(source) and is_binary(s) do
    case compile_pattern(source) do
      {:ok, re} ->
        case Regex.run(re, s, return: :index) do
          nil -> nil
          indices ->
            strings = Enum.map(indices, fn {start, len} -> String.slice(s, start, len) end)
            {match_start, _} = hd(indices)
            ref = make_ref()
            map = strings
              |> Enum.with_index()
              |> Enum.into(%{}, fn {v, i} -> {Integer.to_string(i), v} end)
              |> Map.merge(%{
                "index" => match_start,
                "input" => s,
                "groups" => :undefined,
                "length" => length(strings)
              })
            Heap.put_obj(ref, map)
            {:obj, ref}
        end
      _ -> nil
    end
  end
  defp exec(_, _), do: nil

  defp regexp_to_string({:regexp, bytecode, source}) do
    flags = QuickBEAM.BeamVM.Runtime.extract_regexp_flags(bytecode)
    "/#{source}/#{flags}"
  end
  defp regexp_to_string(_), do: "/(?:)/"
end
