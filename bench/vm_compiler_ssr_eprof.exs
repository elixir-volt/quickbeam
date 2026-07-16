Mix.Task.run("app.start")

alias QuickBEAM.VM.Compiler

iterations = String.to_integer(System.get_env("COMPILER_SSR_EPROF_ITERATIONS", "5"))
profile = System.get_env("COMPILER_SSR_EPROF_PROFILE", "pure_v1")

{engine, compiler_profile} =
  case profile do
    "interpreter" -> {:interpreter, :pure_v1}
    "pure_v1" -> {:compiler, :pure_v1}
    "scalar_v1" -> {:compiler, :scalar_v1}
    invalid -> raise "unsupported COMPILER_SSR_EPROF_PROFILE=#{inspect(invalid)}"
  end

{:ok, _compiler} = Compiler.start_link(capacity: 32)

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
  "title" => "Compiler profile",
  "products" => [
    %{"id" => 1, "name" => "Product 1", "inStock" => true, "priceCents" => 1_299}
  ]
}

options = [
  engine: engine,
  compiler_profile: compiler_profile,
  isolation: :caller,
  profile: :ssr,
  handlers: %{"load_props" => fn [] -> props end},
  max_steps: 50_000_000,
  memory_limit: 256_000_000,
  timeout: 5_000
]

expected = QuickBEAM.VM.eval(program, options)
pool = Process.whereis(QuickBEAM.VM.Compiler.ModulePool)

tools_pattern = Path.join([to_string(:code.root_dir()), "lib", "tools-*", "ebin"])
[tools_ebin | _] = Path.wildcard(tools_pattern)
true = :code.add_patha(String.to_charlist(tools_ebin))
{:module, :eprof} = :code.ensure_loaded(:eprof)

:eprof.start()
:eprof.start_profiling([self(), pool])

Enum.each(1..iterations, fn _iteration ->
  ^expected = QuickBEAM.VM.eval(program, options)
end)

:eprof.stop_profiling()

IO.puts(
  "EPROF fixture=vue_ssr engine=#{engine} compiler_profile=#{compiler_profile} iterations=#{iterations}"
)

:eprof.analyze(:total)
:eprof.stop()
GenServer.stop(Compiler.ModulePool)
