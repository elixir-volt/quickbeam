defmodule QuickBEAM.VM.Runtime.Globals.Bindings do
  @moduledoc "Builds global function and small host-object bindings."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1, object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Globals.Numeric
  alias QuickBEAM.VM.Runtime.Globals.Functions

  @doc "Returns non-constructor global function bindings."
  def bindings do
    Map.merge(global_function_bindings(), %{
      "os" => Heap.wrap(%{"platform" => "elixir"}),
      "qjs" => qjs_object(),
      "globalThis" => Runtime.new_object(),
      "NaN" => :nan,
      "Infinity" => :infinity,
      "undefined" => :undefined
    })
  end

  defp global_function_bindings do
    build_methods do
      @ecma "19.2.1"
      method "eval", length: 1, constructable: false do
        Functions.js_eval(args, this)
      end

      @ecma "19.2.2"
      method "isFinite", length: 1, constructable: false do
        Numeric.finite?(args, this)
      end

      @ecma "19.2.3"
      method "isNaN", length: 1, constructable: false do
        Numeric.nan?(args, this)
      end

      @ecma "19.2.4"
      method "parseFloat", length: 1, constructable: false do
        Numeric.parse_float(args, this)
      end

      @ecma "19.2.5"
      method "parseInt", length: 2, constructable: false do
        Numeric.parse_int(args, this)
      end

      @ecma "19.2.6.1"
      method "decodeURI", constructable: false do
        Functions.decode_uri(args, this)
      end

      @ecma "19.2.6.2"
      method "decodeURIComponent", constructable: false do
        Functions.decode_uri_component(args, this)
      end

      @ecma "19.2.6.3"
      method "encodeURI", constructable: false do
        Functions.encode_uri(args, this)
      end

      @ecma "19.2.6.4"
      method "encodeURIComponent", constructable: false do
        Functions.encode_uri_component(args, this)
      end

      method "require", constructable: false do
        Functions.js_require(args, this)
      end

      method "structuredClone", constructable: false do
        structured_clone(args, this)
      end

      method "queueMicrotask", constructable: false do
        Functions.queue_microtask(args, this)
      end

      method "gc", constructable: false do
        :undefined
      end
    end
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
