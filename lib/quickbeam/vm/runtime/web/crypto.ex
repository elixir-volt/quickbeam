defmodule QuickBEAM.VM.Runtime.Web.Crypto do
  @moduledoc "crypto object builtin for BEAM mode."

  import Bitwise
  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.Web.SubtleCrypto

  def bindings do
    %{"crypto" => crypto_object()}
  end

  defp crypto_object do
    build_object do
      method "getRandomValues" do
        [arr | _] = args

        len =
          case Get.get(arr, "length") do
            n when is_integer(n) -> n
            n when is_float(n) -> trunc(n)
            _ -> 0
          end

        if len > 65_536 do
          JSThrow.type_error!("Failed to execute 'getRandomValues' on 'Crypto': The ArrayBufferView's byte length (#{len}) exceeds the number of bytes of entropy available via this API (65_536).")
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
        <<b0::32, b1::16, _::4, b2::12, _::2, b3::14, b4::48>> =
          :crypto.strong_rand_bytes(16)

        :io_lib.format(
          "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
          [b0, b1, b2, 0x8000 ||| b3, b4]
        )
        |> IO.iodata_to_binary()
      end

      val("subtle", SubtleCrypto.build_subtle())
    end
  end
end
