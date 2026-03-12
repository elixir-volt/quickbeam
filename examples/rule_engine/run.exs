{:ok, _} = RuleEngine.start_link()

IO.puts("=== Rule Engine Demo ===\n")

# ── 1. Pricing rule: tier-based discounts ──

IO.puts("── Pricing Rule ──")

products = %{
  "WIDGET" => %{"name" => "Widget", "price" => 25.00, "category" => "parts"},
  "GADGET" => %{"name" => "Gadget", "price" => 75.00, "category" => "electronics"},
  "BUNDLE-A" => %{"name" => "Starter Kit", "price" => 150.00, "category" => "bundles"}
}

{:ok, _} =
  RuleEngine.load(:pricing, """
    async function price_cart(cart) {
      let subtotal = 0
      const lines = []

      for (const item of cart.items) {
        const product = await Beam.call("lookup", item.sku)
        if (!product) continue
        const line_total = product.price * item.qty
        subtotal += line_total
        lines.push({ sku: item.sku, name: product.name, unit: product.price, qty: item.qty, line_total })
      }

      // Tier-based discount
      let discount_rate = 0
      let tier = "standard"
      if (subtotal >= 500) { discount_rate = 0.15; tier = "gold" }
      else if (subtotal >= 200) { discount_rate = 0.10; tier = "silver" }
      else if (subtotal >= 100) { discount_rate = 0.05; tier = "bronze" }

      const discount = subtotal * discount_rate
      return { lines, subtotal, tier, discount_rate, discount, total: subtotal - discount }
    }
  """,
    handlers: %{
      "lookup" => fn [sku] -> Map.get(products, sku) end
    }
  )

cart = %{
  "items" => [
    %{"sku" => "WIDGET", "qty" => 4},
    %{"sku" => "GADGET", "qty" => 2},
    %{"sku" => "BUNDLE-A", "qty" => 1}
  ]
}

{:ok, result} = RuleEngine.call(:pricing, "price_cart", [cart])

for line <- result["lines"] do
  IO.puts("  #{line["name"]} × #{line["qty"]} = $#{:erlang.float_to_binary(line["line_total"] / 1, decimals: 2)}")
end

IO.puts("  Subtotal: $#{:erlang.float_to_binary(result["subtotal"] / 1, decimals: 2)}")
IO.puts("  Tier: #{result["tier"]} (#{trunc(result["discount_rate"] * 100)}% off)")
IO.puts("  Discount: -$#{:erlang.float_to_binary(result["discount"] / 1, decimals: 2)}")
IO.puts("  Total: $#{:erlang.float_to_binary(result["total"] / 1, decimals: 2)}")

# ── 2. Validation rule: business constraints ──

IO.puts("\n── Validation Rule ──")

{:ok, _} =
  RuleEngine.load(:validate_order, """
    function validate(order) {
      const errors = []

      if (!order.email || !order.email.includes("@"))
        errors.push("Invalid email address")

      if (!order.items || order.items.length === 0)
        errors.push("Order must have at least one item")

      for (const item of (order.items || [])) {
        if (item.qty <= 0)
          errors.push(`Invalid quantity for ${item.sku}: ${item.qty}`)
        if (item.qty > 100)
          errors.push(`Quantity exceeds limit for ${item.sku}: max 100`)
      }

      if (order.total > 10000)
        errors.push("Order total exceeds $10,000 limit — requires manual approval")

      return { valid: errors.length === 0, errors }
    }
  """)

good_order = %{
  "email" => "alice@example.com",
  "items" => [%{"sku" => "WIDGET", "qty" => 2}],
  "total" => 50
}

bad_order = %{
  "email" => "not-an-email",
  "items" => [%{"sku" => "WIDGET", "qty" => -1}, %{"sku" => "GADGET", "qty" => 200}],
  "total" => 15000
}

{:ok, result} = RuleEngine.call(:validate_order, "validate", [good_order])
IO.puts("  Valid order: #{result["valid"]}")

{:ok, result} = RuleEngine.call(:validate_order, "validate", [bad_order])
IO.puts("  Bad order: #{result["valid"]}")

for err <- result["errors"] do
  IO.puts("    - #{err}")
end

# ── 3. Transform rule: normalize and compute derived fields ──

IO.puts("\n── Transform Rule ──")

{:ok, _} =
  RuleEngine.load(:transform, """
    function normalize_address(addr) {
      const state_abbrevs = {
        "california": "CA", "new york": "NY", "texas": "TX",
        "florida": "FL", "illinois": "IL"
      }

      const state = (addr.state || "").toLowerCase()
      const zip = String(addr.zip || "").padStart(5, "0")

      return {
        line1: (addr.street || "").trim(),
        city: (addr.city || "").trim(),
        state: state_abbrevs[state] || addr.state,
        zip,
        country: "US"
      }
    }

    function enrich_customer(customer) {
      const name_parts = (customer.name || "").trim().split(/\\s+/)
      return {
        ...customer,
        first_name: name_parts[0] || "",
        last_name: name_parts.slice(1).join(" ") || "",
        name_upper: (customer.name || "").toUpperCase(),
        email_domain: (customer.email || "").split("@")[1] || ""
      }
    }
  """)

{:ok, addr} =
  RuleEngine.call(:transform, "normalize_address", [
    %{"street" => "  123 Main St  ", "city" => "San Francisco", "state" => "california", "zip" => "94102"}
  ])

IO.puts("  Address: #{addr["line1"]}, #{addr["city"]}, #{addr["state"]} #{addr["zip"]}")

{:ok, customer} =
  RuleEngine.call(:transform, "enrich_customer", [
    %{"name" => "Jane Doe Smith", "email" => "jane@acme.com"}
  ])

IO.puts("  Customer: #{customer["first_name"]} #{customer["last_name"]} (#{customer["email_domain"]})")

# ── 4. Hot reload: update a rule without restarting ──

IO.puts("\n── Hot Reload ──")

{:ok, _} =
  RuleEngine.load(:shipping, """
    function rate(weight) { return weight * 0.50 }
  """)

{:ok, rate} = RuleEngine.call(:shipping, "rate", [10])
IO.puts("  Shipping v1: $#{:erlang.float_to_binary(rate / 1, decimals: 2)} for 10 lbs")

{:ok, _} =
  RuleEngine.reload(:shipping, """
    function rate(weight) {
      if (weight > 50) return weight * 0.35
      return weight * 0.45
    }
  """)

{:ok, rate} = RuleEngine.call(:shipping, "rate", [10])
IO.puts("  Shipping v2: $#{:erlang.float_to_binary(rate / 1, decimals: 2)} for 10 lbs")

{:ok, rate} = RuleEngine.call(:shipping, "rate", [100])
IO.puts("  Shipping v2: $#{:erlang.float_to_binary(rate / 1, decimals: 2)} for 100 lbs (bulk rate)")

# ── 5. Memory limit ──

IO.puts("\n── Safety: Memory Limit ──")

{:ok, _} =
  RuleEngine.load(:mem_hog, """
    function exhaust() {
      const arr = []
      while (true) arr.push("x".repeat(1024))
    }
  """, memory_limit: 2 * 1024 * 1024)

case RuleEngine.call(:mem_hog, "exhaust") do
  {:error, error} -> IO.puts("  Memory hog stopped: #{inspect(error)}")
end

# ── 6. Timeout ──

IO.puts("\n── Safety: Timeout ──")

{:ok, _} =
  RuleEngine.load(:infinite, """
    function spin() { while (true) {} }
  """)

case RuleEngine.call(:infinite, "spin", [], timeout: 500) do
  {:error, error} -> IO.puts("  Infinite loop stopped: #{error.message}")
end

# ── Summary ──

IO.puts("\nLoaded rules: #{inspect(Enum.sort(RuleEngine.list()))}")
IO.puts("\nDone.")
