defmodule QuickBEAM.BeamVM.Runtime.RegExp do
  alias QuickBEAM.BeamVM.Heap
  @moduledoc "RegExp prototype methods."

  def proto_property("test"), do: {:builtin, "test", fn args, this -> test(this, args) end}
  def proto_property("exec"), do: {:builtin, "exec", fn args, this -> exec(this, args) end}
  def proto_property("source"), do: {:builtin, "source", fn _args, this -> source(this) end}
  def proto_property("flags"), do: {:builtin, "flags", fn _args, this -> flags(this) end}
  def proto_property("toString"), do: {:builtin, "toString", fn _args, this -> regexp_to_string(this) end}
  def proto_property(_), do: :undefined

  defp test({:regexp, pat, _}, [s | _]) when is_binary(pat) and is_binary(s) do
    String.match?(s, Regex.compile!(pat))
  end
  defp test(_, _), do: false

  defp exec({:regexp, pat, flags}, [s | _]) when is_binary(pat) and is_binary(s) do
    regex = Regex.compile!(pat, if(is_binary(flags) and String.contains?(flags, "g"), do: "g", else: ""))
    case Regex.run(regex, s, return: :index) do
      nil -> nil
      matches ->
        result = Enum.map(matches, fn {start, len} -> String.slice(s, start, len) end)
        ref = make_ref()
        Heap.put_obj(ref, %{
          "0" => hd(result),
          "index" => elem(hd(matches), 0),
          "input" => s,
          "groups" => :undefined,
          "length" => length(result)
        })
        {:obj, ref}
    end
  end
  defp exec(_, _), do: nil

  defp source({:regexp, pat, _}), do: pat
  defp source(_), do: "(?:)"
  defp flags({:regexp, _, f}), do: f || ""
  defp flags(_), do: ""
  defp regexp_to_string({:regexp, pat, f}), do: "/#{pat}/#{f || ""}"
end
