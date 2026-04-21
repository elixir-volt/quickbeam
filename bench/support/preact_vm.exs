defmodule Bench.PreactVM do
  alias QuickBEAM.Bytecode
  alias QuickBEAM.JS.Bundler
  alias QuickBEAM.VM.{Compiler, Heap, Interpreter}

  def bundle_source! do
    entry = Path.expand("../assets/preact_ssr.js", __DIR__)
    :ok = ensure_bench_deps!()
    {:ok, bundled} = Bundler.bundle_file(entry, format: :esm)
    bundled
  end

  def props do
    %{
      "title" => "Featured products",
      "subtitle" => "Preact component tree benchmark",
      "selectedId" => 18,
      "footerNote" => "Updated every 5 minutes",
      "products" =>
        for id <- 1..48 do
          %{
            "id" => id,
            "name" => "Product #{id}",
            "description" =>
              "A compact component benchmark payload with nested props, tags, and metadata.",
            "priceCents" => 1_995 + id * 37,
            "inStock" => rem(id, 5) != 0,
            "rating" => 3.5 + rem(id, 7) * 0.2,
            "tags" => ["fast", "vm", if(rem(id, 2) == 0, do: "featured", else: "sale")]
          }
        end
    }
  end

  def start_runtime, do: QuickBEAM.start(apis: false, mode: :beam)

  def build_case!(rt, source, props) do
    {:ok, bytecode} = QuickBEAM.compile(rt, source)
    {:ok, parsed} = QuickBEAM.VM.Bytecode.decode(bytecode)
    cache_function_atoms(parsed)

    :ok = QuickBEAM.set_global(rt, "__bench_props", props, mode: :beam)
    js_props = Heap.get_persistent_globals() |> Map.fetch!("__bench_props")

    {:ok, {:closure, _, render_fun} = render_app} = QuickBEAM.eval(rt, source, mode: :beam)

    %{parsed: parsed, render_app: render_app, render_fun: render_fun, js_props: js_props}
  end

  def ensure_case!(source, props) do
    key = {:preact_vm_case, :erlang.phash2(source)}

    case Process.get(key) do
      %{render_app: _render_app, js_props: _js_props} = case_data ->
        case_data

      _ ->
        {:ok, rt} = start_runtime()
        case_data = Map.put(build_case!(rt, source, props), :rt, rt)
        warmup(case_data.render_app, case_data.js_props)
        Process.put(key, case_data)
        case_data
    end
  end

  def run_interpreter!(render_app, props),
    do: Interpreter.invoke(render_app, [props], 1_000_000_000)

  def run_compiler!(render_app, props) do
    {:ok, result} = Compiler.invoke(render_app, [props])
    result
  end

  def warmup(render_app, props, iterations \\ 20) do
    Enum.each(1..iterations, fn _ -> run_compiler!(render_app, props) end)
  end

  def beam_disasm!(fun) do
    {:ok, beam} = Compiler.disasm(fun)
    beam
  end

  def find_function(%Bytecode{} = root, name) do
    cond do
      root.name == name ->
        root

      true ->
        Enum.find_value(root.cpool, fn
          %Bytecode{} = inner -> find_function(inner, name)
          _ -> nil
        end)
    end
  end

  def find_vm_function(%QuickBEAM.VM.Bytecode.Function{} = root, pred) do
    cond do
      pred.(root) ->
        root

      true ->
        Enum.find_value(root.constants, fn
          %QuickBEAM.VM.Bytecode.Function{} = inner -> find_vm_function(inner, pred)
          _ -> nil
        end)
    end
  end

  def opcode_histogram(%Bytecode{} = fun) do
    fun.opcodes
    |> Enum.frequencies_by(&elem(&1, 1))
    |> Enum.sort_by(fn {_op, count} -> -count end)
  end

  def opcode_histogram(%QuickBEAM.VM.Bytecode.Function{} = fun) do
    {:ok, ops} = QuickBEAM.VM.Decoder.decode(fun.byte_code, fun.arg_count)

    ops
    |> Enum.frequencies_by(fn {op, _args} -> elem(QuickBEAM.VM.Opcodes.info(op), 0) end)
    |> Enum.sort_by(fn {_op, count} -> -count end)
  end

  defp cache_function_atoms(parsed) do
    cache_fun =
      fn
        %QuickBEAM.VM.Bytecode.Function{} = fun, atoms, recur ->
          Process.put({:qb_fn_atoms, fun.byte_code}, atoms)

          Enum.each(fun.constants, fn
            %QuickBEAM.VM.Bytecode.Function{} = inner -> recur.(inner, atoms, recur)
            _ -> :ok
          end)

        _other, _atoms, _recur ->
          :ok
      end

    cache_fun.(parsed.value, parsed.atoms, cache_fun)
  end

  defp ensure_bench_deps! do
    if "preact" in NPM.NodeModules.installed() do
      :ok
    else
      NPM.install()
    end
  end
end
