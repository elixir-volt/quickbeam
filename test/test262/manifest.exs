[
  revision: "d1d583db95a521218f3eb8341a887fd63eda8ff1",
  minimum_pass_rate: 0.85,
  known_failures: %{
    "language/expressions/object/setter-prop-desc.js" => %{
      category: :harness_incompatibility,
      reason: "propertyHelper.js requires Object.getOwnPropertyNames and broader Function methods"
    },
    "language/expressions/instanceof/S11.8.6_A2.1_T2.js" => %{
      category: :interpreter_bug,
      reason: "generated ReferenceError values do not yet carry constructor identity"
    }
  },
  tests: [
    "built-ins/Array/isArray/15.4.3.2-1-1.js",
    "built-ins/Array/isArray/15.4.3.2-1-2.js",
    "built-ins/Array/isArray/15.4.3.2-1-3.js",
    "built-ins/Array/isArray/15.4.3.2-1-4.js",
    "built-ins/Array/isArray/15.4.3.2-1-5.js",
    "built-ins/Array/isArray/15.4.3.2-2-1.js",
    "built-ins/Object/keys/15.2.3.14-1-1.js",
    "built-ins/Object/keys/return-order.js",
    "built-ins/Object/setPrototypeOf/success.js",
    "built-ins/String/prototype/charCodeAt/pos-rounding.js",
    "built-ins/String/prototype/slice/S15.5.4.13_A2_T1.js",
    "built-ins/String/prototype/slice/S15.5.4.13_A2_T2.js",
    "language/expressions/object/prop-dup-get-get.js",
    "language/expressions/object/prop-dup-get-set-get.js",
    "language/expressions/object/prop-dup-set-get-set.js",
    "language/expressions/object/setter-prop-desc.js",
    "language/expressions/instanceof/S11.8.6_A2.1_T1.js",
    "language/expressions/instanceof/S11.8.6_A2.1_T2.js",
    "built-ins/Promise/resolve/resolve-thenable.js",
    "built-ins/Promise/resolve/resolve-poisoned-then.js",
    "built-ins/Promise/prototype/then/deferred-is-resolved-value.js",
    "built-ins/Promise/prototype/finally/resolution-value-no-override.js"
  ]
]
