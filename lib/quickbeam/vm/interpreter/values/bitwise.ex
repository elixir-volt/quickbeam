defmodule QuickBEAM.VM.Interpreter.Values.Bitwise do
  @moduledoc "JS bitwise operations: band, bor, bxor, bnot, shl, sar, shr."

  import Bitwise, except: [band: 2, bor: 2, bxor: 2, bnot: 1]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.Interpreter.Values.Coercion

  def band({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.band(a, b)}
  def band({:obj, _} = a, b), do: band(Coercion.to_numeric(a), b)
  def band(a, {:obj, _} = b), do: band(a, Coercion.to_numeric(b))
  def band({:bigint, _}, _), do: throw_bigint_mix_error()
  def band(_, {:bigint, _}), do: throw_bigint_mix_error()
  def band(a, b), do: Bitwise.band(Coercion.to_int32(a), Coercion.to_int32(b))

  def bor({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bor(a, b)}
  def bor({:obj, _} = a, b), do: bor(Coercion.to_numeric(a), b)
  def bor(a, {:obj, _} = b), do: bor(a, Coercion.to_numeric(b))
  def bor({:bigint, _}, _), do: throw_bigint_mix_error()
  def bor(_, {:bigint, _}), do: throw_bigint_mix_error()
  def bor(a, b), do: Bitwise.bor(Coercion.to_int32(a), Coercion.to_int32(b))

  def bxor({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bxor(a, b)}
  def bxor({:obj, _} = a, b), do: bxor(Coercion.to_numeric(a), b)
  def bxor(a, {:obj, _} = b), do: bxor(a, Coercion.to_numeric(b))
  def bxor({:bigint, _}, _), do: throw_bigint_mix_error()
  def bxor(_, {:bigint, _}), do: throw_bigint_mix_error()
  def bxor(a, b), do: Bitwise.bxor(Coercion.to_int32(a), Coercion.to_int32(b))

  def bnot({:bigint, a}), do: {:bigint, -(a + 1)}
  def bnot({:obj, _} = a), do: bnot(Coercion.to_numeric(a))
  def bnot(a), do: Coercion.to_int32(Bitwise.bnot(Coercion.to_int32(a)))

  def shl({:bigint, a}, {:bigint, b}) when b >= 0 and b <= 1_000_000,
    do: {:bigint, Bitwise.bsl(a, b)}

  def shl({:bigint, a}, {:bigint, b}) when b < 0,
    do: {:bigint, Bitwise.bsr(a, -b)}

  def shl({:bigint, _}, {:bigint, _}),
    do: JSThrow.range_error!("Maximum BigInt size exceeded")

  def shl({:obj, _} = a, b), do: shl(Coercion.to_numeric(a), b)
  def shl(a, {:obj, _} = b), do: shl(a, Coercion.to_numeric(b))
  def shl({:bigint, _}, _), do: throw_bigint_mix_error()
  def shl(_, {:bigint, _}), do: throw_bigint_mix_error()

  def shl(a, b),
    do: Coercion.to_int32(Bitwise.bsl(Coercion.to_int32(a), Bitwise.band(Coercion.to_int32(b), 31)))

  def sar({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bsr(a, b)}
  def sar({:obj, _} = a, b), do: sar(Coercion.to_numeric(a), b)
  def sar(a, {:obj, _} = b), do: sar(a, Coercion.to_numeric(b))
  def sar({:bigint, _}, _), do: throw_bigint_mix_error()
  def sar(_, {:bigint, _}), do: throw_bigint_mix_error()
  def sar(a, b), do: Bitwise.bsr(Coercion.to_int32(a), Bitwise.band(Coercion.to_int32(b), 31))

  def shr({:obj, _} = a, b), do: shr(Coercion.to_numeric(a), b)
  def shr(a, {:obj, _} = b), do: shr(a, Coercion.to_numeric(b))

  def shr({:bigint, _}, _),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")}
      )

  def shr(_, {:bigint, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")}
      )

  def shr(a, b) do
    ua = Coercion.to_int32(a) &&& 0xFFFFFFFF
    Bitwise.bsr(ua, Bitwise.band(Coercion.to_int32(b), 31))
  end

  defp throw_bigint_mix_error do
    throw(
      {:js_throw,
       Heap.make_error("Cannot mix BigInt and other types, use explicit conversions", "TypeError")}
    )
  end
end
