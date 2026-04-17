defmodule QuickBEAM.BeamVM.Runtime.RegExp do
  alias QuickBEAM.BeamVM.Heap
  @moduledoc "RegExp prototype methods."

  def proto_property("test"), do: {:builtin, "test", fn args, this -> test(this, args) end}
  def proto_property("exec"), do: {:builtin, "exec", fn args, this -> exec(this, args) end}
  def proto_property("source"), do: {:builtin, "source", fn _args, this -> source(this) end}
  def proto_property("flags"), do: {:builtin, "flags", fn _args, this -> flags(this) end}
  def proto_property("toString"), do: {:builtin, "toString", fn _args, this -> regexp_to_string(this) end}
  def proto_property(_), do: :undefined

  defp test({:regexp, _flags, source}, [s | _]) when is_binary(source) and is_binary(s) do
    case Regex.compile(source) do
      {:ok, re} -> Regex.match?(re, s)
      _ -> false
    end
  end
  defp test(_, _), do: false

  defp exec({:regexp, _flags, source}, [s | _]) when is_binary(source) and is_binary(s) do
    case Regex.compile(source) do
      {:ok, re} ->
        case Regex.run(re, s, return: :index) do
          nil -> nil
          indices ->
            result = Enum.map(indices, fn {start, len} -> String.slice(s, start, len) end)
            ref = make_ref()
            Heap.put_obj(ref, result)
            {:obj, ref}
        end
      _ -> nil
    end
  end
  defp exec(_, _), do: nil

  defp source({:regexp, _, src}), do: src
  defp source(_), do: "(?:)"
  defp flags({:regexp, f, _}), do: f || ""
  defp flags(_), do: ""
  defp regexp_to_string({:regexp, f, src}), do: "/#{src}/#{f || ""}"
end
