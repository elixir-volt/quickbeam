defmodule QuickBEAM.VM.Test262Test do
  use ExUnit.Case, async: true

  @moduletag :test262

  @categories ~w(
    language/expressions/addition
    language/expressions/subtraction
    language/expressions/multiplication
    language/expressions/division
    language/expressions/modulus
    language/expressions/typeof
    language/expressions/void
    language/expressions/comma
    language/expressions/conditional
    language/expressions/logical-and
    language/expressions/logical-or
    language/expressions/logical-not
    language/expressions/equals
    language/expressions/does-not-equals
    language/expressions/strict-equals
    language/expressions/strict-does-not-equal
    language/expressions/greater-than
    language/expressions/greater-than-or-equal
    language/expressions/less-than
    language/expressions/less-than-or-equal
    language/expressions/bitwise-and
    language/expressions/bitwise-or
    language/expressions/bitwise-xor
    language/expressions/bitwise-not
    language/expressions/left-shift
    language/expressions/right-shift
    language/expressions/unsigned-right-shift
    language/expressions/in
    language/expressions/instanceof
    language/expressions/new
    language/expressions/this
    language/expressions/delete
    language/expressions/prefix-increment
    language/expressions/prefix-decrement
    language/expressions/postfix-increment
    language/expressions/postfix-decrement
    language/expressions/unary-minus
    language/expressions/unary-plus
    language/statements/if
    language/statements/return
    language/statements/switch
    language/statements/throw
    language/statements/try
    language/statements/do-while
    language/statements/while
    language/statements/for
    language/statements/for-in
    language/statements/break
    language/statements/continue
    language/statements/block
    language/statements/empty
    language/statements/labeled
    language/statements/with
  )

  if QuickBEAM.Test262.available?() do
    @skip_list QuickBEAM.Test262.load_skip_list()

    for category <- @categories, file <- QuickBEAM.Test262.find_tests(category) do
      source = File.read!(file)
      relative = QuickBEAM.Test262.relative_path(file)
      meta = QuickBEAM.Test262.parse_metadata(source)
      flags = Map.get(meta, "flags", [])
      includes = Map.get(meta, "includes", [])
      negative = meta["negative"]

      skip =
        cond do
          "async" in flags -> "async"
          "module" in flags -> "module"
          MapSet.member?(@skip_list, relative) -> "quickjs nif"
          true -> nil
        end

      if skip do
        @tag skip: skip
        test "test262 #{relative}" do
        end
      else
        @tag timeout: 5_000
        test "test262 #{relative}", ctx do
          harness = QuickBEAM.Test262.harness_source(unquote(includes))
          source = unquote(source)
          wrapped = "(function(){" <> harness <> "\n" <> source <> "\n})()"

          result =
            try do
              QuickBEAM.eval(ctx.rt, wrapped, mode: :beam)
            catch
              :throw, {:js_throw, err} -> {:error, err}
            end

          case {result, unquote(negative != nil)} do
            {{:ok, _}, false} -> :ok
            {{:error, _}, true} -> :ok
            {{:ok, _}, true} -> flunk("Expected error but test passed")
            {{:error, %{message: msg}}, _} -> flunk("JS: #{msg}")
            {{:error, err}, _} -> flunk("Error: #{inspect(err, limit: 200)}")
          end
        end
      end
    end
  end

  setup do
    QuickBEAM.VM.Heap.reset()
    {:ok, rt} = QuickBEAM.start(apis: false, mode: :beam)
    %{rt: rt}
  end
end
