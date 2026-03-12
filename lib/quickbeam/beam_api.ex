defmodule QuickBEAM.BeamAPI do
  @moduledoc false
  import Bitwise

  @version Mix.Project.config()[:version]

  def version([]) do
    @version
  end

  def sleep_sync([ms]) when is_number(ms) do
    Process.sleep(trunc(ms))
    nil
  end

  def hash([data]) do
    :erlang.phash2(data)
  end

  def hash([data, range]) when is_integer(range) and range > 0 do
    :erlang.phash2(data, range)
  end

  def escape_html([str]) when is_binary(str) do
    escape_html_binary(str, <<>>)
  end

  def which([bin]) when is_binary(bin) do
    System.find_executable(bin)
  end

  def random_uuid_v7([]) do
    {counter, last_ms} = uuid_atomics()
    ms = System.system_time(:millisecond)
    prev_ms = :atomics.get(last_ms, 1)

    seq =
      if ms != prev_ms do
        :atomics.put(last_ms, 1, ms)
        rand_seq = :rand.uniform(4096) - 1
        :atomics.put(counter, 1, rand_seq)
        rand_seq
      else
        :atomics.add_get(counter, 1, 1)
      end

    <<rand_b::62, _::2>> = :crypto.strong_rand_bytes(8)

    <<a::32, b::16, c::16, d::16, e::48>> =
      <<ms::48, 0b0111::4, band(seq, 0xFFF)::12, 0b10::2, rand_b::62>>

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c, d, e]
    )
    |> IO.iodata_to_binary()
  end

  defp uuid_atomics do
    case :persistent_term.get({__MODULE__, :uuid_atomics}, nil) do
      nil ->
        counter = :atomics.new(1, signed: false)
        last_ms = :atomics.new(1, signed: true)
        ref = {counter, last_ms}
        :persistent_term.put({__MODULE__, :uuid_atomics}, ref)
        ref

      ref ->
        ref
    end
  end

  def semver_satisfies([version, requirement]) do
    case {Version.parse(version), Version.parse_requirement(requirement)} do
      {{:ok, v}, {:ok, r}} -> Version.match?(v, r)
      _ -> false
    end
  end

  def semver_order([a, b]) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} ->
        case Version.compare(va, vb) do
          :lt -> -1
          :eq -> 0
          :gt -> 1
        end

      _ ->
        nil
    end
  end

  def nodes([]) do
    [node() | Node.list()] |> Enum.map(&Atom.to_string/1)
  end

  def spawn_runtime([script], _caller) do
    {:ok, pid} = QuickBEAM.start()
    QuickBEAM.eval(pid, script)
    pid
  end

  def rpc([node_name, runtime_name, fn_name | args], _caller) when is_binary(node_name) do
    target = String.to_existing_atom(node_name)
    name = String.to_existing_atom(runtime_name)

    :erpc.call(target, QuickBEAM, :call, [name, fn_name, args])
  rescue
    e -> raise "RPC failed: #{Exception.message(e)}"
  end

  def register_name([name], caller) when is_binary(name) do
    atom = String.to_atom(name)
    Process.register(caller, atom)
    true
  rescue
    _ -> false
  end

  def whereis([name]) when is_binary(name) do
    case Process.whereis(String.to_existing_atom(name)) do
      nil -> nil
      pid -> pid
    end
  rescue
    ArgumentError -> nil
  end

  def link_process([pid], _caller) when is_pid(pid) do
    Process.link(pid)
    true
  rescue
    _ -> false
  end

  def unlink_process([pid], _caller) when is_pid(pid) do
    Process.unlink(pid)
    true
  end

  def system_info([]) do
    %{
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      memory:
        :erlang.memory()
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    }
  end

  def process_info([], caller) do
    case Process.info(caller, [
           :memory,
           :message_queue_len,
           :reductions,
           :status,
           :registered_name,
           :heap_size,
           :stack_size,
           :total_heap_size
         ]) do
      nil ->
        nil

      info ->
        %{
          memory: Keyword.get(info, :memory),
          message_queue_len: Keyword.get(info, :message_queue_len),
          reductions: Keyword.get(info, :reductions),
          heap_size: Keyword.get(info, :heap_size),
          stack_size: Keyword.get(info, :stack_size),
          total_heap_size: Keyword.get(info, :total_heap_size),
          status: Keyword.get(info, :status) |> Atom.to_string(),
          registered_name:
            case Keyword.get(info, :registered_name) do
              nil -> nil
              [] -> nil
              name -> Atom.to_string(name)
            end
        }
    end
  end

  defp escape_html_binary(<<>>, acc), do: acc

  defp escape_html_binary(<<"&", rest::binary>>, acc),
    do: escape_html_binary(rest, <<acc::binary, "&amp;">>)

  defp escape_html_binary(<<"<", rest::binary>>, acc),
    do: escape_html_binary(rest, <<acc::binary, "&lt;">>)

  defp escape_html_binary(<<">", rest::binary>>, acc),
    do: escape_html_binary(rest, <<acc::binary, "&gt;">>)

  defp escape_html_binary(<<"\"", rest::binary>>, acc),
    do: escape_html_binary(rest, <<acc::binary, "&quot;">>)

  defp escape_html_binary(<<"'", rest::binary>>, acc),
    do: escape_html_binary(rest, <<acc::binary, "&#x27;">>)

  defp escape_html_binary(<<c, rest::binary>>, acc),
    do: escape_html_binary(rest, <<acc::binary, c>>)
end
