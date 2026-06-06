defmodule QuickBEAM.VM.Runtime.Globals.Functions do
  @moduledoc "Implementations for global JavaScript functions such as `eval`, `require`, and `queueMicrotask`."

  alias QuickBEAM.VM.Execution.Eval, as: ExecutionEval
  alias QuickBEAM.VM.{Heap, RuntimeState}
  alias QuickBEAM.VM.JSThrow

  @doc "Implements global `eval` for source strings by compiling and evaluating them in the current runtime."
  def js_eval([code | _], _) when is_binary(code) do
    ctx = RuntimeState.current()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, value} <- ExecutionEval.compile_and_eval(pid, code) do
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
         {:ok, value} <- ExecutionEval.compile_and_eval(pid, code, globals: globals) do
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

  def encode_uri([value | _], _), do: encode_uri_string(to_string_value(value), :uri)
  def encode_uri(_, _), do: :undefined

  def encode_uri_component([value | _], _),
    do: encode_uri_string(to_string_value(value), :component)

  def encode_uri_component(_, _), do: :undefined

  defp to_string_value(value), do: QuickBEAM.VM.Semantics.Values.stringify(value)

  @decode_uri_reserved MapSet.new(~c";,/?:@&=+$#")
  @encode_uri_unescaped MapSet.new(
                          ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'();,/?:@&=+$#"
                        )
  @encode_uri_component_unescaped MapSet.new(
                                    ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
                                  )

  defp decode_uri_string(string, mode) do
    string
    |> decode_uri_bytes(mode, [])
    |> IO.iodata_to_binary()
  end

  defp decode_uri_bytes(<<>>, _mode, acc), do: Enum.reverse(acc)

  defp decode_uri_bytes(<<"%", rest::binary>>, mode, acc) do
    {encoded, bytes, rest} = collect_percent_sequence(<<"%", rest::binary>>)
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

  defp collect_percent_sequence(input) do
    {encoded, first, rest} = percent_triplet!(input)
    remaining = utf8_continuation_count!(first)
    collect_continuations(rest, remaining, [encoded], [first])
  end

  defp collect_continuations(rest, 0, encoded, bytes),
    do: {IO.iodata_to_binary(Enum.reverse(encoded)), Enum.reverse(bytes), rest}

  defp collect_continuations(rest, remaining, encoded, bytes) do
    {triplet, byte, rest} = percent_triplet!(rest)

    if byte < 0x80 or byte > 0xBF do
      uri_error!()
    end

    collect_continuations(rest, remaining - 1, [triplet | encoded], [byte | bytes])
  end

  defp percent_triplet!(<<"%", high, low, rest::binary>>) do
    with {:ok, hi} <- hex_value(high),
         {:ok, lo} <- hex_value(low) do
      {<<"%", high, low>>, hi * 16 + lo, rest}
    else
      :error -> uri_error!()
    end
  end

  defp percent_triplet!(<<"%", _rest::binary>>), do: uri_error!()
  defp percent_triplet!(_), do: uri_error!()

  defp utf8_continuation_count!(byte) when byte < 0x80, do: 0
  defp utf8_continuation_count!(byte) when byte in 0xC2..0xDF, do: 1
  defp utf8_continuation_count!(byte) when byte in 0xE0..0xEF, do: 2
  defp utf8_continuation_count!(byte) when byte in 0xF0..0xF4, do: 3
  defp utf8_continuation_count!(_), do: uri_error!()

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

  defp encode_uri_string(string, mode) do
    unescaped = if mode == :uri, do: @encode_uri_unescaped, else: @encode_uri_component_unescaped
    encode_uri_codepoints(string, unescaped, []) |> IO.iodata_to_binary()
  end

  defp encode_uri_codepoints(<<>>, _unescaped, acc), do: Enum.reverse(acc)

  defp encode_uri_codepoints(string, unescaped, acc) do
    case String.next_codepoint(string) do
      {codepoint, rest} ->
        [char] = String.to_charlist(codepoint)

        cond do
          char in 0xF0000..0xF03FF ->
            {combined, rest} = surrogate_pair_codepoint!(char, rest)
            encode_uri_codepoints(rest, unescaped, [percent_encode_codepoint(combined) | acc])

          char in 0xD800..0xDFFF or char in 0xF0400..0xF07FF ->
            uri_error!()

          MapSet.member?(unescaped, char) ->
            encode_uri_codepoints(rest, unescaped, [codepoint | acc])

          true ->
            encode_uri_codepoints(rest, unescaped, [percent_encode_utf8(codepoint) | acc])
        end

      nil ->
        Enum.reverse(acc)
    end
  rescue
    _ -> uri_error!()
  end

  defp surrogate_pair_codepoint!(high_private, rest) do
    case String.next_codepoint(rest) do
      {low_codepoint, tail} ->
        [low_private] = String.to_charlist(low_codepoint)

        if low_private in 0xF0400..0xF07FF do
          high = 0xD800 + high_private - 0xF0000
          low = 0xDC00 + low_private - 0xF0400
          {0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00), tail}
        else
          uri_error!()
        end

      nil ->
        uri_error!()
    end
  end

  defp percent_encode_codepoint(codepoint) do
    codepoint
    |> List.wrap()
    |> :unicode.characters_to_binary(:unicode, :utf8)
    |> percent_encode_utf8()
  end

  defp percent_encode_utf8(codepoint) do
    codepoint
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> "%" <> byte_to_hex(byte) end)
  end

  defp byte_to_hex(byte) do
    <<high::4, low::4>> = <<byte>>
    <<hex_digit(high), hex_digit(low)>>
  end

  defp hex_digit(value) when value < 10, do: ?0 + value
  defp hex_digit(value), do: ?A + value - 10

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
