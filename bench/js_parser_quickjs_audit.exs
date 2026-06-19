Code.require_file("support/test262_files.exs", __DIR__)

Mix.Task.run("app.start")

defmodule Bench.JSParserQuickJSAudit do
  @moduledoc false

  def run do
    files =
      Bench.Test262Files.sample(
        offset: Bench.Support.env_integer("AUDIT_OFFSET", 28_000),
        limit: Bench.Support.env_integer("AUDIT_LIMIT", 2_000),
        include_negative?: true
      )

    {:ok, rt} = QuickBEAM.start(apis: false)

    mismatches =
      try do
        files
        |> Enum.reduce([], fn file, acc -> audit_file(rt, file, acc) end)
        |> Enum.reverse()
      after
        QuickBEAM.stop(rt)
      end

    IO.puts(
      "quickjs_acceptance_files=#{length(files)} quickjs_acceptance_mismatches=#{length(mismatches)}"
    )

    Enum.each(Enum.take(mismatches, 80), &print_mismatch/1)

    Bench.Support.metrics(
      quickjs_acceptance_files: length(files),
      quickjs_acceptance_mismatches: length(mismatches)
    )
  end

  defp audit_file(rt, file, acc) do
    source = File.read!(file)
    meta = Bench.Test262Files.metadata(source)

    if Bench.Test262Files.module?(file, source) do
      acc
    else
      quickjs = quickjs_compile(rt, source)
      parser = parser_parse(source)

      if quickjs == :ok == (parser == :ok) do
        acc
      else
        [
          %{file: file, quickjs: quickjs, parser: parser, negative_phase: meta.negative_phase}
          | acc
        ]
      end
    end
  end

  defp quickjs_compile(rt, source) do
    case QuickBEAM.compile(rt, source) do
      {:ok, _bytecode} -> :ok
      {:error, %QuickBEAM.JS.Error{name: name, message: message}} -> {:error, name, message}
    end
  end

  defp parser_parse(source) do
    case QuickBEAM.JS.Parser.parse(source) do
      {:ok, _program} -> :ok
      {:error, _program, errors} -> {:error, Enum.map(errors, & &1.message)}
    end
  end

  defp print_mismatch(mismatch) do
    IO.puts("MISMATCH #{mismatch.file}")
    IO.puts("  negative_phase=#{inspect(mismatch.negative_phase)}")
    IO.puts("  quickjs=#{inspect(mismatch.quickjs, limit: :infinity)}")
    IO.puts("  parser=#{inspect(mismatch.parser, limit: :infinity)}")
  end
end

Bench.JSParserQuickJSAudit.run()
