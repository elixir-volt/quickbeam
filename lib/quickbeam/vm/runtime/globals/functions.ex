defmodule QuickBEAM.VM.Runtime.Globals.Functions do
  @moduledoc "Implementations for global JavaScript functions such as `eval`, `require`, and `queueMicrotask`."

  alias QuickBEAM.VM.Execution.Eval
  alias QuickBEAM.VM.{Heap, RuntimeState}
  alias QuickBEAM.VM.JSThrow

  @doc "Implements global `eval` for source strings by compiling and evaluating them in the current runtime."
  def js_eval([code | _], _) when is_binary(code) do
    ctx = RuntimeState.current()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, value} <- Eval.compile_and_eval(pid, code) do
      value
    else
      %{runtime_pid: nil} -> eval_without_runtime(code)
      nil -> eval_without_runtime(code)
      {:error, {:js_throw, value}} -> throw({:js_throw, value})
      {:error, %{message: msg}} -> JSThrow.syntax_error!(msg)
      {:error, msg} when is_binary(msg) -> JSThrow.syntax_error!(msg)
      _ -> :undefined
    end
  end

  def js_eval(_, _), do: :undefined

  def js_eval_global([code | _], {:obj, ref}) when is_binary(code) do
    ctx = RuntimeState.current()
    globals = Heap.get_obj(ref, %{})
    pre_globals = Heap.get_persistent_globals()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, value} <- Eval.compile_and_eval(pid, code, globals: globals) do
      realm_updates = Heap.get_persistent_globals() || %{}
      Heap.put_persistent_globals(pre_globals)
      Heap.put_obj(ref, Map.merge(globals, realm_updates))
      value
    else
      {:error, {:js_throw, value}} -> throw({:js_throw, value})
      {:error, %{message: msg}} -> JSThrow.syntax_error!(msg)
      {:error, msg} when is_binary(msg) -> JSThrow.syntax_error!(msg)
      _ -> :undefined
    end
  end

  def js_eval_global(_, _), do: :undefined

  def decode_uri([value | _], _), do: decode_uri_string(to_string_value(value), :uri)
  def decode_uri(_, _), do: :undefined

  def decode_uri_component([value | _], _),
    do: decode_uri_string(to_string_value(value), :component)

  def decode_uri_component(_, _), do: :undefined

  def encode_uri([value | _], _), do: URI.encode(to_string_value(value), &URI.char_unreserved?/1)
  def encode_uri(_, _), do: :undefined

  def encode_uri_component([value | _], _), do: URI.encode_www_form(to_string_value(value))
  def encode_uri_component(_, _), do: :undefined

  defp to_string_value(value), do: QuickBEAM.VM.Semantics.Values.stringify(value)

  @decode_uri_reserved MapSet.new(~c";,/?:@&=+$#")

  defp decode_uri_string(string, mode) do
    string
    |> decode_uri_bytes(mode, [])
    |> IO.iodata_to_binary()
  end

  defp decode_uri_bytes(<<>>, _mode, acc), do: Enum.reverse(acc)

  defp decode_uri_bytes(<<"%", rest::binary>>, mode, acc) do
    {encoded, bytes, rest} = collect_percent_bytes(<<"%", rest::binary>>, [], [])
    decoded = decode_percent_bytes!(bytes)

    output =
      if mode == :uri and reserved_decoded?(decoded) do
        encoded
      else
        decoded
      end

    decode_uri_bytes(rest, mode, [output | acc])
  end

  defp decode_uri_bytes(<<byte, rest::binary>>, mode, acc),
    do: decode_uri_bytes(rest, mode, [<<byte>> | acc])

  defp collect_percent_bytes(<<"%", high, low, rest::binary>>, encoded, bytes) do
    with {:ok, hi} <- hex_value(high),
         {:ok, lo} <- hex_value(low) do
      collect_percent_bytes(rest, [<<"%", high, low>> | encoded], [hi * 16 + lo | bytes])
    else
      :error -> uri_error!()
    end
  end

  defp collect_percent_bytes(<<"%", _rest::binary>>, _encoded, _bytes), do: uri_error!()

  defp collect_percent_bytes(rest, encoded, bytes),
    do: {IO.iodata_to_binary(Enum.reverse(encoded)), Enum.reverse(bytes), rest}

  defp hex_value(byte) when byte in ?0..?9, do: {:ok, byte - ?0}
  defp hex_value(byte) when byte in ?a..?f, do: {:ok, byte - ?a + 10}
  defp hex_value(byte) when byte in ?A..?F, do: {:ok, byte - ?A + 10}
  defp hex_value(_), do: :error

  defp decode_percent_bytes!(bytes) do
    bytes
    |> :binary.list_to_bin()
    |> :unicode.characters_to_binary(:utf8, :utf8)
    |> case do
      binary when is_binary(binary) -> binary
      _ -> uri_error!()
    end
  end

  defp reserved_decoded?(decoded) do
    case String.to_charlist(decoded) do
      [char] -> MapSet.member?(@decode_uri_reserved, char)
      _ -> false
    end
  end

  defp uri_error!, do: throw({:js_throw, Heap.make_error("URI malformed", "URIError")})

  defp eval_without_runtime(code) do
    task =
      Task.async(fn ->
        with {:ok, rt} <- QuickBEAM.start(apis: false) do
          try do
            QuickBEAM.eval(rt, code)
          after
            QuickBEAM.stop(rt)
          end
        end
      end)

    case Task.await(task, 5_000) do
      {:ok, value} -> value
      _ -> :undefined
    end
  rescue
    _ -> :undefined
  end

  @doc "Implements the CommonJS-like `require` global backed by registered VM modules."
  def js_require([name | _], _) do
    case Heap.get_module(name) do
      nil -> JSThrow.error!("Cannot find module '#{name}'")
      exports -> exports
    end
  end

  @doc "Implements `queueMicrotask` by enqueuing a callback in the VM microtask queue."
  def queue_microtask([callback | _], _) do
    unless QuickBEAM.VM.Builtin.callable?(callback) do
      JSThrow.type_error!(
        "Failed to execute 'queueMicrotask': The callback provided as parameter 1 is not a function."
      )
    end

    Heap.enqueue_microtask({:resolve, nil, callback, :undefined})
    :undefined
  end
end
