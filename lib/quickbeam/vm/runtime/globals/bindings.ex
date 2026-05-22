defmodule QuickBEAM.VM.Runtime.Globals.Bindings do
  @moduledoc "Builds global function and small host-object bindings."

  import QuickBEAM.VM.Builtin, only: [object: 1]

  alias QuickBEAM.VM.{Builtin, Heap}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Globals.Numeric
  alias QuickBEAM.VM.Runtime.Globals.Functions

  @doc "Returns non-constructor global function bindings."
  def bindings do
    %{
      "parseInt" => builtin("parseInt", &Numeric.parse_int/2),
      "parseFloat" => builtin("parseFloat", &Numeric.parse_float/2),
      "isNaN" => builtin("isNaN", &Numeric.nan?/2),
      "isFinite" => builtin("isFinite", &Numeric.finite?/2),
      "eval" => builtin("eval", &Functions.js_eval/2),
      "decodeURI" => builtin("decodeURI", &Functions.decode_uri/2),
      "decodeURIComponent" => builtin("decodeURIComponent", &Functions.decode_uri_component/2),
      "encodeURI" => builtin("encodeURI", &Functions.encode_uri/2),
      "encodeURIComponent" => builtin("encodeURIComponent", &Functions.encode_uri_component/2),
      "require" => builtin("require", &Functions.js_require/2),
      "structuredClone" => builtin("structuredClone", &structured_clone/2),
      "queueMicrotask" => builtin("queueMicrotask", &Functions.queue_microtask/2),
      "gc" => builtin("gc", fn _, _ -> :undefined end),
      "os" => Heap.wrap(%{"platform" => "elixir"}),
      "qjs" => qjs_object(),
      "globalThis" => Runtime.new_object(),
      "NaN" => :nan,
      "Infinity" => :infinity,
      "undefined" => :undefined
    }
  end

  defp builtin(name, fun) do
    value = {:builtin, name, fun}
    Builtin.put_builtin_metadata(value, Builtin.meta(name, constructable: false))
  end

  defp structured_clone([val | _], _this), do: QuickBEAM.VM.Runtime.StructuredClone.clone(val)
  defp structured_clone([], _this), do: nil

  defp qjs_object do
    object do
      method "getStringKind" do
        s = hd(args)
        if is_binary(s) and byte_size(s) > 256, do: 1, else: 0
      end
    end
  end
end
