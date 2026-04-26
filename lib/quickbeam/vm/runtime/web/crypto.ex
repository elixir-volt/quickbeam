defmodule QuickBEAM.VM.Runtime.Web.Crypto do
  @moduledoc "crypto object builtin for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import Bitwise
  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1]

  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.Web.SubtleCrypto

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{"crypto" => crypto_object()}
  end

  defp crypto_object do
    object do
      method "getRandomValues" do
        arr = arg(args, 0, nil)

        len =
          case Get.get(arr, "length") do
            n when is_integer(n) -> n
            n when is_float(n) -> trunc(n)
            _ -> 0
          end

        if len > 65_536 do
          JSThrow.type_error!(
            "Failed to execute 'getRandomValues' on 'Crypto': The ArrayBufferView's byte length (#{len}) exceeds the number of bytes of entropy available via this API (65_536)."
          )
        end

        if len > 0 do
          bytes = :crypto.strong_rand_bytes(len)

          for i <- 0..(len - 1) do
            Put.put_element(arr, i, :binary.at(bytes, i))
          end
        end

        arr
      end

      method "randomUUID" do
        <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> =
          :crypto.strong_rand_bytes(16)

        <<c1, c2>> = c
        c_fixed = <<(c1 &&& 0x0F) ||| 0x40, c2>>
        <<d1, d2>> = d
        d_fixed = <<(d1 &&& 0x3F) ||| 0x80, d2>>

        [a, b, c_fixed, d_fixed, e]
        |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
      end

      prop("subtle", SubtleCrypto.build_subtle())
    end
  end
end
