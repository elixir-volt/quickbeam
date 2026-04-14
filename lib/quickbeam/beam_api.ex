defmodule QuickBEAM.BeamAPI do
  @moduledoc false
  import Bitwise
  require Record

  Record.defrecord(:xml_element, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecord(:xml_text, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  Record.defrecord(
    :xml_attribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @version Mix.Project.config()[:version]

  @spec version([]) :: String.t()
  def version([]) do
    @version
  end

  @spec sleep_sync([number()]) :: nil
  def sleep_sync([ms]) when is_number(ms) do
    Process.sleep(trunc(ms))
    nil
  end

  @spec hash([term()]) :: non_neg_integer()
  def hash([data]) do
    :erlang.phash2(data)
  end

  @spec hash(list()) :: non_neg_integer()
  def hash([data, range]) when is_integer(range) and range > 0 do
    :erlang.phash2(data, range)
  end

  @spec escape_html([String.t()]) :: String.t()
  def escape_html([str]) when is_binary(str) do
    escape_html_binary(str, <<>>)
  end

  @spec which([String.t()]) :: String.t() | nil
  def which([bin]) when is_binary(bin) do
    System.find_executable(bin)
  end

  @spec random_uuid_v7([]) :: String.t()
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

  @spec semver_satisfies(list()) :: boolean()
  def semver_satisfies([version, requirement]) do
    case {Version.parse(version), Version.parse_requirement(requirement)} do
      {{:ok, v}, {:ok, r}} -> Version.match?(v, r)
      _ -> false
    end
  end

  @spec semver_order(list()) :: -1 | 0 | 1 | nil
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

  @spec nodes([]) :: [String.t()]
  def nodes([]) do
    [node() | Node.list()] |> Enum.map(&Atom.to_string/1)
  end

  @spec spawn_runtime([String.t()], pid()) :: pid()
  def spawn_runtime([script], _caller) do
    {:ok, pid} = QuickBEAM.start()
    QuickBEAM.eval(pid, script)
    pid
  end

  @spec rpc(list(), pid()) :: term()
  def rpc([node_name, runtime_name, fn_name | args], _caller) when is_binary(node_name) do
    target = String.to_existing_atom(node_name)
    name = String.to_existing_atom(runtime_name)

    :erpc.call(target, QuickBEAM, :call, [name, fn_name, args])
  rescue
    e -> reraise RuntimeError, [message: "RPC failed: #{Exception.message(e)}"], __STACKTRACE__
  end

  @spec register_name([String.t()], pid()) :: boolean()
  def register_name([name], caller) when is_binary(name) do
    atom = String.to_atom(name)
    Process.register(caller, atom)
    true
  rescue
    _ -> false
  end

  @spec whereis([String.t()]) :: pid() | nil
  def whereis([name]) when is_binary(name) do
    Process.whereis(String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  @spec link_process([pid()], pid()) :: boolean()
  def link_process([pid], _caller) when is_pid(pid) do
    Process.link(pid)
    true
  rescue
    _ -> false
  end

  @spec unlink_process([pid()], pid()) :: boolean()
  def unlink_process([pid], _caller) when is_pid(pid) do
    Process.unlink(pid)
    true
  end

  @spec system_info([]) :: map()
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

  @pbkdf2_salt_length 16
  @pbkdf2_key_length 32

  @spec nanoseconds([]) :: integer()
  def nanoseconds([]) do
    :erlang.monotonic_time(:nanosecond)
  end

  @spec unique_integer([]) :: integer()
  def unique_integer([]) do
    :erlang.unique_integer([:monotonic, :positive])
  end

  @spec make_ref([]) :: reference()
  def make_ref([]) do
    Kernel.make_ref()
  end

  @spec inspect_value([term()]) :: String.t()
  def inspect_value([value]) do
    Kernel.inspect(value, pretty: true, width: 80)
  end

  @spec xml_parse([String.t()]) :: map()
  def xml_parse([xml]) when is_binary(xml) do
    {document, _rest} = :xmerl_scan.string(String.to_charlist(xml), quiet: true)
    %{element_name(document) => convert_element(document)}
  catch
    :exit, reason ->
      raise ArgumentError, "invalid XML: #{Exception.format_exit(reason)}"
  end

  @spec password_hash(list()) :: String.t()
  def password_hash([password, iterations])
      when is_binary(password) and is_integer(iterations) and iterations > 0 do
    salt = :crypto.strong_rand_bytes(@pbkdf2_salt_length)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @pbkdf2_key_length)
    "$pbkdf2-sha256$#{iterations}$#{Base.encode64(salt)}$#{Base.encode64(hash)}"
  end

  @spec password_verify(list()) :: boolean()
  def password_verify([password, hash_string])
      when is_binary(password) and is_binary(hash_string) do
    case String.split(hash_string, "$", trim: true) do
      ["pbkdf2-sha256", iterations_str, salt_b64, hash_b64] ->
        with {iterations, ""} <- Integer.parse(iterations_str),
             {:ok, salt} <- Base.decode64(salt_b64),
             {:ok, expected} <- Base.decode64(hash_b64) do
          derived = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, byte_size(expected))
          :crypto.hash_equals(derived, expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  @spec process_info([], pid()) :: map() | nil
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

  defp convert_element(element) do
    attributes =
      element
      |> xml_element(:attributes)
      |> Enum.reduce(%{}, fn attribute, acc ->
        Map.put(acc, "@#{attribute_name(attribute)}", attribute_value(attribute))
      end)

    children =
      element
      |> xml_element(:content)
      |> Enum.reduce(%{text: [], elements: %{}}, &reduce_xml_content/2)

    children = %{children | elements: finalize_children(children.elements)}

    text =
      children.text
      |> Enum.reverse()
      |> Enum.join(" ")
      |> String.trim()

    cond do
      map_size(attributes) == 0 and map_size(children.elements) == 0 ->
        text

      text == "" ->
        Map.merge(attributes, children.elements)

      true ->
        Map.merge(attributes, Map.put(children.elements, "#text", text))
    end
  end

  defp reduce_xml_content(content, acc) when is_tuple(content) do
    case elem(content, 0) do
      :xmlText ->
        case text_value(content) do
          "" -> acc
          value -> %{acc | text: [value | acc.text]}
        end

      :xmlElement ->
        name = element_name(content)
        value = convert_element(content)
        %{acc | elements: Map.update(acc.elements, name, value, &prepend_child(&1, value))}

      _ ->
        acc
    end
  end

  defp reduce_xml_content(_content, acc), do: acc

  defp finalize_children(elements) do
    Map.new(elements, fn
      {key, [_ | _] = list} -> {key, Enum.reverse(list)}
      pair -> pair
    end)
  end

  defp prepend_child(existing, value) when is_list(existing), do: [value | existing]
  defp prepend_child(existing, value), do: [value, existing]

  defp element_name(element) do
    case xml_element(element, :nsinfo) do
      {prefix, local} -> "#{prefix}:#{local}"
      _ -> xml_element(element, :name) |> Atom.to_string()
    end
  end

  defp attribute_name(attribute) do
    case xml_attribute(attribute, :nsinfo) do
      {prefix, local} -> "#{prefix}:#{local}"
      _ -> xml_attribute(attribute, :name) |> Atom.to_string()
    end
  end

  defp attribute_value(attribute) do
    attribute |> xml_attribute(:value) |> to_string()
  end

  defp text_value(text) do
    text
    |> xml_text(:value)
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
