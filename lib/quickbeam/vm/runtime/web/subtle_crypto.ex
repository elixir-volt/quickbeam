defmodule QuickBEAM.VM.Runtime.Web.SubtleCrypto do
  @moduledoc "crypto.subtle builtin for BEAM mode — delegates to QuickBEAM.SubtleCrypto."

  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  alias QuickBEAM.VM.{Heap, JSThrow, PromiseState}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Web.Buffer

  def build_subtle do
    build_object do
      method "digest" do
        [algo_val, data_val | _] = args ++ [nil, nil]
        algo = normalize_algo_name(algo_val)
        data = extract_bytes(data_val)

        result =
          try do
            QuickBEAM.SubtleCrypto.digest([algo, data])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        PromiseState.resolved(bytes_to_array_buffer(result))
      end

      method "generateKey" do
        [algo_val, _extractable, _key_usages | _] = args ++ [nil, nil, nil]
        algo = normalize_algo(algo_val)

        result =
          try do
            QuickBEAM.SubtleCrypto.generate_key([algo])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        PromiseState.resolved(wrap_key_result(result))
      end

      method "sign" do
        [algo_val, key_val, data_val | _] = args ++ [nil, nil, nil]
        algo = normalize_algo(algo_val)
        key_data = key_data_for_crypto(unwrap_key(key_val))
        data = extract_bytes(data_val)

        result =
          try do
            QuickBEAM.SubtleCrypto.sign([algo, key_data, data])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        PromiseState.resolved(bytes_to_array_buffer(result))
      end

      method "verify" do
        [algo_val, key_val, sig_val, data_val | _] = args ++ [nil, nil, nil, nil]
        algo = normalize_algo(algo_val)
        key_data = key_data_for_crypto(unwrap_key(key_val))
        sig = extract_bytes(sig_val)
        data = extract_bytes(data_val)

        result =
          try do
            QuickBEAM.SubtleCrypto.verify([algo, key_data, sig, data])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        PromiseState.resolved(result)
      end

      method "encrypt" do
        [algo_val, key_val, data_val | _] = args ++ [nil, nil, nil]
        algo = normalize_algo(algo_val)
        key_data = key_data_for_crypto(unwrap_key(key_val))
        data = extract_bytes(data_val)

        result =
          try do
            QuickBEAM.SubtleCrypto.encrypt([algo, key_data, data])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        PromiseState.resolved(bytes_to_array_buffer(result))
      end

      method "decrypt" do
        [algo_val, key_val, data_val | _] = args ++ [nil, nil, nil]
        algo = normalize_algo(algo_val)
        key_data = key_data_for_crypto(unwrap_key(key_val))
        data = extract_bytes(data_val)

        result =
          try do
            QuickBEAM.SubtleCrypto.decrypt([algo, key_data, data])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        PromiseState.resolved(bytes_to_array_buffer(result))
      end

      method "deriveBits" do
        [algo_val, key_val, length_val | _] = args ++ [nil, nil, nil]
        algo = normalize_algo(algo_val)
        key_data = key_data_for_crypto(unwrap_key(key_val))
        length = to_int(length_val)

        result =
          try do
            QuickBEAM.SubtleCrypto.derive_bits([algo, key_data, length])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        PromiseState.resolved(bytes_to_array_buffer(result))
      end

      method "deriveKey" do
        [algo_val, key_val, derived_algo_val, extractable, _key_usages | _] = args ++ [nil, nil, nil, nil, nil]
        algo = normalize_algo(algo_val)
        key_data = key_data_for_crypto(unwrap_key(key_val))
        derived_algo = normalize_algo(derived_algo_val)

        # Determine bit length from derived algo
        length = case derived_algo do
          %{"length" => l} -> l
          _ -> 256
        end

        bits_result =
          try do
            QuickBEAM.SubtleCrypto.derive_bits([algo, key_data, length])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        {:bytes, raw_key} = bits_result
        algo_name = Map.get(derived_algo, "name", "AES-GCM")

        derived_key = %{
          "type" => "secret",
          "algorithm" => algo_name,
          "extractable" => extractable == true,
          "data" => {:bytes, raw_key}
        }

        PromiseState.resolved(wrap_crypto_key(derived_key))
      end

      method "importKey" do
        [format_val, data_val, algo_val, extractable, _key_usages | _] = args ++ [nil, nil, nil, nil, nil]
        format = to_string(format_val)
        algo = normalize_algo(algo_val)
        algo_name = Map.get(algo, "name", "")
        raw_bytes = extract_bytes(data_val)

        key = case format do
          "raw" ->
            %{
              "type" => "secret",
              "algorithm" => algo_name,
              "extractable" => extractable == true,
              "data" => {:bytes, raw_bytes}
            }

          "PBKDF2" ->
            %{
              "type" => "secret",
              "algorithm" => "PBKDF2",
              "extractable" => false,
              "data" => {:bytes, raw_bytes}
            }

          _ ->
            %{
              "type" => "secret",
              "algorithm" => algo_name,
              "extractable" => extractable == true,
              "data" => {:bytes, raw_bytes}
            }
        end

        # Handle PBKDF2 format — data is the password
        key = if algo_name == "PBKDF2" do
          %{key | "algorithm" => "PBKDF2"}
        else
          key
        end

        PromiseState.resolved(wrap_crypto_key(key))
      end

      method "exportKey" do
        [format_val, key_val | _] = args ++ [nil, nil]
        format = to_string(format_val)
        key_data = unwrap_key(key_val)

        result = case format do
          "raw" ->
            raw = Map.get(key_data, "data")
            bytes = case raw do
              {:bytes, b} -> b
              b when is_binary(b) -> b
              _ -> <<>>
            end
            bytes_to_array_buffer({:bytes, bytes})

          _ ->
            JSThrow.type_error!("exportKey format #{format} not supported")
        end

        PromiseState.resolved(result)
      end
    end
  end

  # ── Helpers ──

  defp normalize_algo_name(algo) when is_binary(algo), do: algo

  defp normalize_algo_name({:obj, _} = obj) do
    case Get.get(obj, "name") do
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  defp normalize_algo_name(_), do: ""

  defp normalize_algo(algo) when is_binary(algo), do: %{"name" => algo}

  defp normalize_algo({:obj, _ref} = obj) do
    extract_algo_from_obj(obj)
  end

  defp normalize_algo(nil), do: %{}
  defp normalize_algo(_), do: %{}

  defp extract_algo_from_obj({:obj, _ref} = obj) do
    keys = ["name", "hash", "namedCurve", "length", "iv", "salt", "iterations", "additionalData", "tagLength", "public"]

    Enum.reduce(keys, %{}, fn key, acc ->
      case Get.get(obj, key) do
        nil -> acc
        :undefined -> acc
        val -> Map.put(acc, key, resolve_nested(val))
      end
    end)
  end

  defp resolve_nested(v) when is_binary(v), do: v
  defp resolve_nested(v) when is_integer(v), do: v
  defp resolve_nested(v) when is_float(v), do: trunc(v)
  defp resolve_nested(v) when is_boolean(v), do: v
  defp resolve_nested({:obj, _} = obj) do
    # Could be a typed array (iv, salt)
    extract_bytes(obj)
  end
  defp resolve_nested({:bytes, b}), do: b
  defp resolve_nested(v), do: v

  defp extract_bytes(nil), do: <<>>
  defp extract_bytes(:undefined), do: <<>>
  defp extract_bytes({:bytes, b}) when is_binary(b), do: b
  defp extract_bytes(b) when is_binary(b), do: b
  defp extract_bytes({:obj, _} = obj), do: Buffer.extract_buf_bytes(obj)
  defp extract_bytes(list) when is_list(list), do: :erlang.list_to_binary(Enum.map(list, fn
    n when is_integer(n) -> n
    _ -> 0
  end))
  defp extract_bytes(_), do: <<>>

  defp bytes_to_array_buffer({:bytes, bytes}), do: bytes_to_array_buffer(bytes)
  defp bytes_to_array_buffer(bytes) when is_binary(bytes) do
    byte_len = byte_size(bytes)
    case Heap.get_global_cache() do
      nil ->
        Heap.wrap(%{"__buffer__" => bytes, "byteLength" => byte_len})
      globals ->
        case Map.get(globals, "ArrayBuffer") do
          {:builtin, _, cb} = ctor ->
            result = cb.([byte_len], nil)
            proto = Heap.get_class_proto(ctor)
            case result do
              {:obj, ref} ->
                Heap.update_obj(ref, %{}, fn m ->
                  base = Map.put(m, "__buffer__", bytes)
                  if proto != nil and not Map.has_key?(base, "__proto__"),
                    do: Map.put(base, "__proto__", proto),
                    else: base
                end)
                result
              _ -> result
            end
          _ ->
            Heap.wrap(%{"__buffer__" => bytes, "byteLength" => byte_len})
        end
    end
  end

  defp wrap_key_result(%{"publicKey" => pub, "privateKey" => priv}) do
    Heap.wrap(%{
      "publicKey" => wrap_crypto_key(pub),
      "privateKey" => wrap_crypto_key(priv)
    })
  end

  defp wrap_key_result(key_data) when is_map(key_data) do
    wrap_crypto_key(key_data)
  end

  defp wrap_crypto_key(key_data) when is_map(key_data) do
    raw_data = Map.get(key_data, "data")
    data_val = case raw_data do
      {:bytes, bytes} -> bytes_to_uint8(bytes)
      bytes when is_binary(bytes) -> bytes_to_uint8(bytes)
      _ -> :undefined
    end

    Heap.wrap(%{
      "type" => Map.get(key_data, "type", "secret"),
      "algorithm" => Map.get(key_data, "algorithm", ""),
      "extractable" => Map.get(key_data, "extractable", true),
      "usages" => [],
      "namedCurve" => Map.get(key_data, "namedCurve", :undefined),
      "hash" => Map.get(key_data, "hash", :undefined),
      "data" => data_val,
      "__key_data__" => key_data
    })
  end

  defp bytes_to_uint8(bytes) when is_binary(bytes) do
    byte_list = :binary.bin_to_list(bytes)
    case Heap.get_global_cache() do
      nil -> Heap.wrap(byte_list)
      globals ->
        case Map.get(globals, "Uint8Array") do
          {:builtin, _, cb} = ctor ->
            result = cb.([byte_list], nil)
            # Set __proto__ for instanceof checks
            case result do
              {:obj, ref} ->
                class_proto = Heap.get_class_proto(ctor)
                if class_proto do
                  m = Heap.get_obj(ref, %{})
                  if is_map(m) and not Map.has_key?(m, "__proto__") do
                    Heap.put_obj(ref, Map.put(m, "__proto__", class_proto))
                  end
                end
                result
              _ -> result
            end
          _ ->
            Heap.wrap(byte_list)
        end
    end
  end

  defp unwrap_key({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      m when is_map(m) ->
        case Map.get(m, "__key_data__") do
          kd when is_map(kd) ->
            # Ensure data is a raw binary for SubtleCrypto functions
            normalize_key_data(kd)
          _ ->
            # Reconstruct from the object properties
            raw = case Map.get(m, "data") do
              {:bytes, b} -> b
              b when is_binary(b) -> b
              {:obj, _} = arr -> Buffer.extract_buf_bytes(arr)
              _ -> <<>>
            end
            %{
              "type" => Map.get(m, "type", "secret"),
              "algorithm" => Map.get(m, "algorithm", ""),
              "namedCurve" => Map.get(m, "namedCurve"),
              "hash" => Map.get(m, "hash"),
              "data" => raw
            }
        end
      _ -> %{}
    end
  end

  defp unwrap_key(_), do: %{}

  defp normalize_key_data(kd) when is_map(kd) do
    # SubtleCrypto.encrypt etc. use to_binary/1 which handles :binary but not {:bytes, binary}
    # We keep {:bytes, binary} as SubtleCrypto knows how to handle it
    kd
  end

  # QuickBEAM.SubtleCrypto uses to_binary which handles is_binary and is_list
  # So we need to unwrap {:bytes, b} to just b before calling SubtleCrypto
  defp key_data_for_crypto(kd) when is_map(kd) do
    data = Map.get(kd, "data")
    raw = case data do
      {:bytes, b} -> b
      b when is_binary(b) -> b
      {:obj, _} = arr -> Buffer.extract_buf_bytes(arr)
      _ -> <<>>
    end
    Map.put(kd, "data", raw)
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(_), do: 0
end
