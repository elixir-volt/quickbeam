defmodule QuickBEAM.SubtleCrypto do
  @moduledoc false

  @algo_map %{
    "SHA-1" => :sha,
    "SHA-256" => :sha256,
    "SHA-384" => :sha384,
    "SHA-512" => :sha512
  }

  @ec_curves %{
    "P-256" => :secp256r1,
    "P-384" => :secp384r1,
    "P-521" => :secp521r1
  }

  def digest([algo, data]) when is_binary(algo) and is_list(data) do
    hash_algo = Map.fetch!(@algo_map, algo)
    bytes = :erlang.list_to_binary(data)
    {:bytes, :crypto.hash(hash_algo, bytes)}
  end

  def generate_key([algo]) when is_map(algo) do
    case algo do
      %{"name" => "HMAC", "hash" => hash_name} ->
        hash_algo = Map.fetch!(@algo_map, hash_name)
        length = Map.get(algo, "length", default_hmac_length(hash_algo))
        key = :crypto.strong_rand_bytes(div(length, 8))

        %{
          "type" => "secret",
          "algorithm" => "HMAC",
          "hash" => hash_name,
          "data" => {:bytes, key}
        }

      %{"name" => "AES-GCM", "length" => length} ->
        key = :crypto.strong_rand_bytes(div(length, 8))
        %{"type" => "secret", "algorithm" => "AES-GCM", "data" => {:bytes, key}}

      %{"name" => "AES-CBC", "length" => length} ->
        key = :crypto.strong_rand_bytes(div(length, 8))
        %{"type" => "secret", "algorithm" => "AES-CBC", "data" => {:bytes, key}}

      %{"name" => "ECDSA", "namedCurve" => curve_name} ->
        generate_ec_keypair(curve_name, "ECDSA")

      %{"name" => "ECDH", "namedCurve" => curve_name} ->
        generate_ec_keypair(curve_name, "ECDH")

      _ ->
        raise "Unsupported algorithm: #{inspect(algo)}"
    end
  end

  def sign([algo, key_data, data]) do
    bytes = to_binary(data)

    case algo do
      %{"name" => "HMAC"} ->
        hash_algo = Map.fetch!(@algo_map, key_data["hash"])
        key = to_binary(key_data["data"])
        mac = :crypto.mac(:hmac, hash_algo, key, bytes)
        {:bytes, mac}

      %{"name" => "ECDSA", "hash" => hash_name} ->
        hash_algo = Map.fetch!(@algo_map, hash_name)
        curve = Map.fetch!(@ec_curves, key_data["namedCurve"])
        priv_key = to_binary(key_data["data"])
        sig = :crypto.sign(:ecdsa, hash_algo, bytes, [priv_key, curve])
        {:bytes, sig}

      _ ->
        raise "Unsupported sign algorithm: #{inspect(algo)}"
    end
  end

  def verify([algo, key_data, signature, data]) do
    bytes = to_binary(data)
    sig_bytes = to_binary(signature)

    case algo do
      %{"name" => "HMAC"} ->
        hash_algo = Map.fetch!(@algo_map, key_data["hash"])
        key = to_binary(key_data["data"])
        expected = :crypto.mac(:hmac, hash_algo, key, bytes)
        :crypto.hash_equals(expected, sig_bytes)

      %{"name" => "ECDSA", "hash" => hash_name} ->
        hash_algo = Map.fetch!(@algo_map, hash_name)
        curve = Map.fetch!(@ec_curves, key_data["namedCurve"])
        pub_key = to_binary(key_data["data"])
        :crypto.verify(:ecdsa, hash_algo, bytes, sig_bytes, [pub_key, curve])

      _ ->
        raise "Unsupported verify algorithm: #{inspect(algo)}"
    end
  end

  def encrypt([algo, key_data, data]) do
    bytes = to_binary(data)

    case algo do
      %{"name" => "AES-GCM", "iv" => iv_list} ->
        key = to_binary(key_data["data"])
        iv = to_binary(iv_list)
        aad = to_binary(Map.get(algo, "additionalData", []))
        tag_length = Map.get(algo, "tagLength", 128)

        {ct, tag} =
          :crypto.crypto_one_time_aead(
            aes_gcm_algo(key),
            key,
            iv,
            bytes,
            aad,
            div(tag_length, 8),
            true
          )

        {:bytes, ct <> tag}

      %{"name" => "AES-CBC", "iv" => iv_list} ->
        key = to_binary(key_data["data"])
        iv = to_binary(iv_list)
        padded = pkcs7_pad(bytes, 16)
        ct = :crypto.crypto_one_time(aes_cbc_algo(key), key, iv, padded, true)
        {:bytes, ct}

      _ ->
        raise "Unsupported encrypt algorithm: #{inspect(algo)}"
    end
  end

  def decrypt([algo, key_data, data]) do
    bytes = to_binary(data)

    case algo do
      %{"name" => "AES-GCM", "iv" => iv_list} ->
        key = to_binary(key_data["data"])
        iv = to_binary(iv_list)
        aad = to_binary(Map.get(algo, "additionalData", []))
        tag_length = div(Map.get(algo, "tagLength", 128), 8)
        ct_len = byte_size(bytes) - tag_length
        <<ct::binary-size(ct_len), tag::binary-size(tag_length)>> = bytes

        case :crypto.crypto_one_time_aead(aes_gcm_algo(key), key, iv, ct, aad, tag, false) do
          :error -> raise "Decryption failed"
          plaintext -> {:bytes, plaintext}
        end

      %{"name" => "AES-CBC", "iv" => iv_list} ->
        key = to_binary(key_data["data"])
        iv = to_binary(iv_list)
        padded = :crypto.crypto_one_time(aes_cbc_algo(key), key, iv, bytes, false)
        {:bytes, pkcs7_unpad(padded)}

      _ ->
        raise "Unsupported decrypt algorithm: #{inspect(algo)}"
    end
  end

  def derive_bits([algo, key_data, length]) do
    case algo do
      %{"name" => "PBKDF2", "hash" => hash_name, "salt" => salt_list, "iterations" => iterations} ->
        hash_algo = Map.fetch!(@algo_map, hash_name)
        password = to_binary(key_data["data"])
        salt = to_binary(salt_list)
        derived = :crypto.pbkdf2_hmac(hash_algo, password, salt, iterations, div(length, 8))
        {:bytes, derived}

      %{"name" => "ECDH", "public" => pub_key_data} ->
        curve = Map.fetch!(@ec_curves, key_data["namedCurve"])
        priv_key = to_binary(key_data["data"])
        pub_key = to_binary(pub_key_data["data"])
        shared = :crypto.compute_key(:ecdh, pub_key, priv_key, curve)
        bits = div(length, 8)
        {:bytes, binary_part(shared, 0, min(bits, byte_size(shared)))}

      _ ->
        raise "Unsupported deriveBits algorithm: #{inspect(algo)}"
    end
  end

  defp generate_ec_keypair(curve_name, algo_name) do
    curve = Map.fetch!(@ec_curves, curve_name)
    {pub, priv} = :crypto.generate_key(:ecdh, curve)

    %{
      "publicKey" => %{
        "type" => "public",
        "algorithm" => algo_name,
        "namedCurve" => curve_name,
        "data" => {:bytes, pub}
      },
      "privateKey" => %{
        "type" => "private",
        "algorithm" => algo_name,
        "namedCurve" => curve_name,
        "data" => {:bytes, priv}
      }
    }
  end

  defp to_binary(data) when is_list(data), do: :erlang.list_to_binary(data)
  defp to_binary(data) when is_binary(data), do: data
  defp to_binary(_), do: <<>>

  defp default_hmac_length(:sha), do: 512
  defp default_hmac_length(:sha256), do: 512
  defp default_hmac_length(:sha384), do: 1024
  defp default_hmac_length(:sha512), do: 1024

  defp aes_gcm_algo(key) when byte_size(key) == 16, do: :aes_128_gcm
  defp aes_gcm_algo(key) when byte_size(key) == 32, do: :aes_256_gcm

  defp aes_cbc_algo(key) when byte_size(key) == 16, do: :aes_128_cbc
  defp aes_cbc_algo(key) when byte_size(key) == 32, do: :aes_256_cbc

  defp pkcs7_pad(data, block_size) do
    pad_len = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<pad_len>>, pad_len)
  end

  defp pkcs7_unpad(data) do
    pad_len = :binary.last(data)

    if pad_len > 0 and pad_len <= 16 do
      binary_part(data, 0, byte_size(data) - pad_len)
    else
      data
    end
  end
end
