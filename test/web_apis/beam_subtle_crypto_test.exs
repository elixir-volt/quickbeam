defmodule QuickBEAM.WebAPIs.BeamSubtleCryptoTest do
  use ExUnit.Case, async: true
  @moduletag :beam_web_apis

  setup do
    QuickBEAM.VM.Heap.reset()
    {:ok, rt} = QuickBEAM.start(mode: :beam)
    {:ok, rt: rt}
  end

  describe "crypto.subtle.digest" do
    test "SHA-256", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const data = new TextEncoder().encode('hello');
               const hash = await crypto.subtle.digest('SHA-256', data);
               const arr = new Uint8Array(hash);
               arr.length === 32 && arr[0] === 0x2c && arr[1] === 0xf2;
               """)
    end

    test "SHA-1", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const hash = await crypto.subtle.digest('SHA-1', new TextEncoder().encode('hello'));
               new Uint8Array(hash).length === 20;
               """)
    end

    test "SHA-384", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const hash = await crypto.subtle.digest('SHA-384', new TextEncoder().encode('hello'));
               new Uint8Array(hash).length === 48;
               """)
    end

    test "SHA-512", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const hash = await crypto.subtle.digest('SHA-512', new TextEncoder().encode('hello'));
               new Uint8Array(hash).length === 64;
               """)
    end

    test "digest with object algorithm", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const hash = await crypto.subtle.digest({name: 'SHA-256'}, new TextEncoder().encode('test'));
               new Uint8Array(hash).length === 32;
               """)
    end

    test "digest returns ArrayBuffer", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const hash = await crypto.subtle.digest('SHA-256', new Uint8Array([1,2,3]));
               hash instanceof ArrayBuffer;
               """)
    end

    test "empty input", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const hash = await crypto.subtle.digest('SHA-256', new Uint8Array());
               new Uint8Array(hash).length === 32;
               """)
    end
  end

  describe "crypto.subtle.generateKey" do
    test "HMAC key", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.generateKey(
                 {name: 'HMAC', hash: 'SHA-256'},
                 true, ['sign', 'verify']
               );
               key.type === 'secret' && key.algorithm === 'HMAC' && key.data.length === 64;
               """)
    end

    test "AES-GCM key", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.generateKey(
                 {name: 'AES-GCM', length: 256},
                 true, ['encrypt', 'decrypt']
               );
               key.type === 'secret' && key.data.length === 32;
               """)
    end

    test "ECDSA key pair", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const pair = await crypto.subtle.generateKey(
                 {name: 'ECDSA', namedCurve: 'P-256'},
                 true, ['sign', 'verify']
               );
               pair.publicKey.type === 'public' && pair.privateKey.type === 'private';
               """)
    end
  end

  describe "crypto.subtle.sign/verify HMAC" do
    test "HMAC sign and verify", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.generateKey(
                 {name: 'HMAC', hash: 'SHA-256'},
                 true, ['sign', 'verify']
               );
               const data = new TextEncoder().encode('message');
               const sig = await crypto.subtle.sign('HMAC', key, data);
               sig instanceof ArrayBuffer && new Uint8Array(sig).length === 32;
               """)
    end

    test "HMAC verify returns true for valid", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.generateKey(
                 {name: 'HMAC', hash: 'SHA-256'},
                 true, ['sign', 'verify']
               );
               const data = new TextEncoder().encode('message');
               const sig = await crypto.subtle.sign('HMAC', key, data);
               await crypto.subtle.verify('HMAC', key, sig, data);
               """)
    end

    test "HMAC verify returns false for tampered", %{rt: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.generateKey(
                 {name: 'HMAC', hash: 'SHA-256'},
                 true, ['sign', 'verify']
               );
               const data = new TextEncoder().encode('message');
               const sig = await crypto.subtle.sign('HMAC', key, data);
               const other = new TextEncoder().encode('tampered');
               await crypto.subtle.verify('HMAC', key, sig, other);
               """)
    end
  end

  describe "crypto.subtle.sign/verify ECDSA" do
    test "ECDSA sign and verify", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const pair = await crypto.subtle.generateKey(
                 {name: 'ECDSA', namedCurve: 'P-256'},
                 true, ['sign', 'verify']
               );
               const data = new TextEncoder().encode('hello');
               const sig = await crypto.subtle.sign(
                 {name: 'ECDSA', hash: 'SHA-256'},
                 pair.privateKey, data
               );
               await crypto.subtle.verify(
                 {name: 'ECDSA', hash: 'SHA-256'},
                 pair.publicKey, sig, data
               );
               """)
    end

    test "ECDSA verify rejects wrong message", %{rt: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, """
               const pair = await crypto.subtle.generateKey(
                 {name: 'ECDSA', namedCurve: 'P-256'},
                 true, ['sign', 'verify']
               );
               const data = new TextEncoder().encode('hello');
               const sig = await crypto.subtle.sign(
                 {name: 'ECDSA', hash: 'SHA-256'},
                 pair.privateKey, data
               );
               await crypto.subtle.verify(
                 {name: 'ECDSA', hash: 'SHA-256'},
                 pair.publicKey, sig, new TextEncoder().encode('wrong')
               );
               """)
    end
  end

  describe "crypto.subtle.encrypt/decrypt AES-GCM" do
    test "encrypt and decrypt round-trip", %{rt: rt} do
      assert {:ok, "secret message"} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.generateKey(
                 {name: 'AES-GCM', length: 256},
                 true, ['encrypt', 'decrypt']
               );
               const iv = crypto.getRandomValues(new Uint8Array(12));
               const data = new TextEncoder().encode('secret message');
               const ct = await crypto.subtle.encrypt({name: 'AES-GCM', iv}, key, data);
               const pt = await crypto.subtle.decrypt({name: 'AES-GCM', iv}, key, ct);
               new TextDecoder().decode(pt);
               """)
    end

    test "decrypt with wrong key fails", %{rt: rt} do
      assert {:error, _} =
               QuickBEAM.eval(rt, """
               const key1 = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, true, ['encrypt', 'decrypt']);
               const key2 = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, true, ['encrypt', 'decrypt']);
               const iv = crypto.getRandomValues(new Uint8Array(12));
               const ct = await crypto.subtle.encrypt({name: 'AES-GCM', iv}, key1, new TextEncoder().encode('test'));
               await crypto.subtle.decrypt({name: 'AES-GCM', iv}, key2, ct);
               """)
    end
  end

  describe "crypto.subtle.encrypt/decrypt AES-CBC" do
    test "AES-CBC round-trip", %{rt: rt} do
      assert {:ok, "hello world"} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.generateKey(
                 {name: 'AES-CBC', length: 256},
                 true, ['encrypt', 'decrypt']
               );
               const iv = crypto.getRandomValues(new Uint8Array(16));
               const data = new TextEncoder().encode('hello world');
               const ct = await crypto.subtle.encrypt({name: 'AES-CBC', iv}, key, data);
               const pt = await crypto.subtle.decrypt({name: 'AES-CBC', iv}, key, ct);
               new TextDecoder().decode(pt);
               """)
    end
  end

  describe "crypto.subtle.deriveBits/deriveKey" do
    test "PBKDF2 deriveBits", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const key = await crypto.subtle.importKey(
                 'raw', new TextEncoder().encode('password'),
                 'PBKDF2', false, ['deriveBits']
               );
               const bits = await crypto.subtle.deriveBits(
                 {name: 'PBKDF2', hash: 'SHA-256', salt: new TextEncoder().encode('salt'), iterations: 1000},
                 key, 256
               );
               new Uint8Array(bits).length === 32;
               """)
    end

    test "PBKDF2 deriveKey for AES", %{rt: rt} do
      assert {:ok, "encrypted round-trip"} =
               QuickBEAM.eval(rt, """
               const baseKey = await crypto.subtle.importKey(
                 'raw', new TextEncoder().encode('password'),
                 'PBKDF2', false, ['deriveKey']
               );
               const key = await crypto.subtle.deriveKey(
                 {name: 'PBKDF2', hash: 'SHA-256', salt: new TextEncoder().encode('salt'), iterations: 1000},
                 baseKey,
                 {name: 'AES-GCM', length: 256},
                 true, ['encrypt', 'decrypt']
               );
               const iv = crypto.getRandomValues(new Uint8Array(12));
               const ct = await crypto.subtle.encrypt({name: 'AES-GCM', iv}, key, new TextEncoder().encode('encrypted round-trip'));
               const pt = await crypto.subtle.decrypt({name: 'AES-GCM', iv}, key, ct);
               new TextDecoder().decode(pt);
               """)
    end
  end

  describe "crypto.subtle.importKey/exportKey" do
    test "importKey raw and exportKey", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const raw = crypto.getRandomValues(new Uint8Array(32));
               const key = await crypto.subtle.importKey(
                 'raw', raw, {name: 'AES-GCM'}, true, ['encrypt']
               );
               const exported = await crypto.subtle.exportKey('raw', key);
               const arr = new Uint8Array(exported);
               arr.length === 32 && arr.every((b, i) => b === raw[i]);
               """)
    end
  end
end
