# Generates test/test262_skip.txt by running all test262 tests through the
# native QuickJS NIF and recording failures.
#
# Usage: MIX_ENV=test mix run test/support/gen_test262_skip.exs

categories = ~w(
  language/expressions/addition language/expressions/subtraction
  language/expressions/multiplication language/expressions/division
  language/expressions/modulus language/expressions/typeof
  language/expressions/void language/expressions/comma
  language/expressions/conditional language/expressions/logical-and
  language/expressions/logical-or language/expressions/logical-not
  language/expressions/equals language/expressions/does-not-equals
  language/expressions/strict-equals language/expressions/strict-does-not-equal
  language/expressions/greater-than language/expressions/greater-than-or-equal
  language/expressions/less-than language/expressions/less-than-or-equal
  language/expressions/bitwise-and language/expressions/bitwise-or
  language/expressions/bitwise-xor language/expressions/bitwise-not
  language/expressions/left-shift language/expressions/right-shift
  language/expressions/unsigned-right-shift
  language/expressions/in language/expressions/instanceof
  language/expressions/new language/expressions/this
  language/expressions/delete
  language/expressions/prefix-increment language/expressions/prefix-decrement
  language/expressions/postfix-increment language/expressions/postfix-decrement
  language/expressions/unary-minus language/expressions/unary-plus
  language/statements/if language/statements/return language/statements/switch
  language/statements/throw language/statements/try
  language/statements/do-while language/statements/while
  language/statements/for language/statements/for-in
  language/statements/break language/statements/continue
  language/statements/block language/statements/empty
  language/statements/labeled language/statements/with
)

{:ok, rt} = QuickBEAM.start()
failures = QuickBEAM.Test262.build_nif_failures(rt, categories)
QuickBEAM.stop(rt)

lines = failures |> Enum.sort()
out = Path.expand("../test262_skip.txt", __DIR__)

content = """
# QuickJS NIF failures — tests that fail on native QuickJS,
# so they cannot be tested on the BEAM VM either.
# Regenerate: MIX_ENV=test mix run test/support/gen_test262_skip.exs
# #{length(lines)} entries
#{Enum.join(lines, "\n")}
"""

File.write!(out, content)
IO.puts("Wrote #{length(lines)} entries to #{out}")
