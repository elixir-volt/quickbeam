defmodule RuleEngineTest do
  use ExUnit.Case

  setup do
    start_supervised!(RuleEngine)
    :ok
  end

  test "basic rule evaluation" do
    {:ok, _} =
      RuleEngine.load(:tax, """
        function calculate(price, rate) {
          return { net: price, tax: price * rate, total: price * (1 + rate) }
        }
      """)

    assert {:ok, result} = RuleEngine.call(:tax, "calculate", [100, 0.2])
    assert result["net"] == 100
    assert result["tax"] == 20.0
    assert result["total"] == 120.0
  end

  test "rule with handlers" do
    products = %{
      "SKU-001" => %{"name" => "Widget", "price" => 25.00},
      "SKU-002" => %{"name" => "Gadget", "price" => 75.00}
    }

    {:ok, _} =
      RuleEngine.load(:pricing, """
        async function price_cart(skus) {
          let total = 0
          for (const sku of skus) {
            const product = await Beam.call("lookup", sku)
            if (product) total += product.price
          }
          return total
        }
      """,
        handlers: %{
          "lookup" => fn [sku] -> Map.get(products, sku) end
        }
      )

    assert {:ok, 100} = RuleEngine.call(:pricing, "price_cart", [["SKU-001", "SKU-002"]])
    assert {:ok, 25} = RuleEngine.call(:pricing, "price_cart", [["SKU-001"]])
  end

  test "rules are isolated from each other" do
    {:ok, _} =
      RuleEngine.load(:rule_a, """
        globalThis.secret = "from_a"
        function get() { return globalThis.secret }
      """)

    {:ok, _} =
      RuleEngine.load(:rule_b, """
        function get() { return globalThis.secret }
      """)

    assert {:ok, "from_a"} = RuleEngine.call(:rule_a, "get")
    assert {:ok, nil} = RuleEngine.call(:rule_b, "get")
  end

  test "apis are disabled — no fetch, no require, no process" do
    {:ok, _} =
      RuleEngine.load(:sandbox_check, """
        function check() {
          return {
            fetch: typeof fetch,
            require: typeof require,
            process: typeof process
          }
        }
      """)

    assert {:ok, result} = RuleEngine.call(:sandbox_check, "check")
    assert result["fetch"] == "undefined"
    assert result["require"] == "undefined"
    assert result["process"] == "undefined"
  end

  test "memory limit triggers OOM" do
    {:ok, _} =
      RuleEngine.load(:mem_hog, """
        function exhaust() {
          const arr = []
          while (true) arr.push("x".repeat(1024))
        }
      """, memory_limit: 2 * 1024 * 1024)

    assert {:error, %QuickBEAM.JSError{}} = RuleEngine.call(:mem_hog, "exhaust")
  end

  test "timeout stops infinite loops" do
    {:ok, _} =
      RuleEngine.load(:looper, """
        function spin() { while (true) {} }
      """)

    assert {:error, %QuickBEAM.JSError{message: "interrupted"}} =
             RuleEngine.call(:looper, "spin", [], timeout: 500)
  end

  test "hot reload replaces rule code" do
    {:ok, _} =
      RuleEngine.load(:versioned, """
        function version() { return 1 }
      """)

    assert {:ok, 1} = RuleEngine.call(:versioned, "version")

    {:ok, _} =
      RuleEngine.reload(:versioned, """
        function version() { return 2 }
      """)

    assert {:ok, 2} = RuleEngine.call(:versioned, "version")
  end

  test "reload of unknown rule returns error" do
    assert {:error, :not_found} = RuleEngine.reload(:nonexistent, "function f() {}")
  end

  test "list returns loaded rule IDs" do
    {:ok, _} = RuleEngine.load(:r1, "")
    {:ok, _} = RuleEngine.load(:r2, "")

    rules = RuleEngine.list()
    assert :r1 in rules
    assert :r2 in rules
  end

  test "unload removes a rule" do
    {:ok, _} = RuleEngine.load(:temp, "function hi() { return 'hello' }")
    assert {:ok, "hello"} = RuleEngine.call(:temp, "hi")

    :ok = RuleEngine.unload(:temp)
    assert {:error, :not_found} = RuleEngine.unload(:temp)
  end

  test "duplicate load returns error" do
    {:ok, _} = RuleEngine.load(:dup, "")
    assert {:error, :already_loaded} = RuleEngine.load(:dup, "")
  end

  test "complex pricing rule with tiers and bundles" do
    {:ok, _} =
      RuleEngine.load(:discount, """
        function apply_discount(cart) {
          const subtotal = cart.items.reduce((sum, i) => sum + i.price * i.qty, 0)

          let rate = 0
          if (subtotal >= 500) rate = 0.15
          else if (subtotal >= 200) rate = 0.10
          else if (subtotal >= 100) rate = 0.05

          const discount = subtotal * rate
          return { subtotal, discount_rate: rate, discount, total: subtotal - discount }
        }
      """)

    cart = %{"items" => [%{"price" => 50, "qty" => 3}, %{"price" => 120, "qty" => 2}]}

    assert {:ok, result} = RuleEngine.call(:discount, "apply_discount", [cart])
    assert result["subtotal"] == 390
    assert result["discount_rate"] == 0.10
    assert result["total"] == 351.0
  end
end
