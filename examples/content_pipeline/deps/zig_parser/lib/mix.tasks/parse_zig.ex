defmodule Mix.Tasks.ParseZig do
  use Mix.Task

  def run([file]) do
    file
    |> Path.absname()
    |> File.read!()
    |> Zig.Parser.parse()
    |> IO.inspect()

    :ok
  end
end
