output = System.get_env("VM_INTERPRETER_FPROF_OUTPUT", "vm-interpreter.fprof")
trace = output <> ".trace"

tools_ebin =
  :code.root_dir()
  |> to_string()
  |> Path.join("lib/tools-*/ebin")
  |> Path.wildcard()
  |> List.first()

runtime_tools_ebin =
  :code.root_dir()
  |> to_string()
  |> Path.join("lib/runtime_tools-*/ebin")
  |> Path.wildcard()
  |> List.first()

true = :code.add_patha(String.to_charlist(tools_ebin))
true = :code.add_patha(String.to_charlist(runtime_tools_ebin))
{:module, :dbg} = :code.ensure_loaded(:dbg)
{:module, :fprof} = :code.ensure_loaded(:fprof)

{:ok, source} =
  QuickBEAM.JS.bundle_file("test/fixtures/vm/vue_ssr.js",
    format: :esm,
    minify: true,
    define: %{
      "__VUE_OPTIONS_API__" => "true",
      "__VUE_PROD_DEVTOOLS__" => "false",
      "__VUE_PROD_HYDRATION_MISMATCH_DETAILS__" => "false",
      "process.env.NODE_ENV" => ~s("production")
    }
  )

{:ok, program} = QuickBEAM.VM.compile(source, filename: "test/fixtures/vm/vue_ssr.js")

props = %{
  "title" => "Profile",
  "products" => [
    %{"id" => 1, "name" => "Product 1", "inStock" => true, "priceCents" => 1299}
  ]
}

handler = fn [] -> props end

opts = [
  profile: :ssr,
  handlers: %{"load_props" => handler},
  max_steps: 50_000_000,
  memory_limit: 256_000_000,
  timeout: 5_000,
  isolation: :caller
]

{:ok, _html} = QuickBEAM.VM.Evaluator.eval(program, opts)

:fprof.apply(fn -> QuickBEAM.VM.Evaluator.eval(program, opts) end, [],
  file: String.to_charlist(trace)
)

:fprof.profile(file: String.to_charlist(trace))

:fprof.analyse(
  dest: String.to_charlist(output),
  callers: true,
  sort: :own,
  totals: true,
  details: true
)

IO.puts("wrote #{output}")
