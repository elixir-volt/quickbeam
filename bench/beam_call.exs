# Benchmark 3: JS → BEAM call (beam.callSync)
#
# JS calls into BEAM, gets a result back. QuickJSEx cannot do this —
# this benchmark shows what the bridge costs in the reverse direction.

{:ok, qb} =
  QuickBEAM.start(
    handlers: %{
      "echo" => fn [x] -> x end,
      "compute" => fn [a, b] -> a * b + 1 end
    }
  )

{:ok, _} =
  QuickBEAM.eval(qb, """
  function echo_via_beam(x) {
    return beam.callSync("echo", x);
  }

  function compute_via_beam(a, b) {
    return beam.callSync("compute", a, b);
  }

  function pure_compute(a, b) {
    return a * b + 1;
  }
  """)

Benchee.run(
  %{
    "beam.callSync — echo" => fn -> {:ok, 42} = QuickBEAM.call(qb, "echo_via_beam", [42]) end,
    "beam.callSync — compute" => fn -> {:ok, 43} = QuickBEAM.call(qb, "compute_via_beam", [6, 7]) end,
    "pure JS — same compute" => fn -> {:ok, 43} = QuickBEAM.call(qb, "pure_compute", [6, 7]) end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)

QuickBEAM.stop(qb)
