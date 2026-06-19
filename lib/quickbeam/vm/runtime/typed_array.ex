defmodule QuickBEAM.VM.Runtime.TypedArray do
  @moduledoc "JS TypedArray built-ins: constructors and prototype methods for all numeric array types (Uint8Array through Float64Array)."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Definition
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyKey}
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Value
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Array
  alias QuickBEAM.VM.Runtime.TypedArray.Metadata
  alias QuickBEAM.VM.Runtime.TypedArrayCoercion
  alias QuickBEAM.VM.Runtime.TypedArrayInstallation
  alias QuickBEAM.VM.Semantics.Iterators

  @max_typed_array_elements 4_294_967_295

  def builtin_definitions do
    for {name, type} <- Metadata.types() do
      %Definition{
        name: name,
        constructor: constructor(type),
        length: 3,
        phase: :collections,
        module: __MODULE__,
        after_install: &__MODULE__.install_builtin/1
      }
    end
  end

  def install_builtin({:builtin, name, _} = ctor) do
    TypedArrayInstallation.install_builtin(ctor, __MODULE__)

    if name == "Uint8Array" do
      install_uint8array_encoding_static(ctor, "fromHex", 1, &from_hex/2)
      install_uint8array_encoding_static(ctor, "fromBase64", 1, &from_base64/2)
    end
  end

  defp install_uint8array_encoding_static(ctor, name, length, callback) do
    method =
      {:builtin, name, fn args, this -> callback.(args, this) end}
      |> Builtin.put_builtin_metadata(Builtin.meta(name, length: length, constructable: false))
      |> Builtin.put_function_metadata(name, length)

    Heap.put_ctor_static(ctor, name, method)
    Heap.put_ctor_prop_desc(ctor, name, QuickBEAM.VM.ObjectModel.PropertyDescriptor.method())
  end

  def from_hex(args, _this) do
    args
    |> Builtin.arg(0, :undefined)
    |> require_string_argument!("Uint8Array.fromHex")
    |> decode_hex_bytes()
    |> uint8array_from_bytes()
  end

  def from_base64(args, _this) do
    source =
      args |> Builtin.arg(0, :undefined) |> require_string_argument!("Uint8Array.fromBase64")

    options = Builtin.arg(args, 1, :undefined)
    alphabet = base64_option(options, "alphabet", "base64")
    last_chunk_handling = base64_option(options, "lastChunkHandling", "loose")

    source
    |> decode_base64_bytes(alphabet, last_chunk_handling)
    |> uint8array_from_bytes()
  end

  @ecma "23.2.2.1"
  static "from", length: 1 do
    static_from(args, this)
  end

  @ecma "23.2.2.2"
  static "of", length: 0 do
    static_of(args, this)
  end

  def toHex(_args, this) do
    this
    |> require_uint8array_receiver!("Uint8Array.prototype.toHex")
    |> uint8array_bytes()
    |> Enum.map_join(fn byte ->
      byte |> trunc() |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    end)
  end

  def toBase64(args, this) do
    target = require_uint8array_receiver!(this, "Uint8Array.prototype.toBase64")
    options = Builtin.arg(args, 0, :undefined)
    alphabet = base64_option(options, "alphabet", "base64")
    omit_padding = Values.truthy?(Get.get(options, "omitPadding"))
    validate_base64_options!(alphabet, "loose")

    target
    |> uint8array_bytes()
    |> :binary.list_to_bin()
    |> Base.encode64()
    |> maybe_base64url(alphabet)
    |> maybe_omit_base64_padding(omit_padding)
  end

  def setFromHex(args, this) do
    target = require_uint8array_receiver!(this, "Uint8Array.prototype.setFromHex")

    source =
      args
      |> Builtin.arg(0, :undefined)
      |> require_string_argument!("Uint8Array.prototype.setFromHex")

    bytes =
      try do
        decode_hex_bytes(source)
      catch
        {:js_throw, reason} ->
          if rem(String.length(source), 2) == 0 do
            write_prefix_bytes(
              target,
              decode_hex_prefix_before_error(source),
              element_count(target)
            )
          end

          throw({:js_throw, reason})
      end

    written = write_prefix_bytes(target, bytes, element_count(target))
    result_object(%{"read" => written * 2, "written" => written})
  end

  def setFromBase64(args, this) do
    target = require_uint8array_receiver!(this, "Uint8Array.prototype.setFromBase64")

    source =
      args
      |> Builtin.arg(0, :undefined)
      |> require_string_argument!("Uint8Array.prototype.setFromBase64")

    options = Builtin.arg(args, 1, :undefined)
    alphabet = base64_option(options, "alphabet", "base64")
    last_chunk_handling = base64_option(options, "lastChunkHandling", "loose")
    normalized_source = String.replace(source, ~r/[\t\n\f\r ]/, "")
    capacity = element_count(target)

    if capacity == 0 do
      result_object(%{"read" => 0, "written" => 0})
    else
      {bytes, prefix_completed?} =
        try do
          {decode_base64_bytes(source, alphabet, last_chunk_handling), false}
        catch
          {:js_throw, reason} ->
            prefix = decode_base64_prefix_before_error(source, alphabet)

            if length(prefix) >= capacity do
              {prefix, true}
            else
              write_prefix_bytes(target, prefix, capacity)
              throw({:js_throw, reason})
            end
        end

      written =
        if length(bytes) <= capacity do
          write_prefix_bytes(target, bytes, capacity)
        else
          write_prefix_bytes(target, Enum.take(bytes, div(capacity, 3) * 3), capacity)
        end

      read =
        cond do
          prefix_completed? or length(bytes) > capacity ->
            div(capacity, 3) * 4

          last_chunk_handling == "stop-before-partial" ->
            String.length(trim_base64_partial(normalized_source, last_chunk_handling))

          true ->
            String.length(source)
        end

      result_object(%{"read" => read, "written" => written})
    end
  end

  defp decode_hex_bytes(source) do
    if rem(String.length(source), 2) != 0 do
      JSThrow.syntax_error!("Invalid hex string")
    end

    source
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(fn pair ->
      digits = Enum.join(pair)

      case Integer.parse(digits, 16) do
        {byte, ""} -> byte
        _ -> JSThrow.syntax_error!("Invalid hex string")
      end
    end)
  end

  defp decode_hex_prefix_before_error(source) do
    source
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.take_while(fn pair ->
      length(pair) == 2 and match?({_byte, ""}, Integer.parse(Enum.join(pair), 16))
    end)
    |> Enum.map(fn pair ->
      {byte, ""} = Integer.parse(Enum.join(pair), 16)
      byte
    end)
  end

  defp decode_base64_bytes(source, alphabet, last_chunk_handling) do
    normalized = String.replace(source, ~r/[\t\n\f\r ]/, "")
    validate_base64_options!(alphabet, last_chunk_handling)

    validate_base64_alphabet_source!(normalized, alphabet)

    normalized =
      case alphabet do
        "base64" -> normalized
        "base64url" -> normalized |> String.replace("-", "+") |> String.replace("_", "/")
      end

    normalized = trim_base64_partial(normalized, last_chunk_handling)
    validate_base64_source!(normalized)
    padded = pad_base64(normalized)

    case Base.decode64(padded) do
      {:ok, binary} ->
        if last_chunk_handling == "strict" and Base.encode64(binary) != padded do
          JSThrow.syntax_error!("Invalid base64 string")
        end

        :binary.bin_to_list(binary)

      :error ->
        JSThrow.syntax_error!("Invalid base64 string")
    end
  end

  defp validate_base64_options!(alphabet, last_chunk_handling) do
    unless alphabet in ["base64", "base64url"] do
      JSThrow.type_error!("Invalid base64 alphabet")
    end

    unless last_chunk_handling in ["loose", "strict", "stop-before-partial"] do
      JSThrow.type_error!("Invalid base64 lastChunkHandling")
    end
  end

  defp trim_base64_partial(source, "stop-before-partial") do
    case String.split(source, "=", parts: 2) do
      [prefix, suffix] ->
        case Base.decode64(source) do
          {:ok, _} ->
            source

          :error ->
            if suffix == "" and rem(String.length(prefix), 4) == 2 do
              binary_part(prefix, 0, String.length(prefix) - 2)
            else
              JSThrow.syntax_error!("Invalid base64 string")
            end
        end

      [_] ->
        valid_prefix_length = base64_valid_prefix_length(source)

        source =
          if valid_prefix_length < String.length(source) do
            if valid_prefix_length < 4 do
              JSThrow.syntax_error!("Invalid base64 string")
            else
              binary_part(source, 0, valid_prefix_length)
            end
          else
            source
          end

        case rem(String.length(source), 4) do
          0 -> source
          remainder -> binary_part(source, 0, String.length(source) - remainder)
        end
    end
  end

  defp trim_base64_partial(source, "strict") do
    if rem(String.length(source), 4) != 0 do
      JSThrow.syntax_error!("Invalid base64 string")
    end

    source
  end

  defp trim_base64_partial(source, _), do: source

  defp base64_valid_prefix_length(source) do
    source
    |> String.graphemes()
    |> Enum.take_while(&Regex.match?(~r/[A-Za-z0-9+\/_=-]/, &1))
    |> Enum.join()
    |> String.length()
  end

  defp validate_base64_source!(source) do
    cond do
      Regex.match?(~r/[^A-Za-z0-9+\/=]/, source) ->
        JSThrow.syntax_error!("Invalid base64 string")

      String.contains?(source, "=") and rem(String.length(source), 4) != 0 ->
        JSThrow.syntax_error!("Invalid base64 string")

      String.contains?(source, "=") and not Regex.match?(~r/^[A-Za-z0-9+\/]*={0,2}$/, source) ->
        JSThrow.syntax_error!("Invalid base64 string")

      String.ends_with?(source, "===") ->
        JSThrow.syntax_error!("Invalid base64 string")

      true ->
        :ok
    end
  end

  defp pad_base64(source) do
    case rem(String.length(source), 4) do
      0 -> source
      1 -> JSThrow.syntax_error!("Invalid base64 string")
      remainder -> source <> String.duplicate("=", 4 - remainder)
    end
  end

  defp maybe_base64url(encoded, "base64url") do
    encoded |> String.replace("+", "-") |> String.replace("/", "_")
  end

  defp maybe_base64url(encoded, _alphabet), do: encoded

  defp maybe_omit_base64_padding(encoded, true), do: String.trim_trailing(encoded, "=")
  defp maybe_omit_base64_padding(encoded, _), do: encoded

  defp decode_base64_prefix_before_error(source, alphabet) do
    normalized = String.replace(source, ~r/[\t\n\f\r ]/, "")

    normalized =
      case alphabet do
        "base64url" -> normalized |> String.replace("-", "+") |> String.replace("_", "/")
        _ -> normalized
      end

    prefix =
      normalized
      |> String.graphemes()
      |> Enum.take_while(&Regex.match?(~r/[A-Za-z0-9+\/]/, &1))
      |> Enum.join()

    full_len = div(String.length(prefix), 4) * 4

    if full_len == 0 do
      []
    else
      case Base.decode64(binary_part(prefix, 0, full_len)) do
        {:ok, binary} -> :binary.bin_to_list(binary)
        :error -> []
      end
    end
  end

  defp validate_base64_alphabet_source!(source, "base64") do
    if Regex.match?(~r/[-_]/, source), do: JSThrow.syntax_error!("Invalid base64 string")
  end

  defp validate_base64_alphabet_source!(source, "base64url") do
    if Regex.match?(~r/[+\/]/, source), do: JSThrow.syntax_error!("Invalid base64 string")
  end

  defp base64_option(:undefined, _key, default), do: default
  defp base64_option(nil, _key, default), do: default

  defp base64_option(options, key, default) do
    case Get.get(options, key) do
      value when value in [:undefined, nil] -> default
      value when is_binary(value) -> value
      _ -> JSThrow.type_error!("Invalid base64 option")
    end
  end

  defp require_string_argument!(value, _name) when is_binary(value), do: value

  defp require_string_argument!(_value, name) do
    JSThrow.type_error!("#{name} requires a string")
  end

  defp uint8array_from_bytes(bytes) do
    ctor =
      Runtime.global_constructor("Uint8Array") || {:builtin, "Uint8Array", constructor(:uint8)}

    Invocation.construct_runtime(ctor, ctor, [bytes])
  end

  defp require_uint8array_receiver!({:obj, ref} = obj, name) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true, type_key() => :uint8} -> obj
      _ -> JSThrow.type_error!("#{name} called on incompatible receiver")
    end
  end

  defp require_uint8array_receiver!(_this, name) do
    JSThrow.type_error!("#{name} called on incompatible receiver")
  end

  defp uint8array_bytes(target) do
    for index <- 0..(element_count(target) - 1)//1, do: get_element(target, index)
  end

  defp write_prefix_bytes(target, bytes, capacity) do
    bytes
    |> Enum.take(capacity)
    |> Enum.with_index()
    |> Enum.each(fn {byte, index} -> set_element(target, index, byte) end)

    min(length(bytes), capacity)
  end

  defp result_object(properties), do: Heap.wrap(properties)

  static_methods do
    @ecma "23.2.3.4"
    symbol :species do
      get do
        this
      end
    end
  end

  @ecma "23.2.3.2"
  proto_getter "buffer" do
    prototype_buffer(this)
  end

  @ecma "23.2.3.3"
  proto_getter "byteLength" do
    prototype_byte_length(this)
  end

  @ecma "23.2.3.4"
  proto_getter "byteOffset" do
    prototype_byte_offset(this)
  end

  @ecma "23.2.3.21"
  proto_getter "length" do
    prototype_length(this)
  end

  prototype_methods do
    @ecma "23.2.3.38"
    symbol :toStringTag do
      get do
        prototype_to_string_tag(this)
      end
    end
  end

  @doc "Returns typed-array type descriptors supported by the runtime."
  defdelegate types, to: Metadata

  @doc "Returns the typed-array element type for a constructor name, when known."
  defdelegate constructor_type(name), to: Metadata

  @doc "Classifies a property key using integer-indexed exotic object rules."
  def integer_index_key(key) when is_binary(key) do
    cond do
      key == "-0" ->
        :invalid

      Regex.match?(~r/^-[0-9]+$/, key) ->
        :invalid

      canonical_nonnegative_integer_string?(key) ->
        {:ok, String.to_integer(key)}

      canonical_non_integral_numeric_string?(key) ->
        :invalid

      true ->
        :not_integer_index
    end
  end

  def integer_index_key(key) when is_float(key) and key == 0.0, do: {:ok, 0}

  def integer_index_key(key) do
    case PropertyKey.integer_index(key) do
      {:ok, idx} -> {:ok, idx}
      :error -> invalid_integer_index_key(key)
    end
  end

  defp canonical_nonnegative_integer_string?("0"), do: true

  defp canonical_nonnegative_integer_string?(key) do
    Regex.match?(~r/^[1-9][0-9]*$/, key) and String.length(key) < 22
  end

  defp canonical_non_integral_numeric_string?(key) when key in ["NaN", "Infinity", "-Infinity"],
    do: true

  defp canonical_non_integral_numeric_string?(key) do
    case Float.parse(key) do
      {number, ""} when number != trunc(number) ->
        QuickBEAM.VM.Semantics.Values.stringify(number) == key

      _ ->
        false
    end
  end

  defp invalid_integer_index_key(key) when is_integer(key), do: :invalid
  defp invalid_integer_index_key(_key), do: :not_integer_index

  @doc "Returns whether an object map stores a typed-array instance for a constructor name."
  def instance_for_constructor?(
        %{"__typed_array__" => true, "__type__" => type},
        constructor_name
      ),
      do: constructor_type(constructor_name) == type

  def instance_for_constructor?(_, _), do: false

  @doc "Returns the byte width for a typed-array element type."
  defdelegate elem_size(type), to: Metadata

  def prevalidate_construct_args!([first | _]) do
    if QuickBEAM.VM.Value.symbol?(first) do
      JSThrow.type_error!("Cannot convert Symbol to index")
    end
  end

  def prevalidate_construct_args!(_args), do: :ok

  @doc "Returns generic properties for typed-array constructor prototype objects."
  def prototype_properties do
    proto_property_names()
    |> Enum.reject(
      &(&1 in ["buffer", "byteLength", "byteOffset", "length", {:symbol, "Symbol.toStringTag"}])
    )
    |> Enum.into(%{}, fn key -> {key, proto_property(key)} end)
  end

  @ecma "23.2.3.1"
  proto "at", length: 1 do
    at(this, args)
  end

  @ecma "23.2.3.6"
  proto "copyWithin", length: 2 do
    typed_array_ref_method(this, args, &copy_within/3)
  end

  @ecma "23.2.3.7"
  proto "entries", length: 0 do
    typed_array_iterator(this, :entries)
  end

  @ecma "23.2.3.19"
  proto "keys", length: 0 do
    typed_array_iterator(this, :keys)
  end

  @ecma "23.2.3.35"
  proto "values", length: 0 do
    typed_array_iterator(this, :values)
  end

  prototype_methods do
    @ecma "23.2.3.37"
    symbol :iterator do
      method length: 0 do
        typed_array_iterator(this, :values)
      end
    end
  end

  @ecma "23.2.3.8"
  proto "every", length: 1 do
    typed_array_ref_method(this, args, &every/3)
  end

  @ecma "23.2.3.9"
  proto "fill", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> fill(ref, call_args) end)
  end

  @ecma "23.2.3.10"
  proto "filter", length: 1 do
    typed_array_ref_method(this, args, &filter/3)
  end

  @ecma "23.2.3.11"
  proto "find", length: 1 do
    typed_array_ref_method(this, args, &find/3)
  end

  @ecma "23.2.3.12"
  proto "findIndex", length: 1 do
    typed_array_ref_method(this, args, &find_index/3)
  end

  @ecma "23.2.3.13"
  proto "findLast", length: 1 do
    typed_array_ref_method(this, args, &find_last/3)
  end

  @ecma "23.2.3.14"
  proto "findLastIndex", length: 1 do
    typed_array_ref_method(this, args, &find_last_index/3)
  end

  @ecma "23.2.3.15"
  proto "forEach", length: 1 do
    typed_array_ref_method(this, args, &for_each/3)
  end

  @ecma "23.2.3.16"
  proto "includes", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> includes(ref, call_args) end)
  end

  @ecma "23.2.3.17"
  proto "indexOf", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> index_of(ref, call_args) end)
  end

  @ecma "23.2.3.18"
  proto "join", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> join(ref, call_args) end)
  end

  @ecma "23.2.3.20"
  proto "lastIndexOf", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this ->
      last_index_of(ref, call_args)
    end)
  end

  @ecma "23.2.3.22"
  proto "map", length: 1 do
    typed_array_ref_method(this, args, &map/3)
  end

  @ecma "23.2.3.23"
  proto "reduce", length: 1 do
    typed_array_ref_method(this, args, &reduce/3)
  end

  @ecma "23.2.3.24"
  proto "reduceRight", length: 1 do
    typed_array_ref_method(this, args, &reduce_right/3)
  end

  @ecma "23.2.3.25"
  proto "reverse", length: 0 do
    typed_array_ref_method(this, args, fn ref, _call_args, _this -> reverse(ref) end)
  end

  @ecma "23.2.3.26"
  proto "set", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> set(ref, call_args) end)
  end

  @ecma "23.2.3.27"
  proto "slice", length: 2 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> slice(ref, call_args) end)
  end

  @ecma "23.2.3.28"
  proto "some", length: 1 do
    typed_array_ref_method(this, args, &some/3)
  end

  @ecma "23.2.3.29"
  proto "sort", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> sort(ref, call_args) end)
  end

  @ecma "23.2.3.30"
  proto "subarray", length: 2 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> subarray(ref, call_args) end)
  end

  @ecma "23.2.3.31"
  proto "toLocaleString", length: 0 do
    typed_array_ref_method(this, args, fn ref, _call_args, _this -> to_locale_string(ref) end)
  end

  @ecma "23.2.3.32"
  proto "toReversed", length: 0 do
    typed_array_ref_method(this, args, fn ref, _call_args, _this -> to_reversed(ref) end)
  end

  @ecma "23.2.3.33"
  proto "toSorted", length: 1 do
    typed_array_ref_method(this, args, fn ref, call_args, _this -> to_sorted(ref, call_args) end)
  end

  @ecma "23.2.3.34"
  proto "toString", length: 0 do
    typed_array_ref_method(this, args, fn ref, _call_args, _this -> join(ref, [","]) end)
  end

  @ecma "23.2.3.36"
  proto "with", length: 2 do
    typed_array_ref_method(this, args, fn ref, call_args, _this ->
      with_element(ref, call_args)
    end)
  end

  defp typed_array_iterator(this, mode) do
    {:obj, ref} = this = typed_array_object!(this)
    ensure_not_out_of_bounds(ref)
    Array.make_array_iterator(this, mode)
  end

  defp typed_array_ref_method(this, args, callback) do
    {:obj, ref} = typed_array_object!(this)
    callback.(ref, args, this)
  end

  @doc "Returns properties installed on %TypedArray%.prototype."
  def base_prototype_properties do
    proto_property_names()
    |> Enum.into(%{}, fn key -> {key, proto_property(key)} end)
  end

  defp prototype_buffer(this), do: typed_array_state!(this) |> Map.get("buffer", :undefined)

  defp prototype_byte_length(this) do
    obj = typed_array_object!(this)
    if out_of_bounds?(obj), do: 0, else: current_byte_length(obj)
  end

  defp prototype_byte_offset(this) do
    obj = typed_array_object!(this)
    if out_of_bounds?(obj), do: 0, else: Map.get(typed_array_state!(obj), offset(), 0)
  end

  defp prototype_length(this) do
    obj = typed_array_object!(this)
    if out_of_bounds?(obj), do: 0, else: element_count(obj)
  end

  defp prototype_to_string_tag({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true, type_key() => type} -> Metadata.name(type)
      _ -> :undefined
    end
  end

  defp prototype_to_string_tag(_), do: :undefined

  defp typed_array_object!({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} -> obj
      _ -> JSThrow.type_error!("TypedArray expected")
    end
  end

  defp typed_array_object!(_), do: JSThrow.type_error!("TypedArray expected")

  defp typed_array_state!(obj) do
    {:obj, ref} = typed_array_object!(obj)
    Heap.get_obj(ref, %{})
  end

  def static_from(args, constructor) do
    {source, map_fn, this_arg} = from_args(args)

    {values, map_fn, this_arg} = typed_array_from_values_for_target(source, map_fn, this_arg)
    target = Invocation.construct_runtime(constructor, constructor, [length(values)])
    typed_target = typed_array_object!(target)
    require_typed_array_capacity!(typed_target, length(values))

    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      mapped_value =
        if map_fn == :__missing__ do
          value
        else
          Invocation.invoke_with_receiver(map_fn, [value, index], this_arg)
        end

      set_element(typed_target, index, mapped_value)
    end)

    target
  end

  defp require_typed_array_capacity!(target, required_length) do
    if element_count(target) < required_length do
      JSThrow.type_error!("TypedArray target is too small")
    end
  end

  def static_of(args, constructor) do
    target = Invocation.construct_runtime(constructor, constructor, [length(args)])
    typed_target = typed_array_object!(target)
    require_typed_array_capacity!(typed_target, length(args))

    args
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> set_element(typed_target, index, value) end)

    target
  end

  defp from_args([source, :undefined | _]), do: {source, :__missing__, :undefined}
  defp from_args([source, map_fn, this_arg | _]), do: {source, map_fn, this_arg}
  defp from_args([source, map_fn | _]), do: {source, map_fn, :undefined}
  defp from_args([source | _]), do: {source, :__missing__, :undefined}
  defp from_args(_), do: {nil, nil, :undefined}

  defp typed_array_from_values_for_target(source, map_fn, this_arg) do
    validate_from_map_fn!(map_fn)
    {typed_array_source_values(source), map_fn, this_arg}
  end

  defp validate_from_map_fn!(map_fn) do
    if map_fn != :__missing__ and not QuickBEAM.VM.Builtin.callable?(map_fn) do
      JSThrow.type_error!("mapfn is not callable")
    end
  end

  defp typed_array_source_values(source) do
    iterator = Get.get(source, {:symbol, "Symbol.iterator"})

    cond do
      QuickBEAM.VM.Builtin.callable?(iterator) ->
        Iterators.iterable_to_list(source)

      not Value.nullish?(iterator) ->
        JSThrow.type_error!("@@iterator is not callable")

      true ->
        len = max(Runtime.to_int(Get.get(source, "length")), 0)
        array_like_to_list_with_length(source, len)
    end
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor(type) do
    fn args, this ->
      {buf, offset, len, orig_buf, length_tracking?} = parse_args(args, type)
      ref = make_ref()
      proto = typed_array_instance_proto(this, type)

      obj =
        object heap: false, extends: proto do
          prop(typed_array(), true)
          prop(type_key(), type)
          prop(buffer(), buf)
          prop(offset(), offset)
          prop("length", len)
          prop("byteLength", len * elem_size(type))
          prop("byteOffset", offset)
          prop("BYTES_PER_ELEMENT", elem_size(type))
          prop("__length_tracking__", length_tracking?)
          prop("__fixed_length__", len)
          prop("__fixed_byte_length__", len * elem_size(type))
          prop("buffer", orig_buf || make_buffer_ref(buf))
        end

      Heap.put_obj(ref, obj)
      register_buffer_view(orig_buf, ref)
      {:obj, ref}
    end
  end

  defp typed_array_instance_proto({:obj, ref}, type) do
    case Heap.get_obj(ref, %{}) do
      %{__proto__: proto} -> proto
      %{"__proto__" => proto} -> proto
      _ -> class_proto_for(type)
    end
  end

  defp typed_array_instance_proto(_, type), do: class_proto_for(type)

  def constructor_static_property(name, _ctor, {:symbol, "Symbol.species"}) do
    if constructor_type(name) != nil do
      {:accessor, {:builtin, "get [Symbol.species]", fn _args, this -> this end}, nil}
    else
      :undefined
    end
  end

  def constructor_static_property(name, ctor, "prototype") do
    if constructor_type(name) != nil, do: constructor_prototype(name, ctor), else: :undefined
  end

  def constructor_static_property(name, _ctor, "BYTES_PER_ELEMENT") do
    case Map.fetch(types(), name) do
      {:ok, type} -> elem_size(type)
      :error -> :undefined
    end
  end

  def constructor_static_property(_name, _ctor, _key), do: :undefined

  def constructor_prototype(name, ctor),
    do: TypedArrayInstallation.constructor_prototype(name, ctor, __MODULE__)

  defp class_proto_for(type) do
    name = Metadata.name(type)

    Runtime.global_class_proto(name) ||
      constructor_prototype(
        name,
        {:builtin, name, constructor(type)}
      )
  end

  defp register_buffer_view({:obj, buf_ref}, view_ref) do
    case Heap.get_obj(buf_ref, %{}) do
      map when is_map(map) ->
        Heap.put_obj(buf_ref, Map.update(map, "__views__", [view_ref], &[view_ref | &1]))

      _ ->
        :ok
    end
  end

  defp register_buffer_view(_, _), do: :ok

  # ── Element access (public, used by ObjectModel.Put) ──

  @doc "Returns whether a typed-array object is backed by immutable data."
  def metadata_key?(key), do: key in ["buffer", "byteLength", "byteOffset", "length"]

  @doc "Returns the element type for a typed-array value."
  def element_type({:obj, ref}), do: type(ref)

  @doc "Returns whether a typed-array view is backed by a SharedArrayBuffer."
  def shared_buffer?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"buffer" => {:obj, buffer_ref}} ->
        Heap.get_obj(buffer_ref, %{})
        |> Map.get("__array_buffer_kind__")
        |> Kernel.==(:shared_array_buffer)

      _ ->
        false
    end
  end

  def immutable?({:obj, ref}) do
    is_immutable_buffer?(Heap.get_obj(ref, %{}))
  end

  @doc "Reads an element from a typed-array value."
  def get_element({:obj, ref}, idx) do
    b = buf(ref)
    if b == nil, do: :undefined, else: read_element(b, idx, type(ref))
  end

  @doc "Returns whether a typed-array view is currently out of bounds."
  def out_of_bounds?({:obj, ref}) do
    s = state(ref)

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          %{"__detached__" => true} ->
            true

          m when is_map(m) ->
            byte_len = byte_size(Map.get(m, buffer(), Map.get(s, buffer(), <<>>)))
            offset = Map.get(s, offset(), 0)

            if Map.get(s, "__length_tracking__") do
              byte_len < offset
            else
              fixed = Map.get(s, "__fixed_byte_length__", Map.get(s, "byteLength", 0))
              max(byte_len - offset, 0) < fixed
            end

          _ ->
            false
        end

      _ ->
        false
    end
  end

  def out_of_bounds?(_), do: false

  @doc "Returns the currently addressable element count for a typed-array value."
  def element_count({:obj, ref}) do
    s = state(ref)

    if Map.get(s, "__length_tracking__") do
      div(max(byte_size(buf(ref) || <<>>), 0), elem_size(type(ref)))
    else
      Map.get(s, "__fixed_length__", Map.get(s, "length", 0))
    end
  end

  @doc "Returns the currently addressable byte length for a typed-array value."
  def current_byte_length({:obj, ref}) do
    element_count({:obj, ref}) * elem_size(type(ref))
  end

  @doc "Returns the value after typed-array element conversion for the given element type."
  def normalized_element(value, type) do
    converted = TypedArrayCoercion.element_value(value, type)
    buffer = :binary.copy(<<0>>, elem_size(type))
    read_element(write_element(buffer, 0, converted, type), 0, type)
  end

  @doc "Writes an element to a typed-array value."
  def set_element({:obj, ref}, idx, val) do
    ta = Heap.get_obj(ref, %{})

    if Map.get(ta, "__immutable__") || is_immutable_buffer?(ta) do
      :ok
    else
      t = Map.get(ta, type_key(), :uint8)
      value = TypedArrayCoercion.element_value(val, t)

      unless out_of_bounds?({:obj, ref}) do
        new_buf = write_element(buf(ref) || <<>>, idx, value, t)
        update_buffer(ref, new_buf)
        delete_shadowed_views(ref, idx, elem_size(t))
      end
    end
  end

  defp delete_shadowed_views(ref, idx, write_size) do
    case Heap.get_obj(ref, %{}) do
      %{"buffer" => {:obj, buf_ref}} = writer ->
        write_start = Map.get(writer, offset(), 0) + idx * write_size
        write_end = write_start + write_size

        case Heap.get_obj(buf_ref, %{}) do
          %{"__views__" => views} when is_list(views) ->
            Enum.each(views, fn view_ref ->
              view = Heap.get_obj(view_ref, %{})
              view_offset = Map.get(view, offset(), 0)
              view_size = Map.get(view, "BYTES_PER_ELEMENT", 1)
              first = max(0, div(write_start - view_offset, view_size))
              last = max(0, div(max(write_end - 1 - view_offset, 0), view_size))

              for view_idx <- first..last do
                elem_start = view_offset + view_idx * view_size
                elem_end = elem_start + view_size

                if elem_start < write_end and elem_end > write_start do
                  Heap.delete_array_prop(view_ref, Integer.to_string(view_idx))
                end
              end
            end)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_immutable_buffer?(ta) do
    case Map.get(ta, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          m when is_map(m) -> Map.get(m, "__immutable__", false)
          _ -> false
        end

      _ ->
        false
    end
  end

  # ── State readers ──

  defp state(ref), do: Heap.get_obj(ref, %{})

  defp buf(ref) do
    s = state(ref)

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          m when is_map(m) ->
            if Map.get(m, "__detached__") do
              nil
            else
              ab_buf = Map.get(m, buffer(), Map.get(s, buffer(), <<>>))
              offset = Map.get(s, offset(), 0)
              byte_len = current_view_byte_length(s, ab_buf, offset)

              cond do
                byte_len == 0 ->
                  nil

                offset == 0 and byte_len == byte_size(ab_buf) ->
                  ab_buf

                offset + byte_len <= byte_size(ab_buf) ->
                  binary_part(ab_buf, offset, byte_len)

                offset < byte_size(ab_buf) ->
                  binary_part(ab_buf, offset, byte_size(ab_buf) - offset)

                true ->
                  nil
              end
            end

          _ ->
            Map.get(s, buffer(), <<>>)
        end

      _ ->
        Map.get(s, buffer(), <<>>)
    end
  end

  defp len(ref), do: element_count({:obj, ref})
  defp type(ref), do: Map.get(state(ref), type_key(), :uint8)

  defp current_view_byte_length(s, ab_buf, offset) do
    available = max(byte_size(ab_buf) - offset, 0)

    if Map.get(s, "__length_tracking__") do
      available
    else
      fixed = Map.get(s, "byteLength", available)
      if available < fixed, do: 0, else: fixed
    end
  end

  # ── Method implementations ──

  defp at(nil, _args),
    do: JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")

  defp at(:undefined, _args),
    do: JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")

  defp at({:obj, ref} = obj, args) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        if out_of_bounds?(obj) do
          JSThrow.type_error!("TypedArray is out of bounds")
        end

        len = element_count(obj)

        relative_index =
          args |> Enum.at(0, :undefined) |> TypedArrayCoercion.integer_or_infinity()

        case relative_index do
          :infinity ->
            :undefined

          :neg_infinity ->
            :undefined

          index ->
            idx = if index < 0, do: len + index, else: index

            if idx < 0 or idx >= len do
              :undefined
            else
              get_element(obj, idx)
            end
        end

      _ ->
        JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")
    end
  end

  defp at(_, _args),
    do: JSThrow.type_error!("TypedArray.prototype.at called on incompatible receiver")

  defp set(ref, args) do
    source = arg(args, 0, :undefined)
    offset = args |> arg(1, 0) |> TypedArrayCoercion.integer_or_infinity()

    if offset in [:infinity, :neg_infinity] or offset < 0 do
      JSThrow.range_error!("offset is out of bounds")
    end

    if out_of_bounds?({:obj, ref}) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end

    target_len = len(ref)
    validate_typed_array_set_content_type!(type(ref), source)

    {source_len, source_getter} = typed_array_set_source(source)

    if offset + source_len > target_len do
      JSThrow.range_error!("source is too large")
    end

    if source_len > 0 do
      for index <- 0..(source_len - 1) do
        set_element({:obj, ref}, offset + index, source_getter.(index))
      end
    end

    :undefined
  end

  defp validate_typed_array_set_content_type!(target_type, {:obj, source_ref} = source) do
    case Heap.get_obj(source_ref, %{}) do
      %{typed_array() => true} ->
        if bigint_element_type?(target_type) != bigint_element_type?(type(elem(source, 1))) do
          JSThrow.type_error!("Cannot mix BigInt and other types")
        end

      _ ->
        :ok
    end
  end

  defp validate_typed_array_set_content_type!(_target_type, _source), do: :ok

  defp bigint_element_type?(type), do: type in [:bigint64, :biguint64]

  defp typed_array_set_source(nil),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp typed_array_set_source(:undefined),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp typed_array_set_source({:obj, ref} = source) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        if out_of_bounds?(source) do
          JSThrow.type_error!("TypedArray source is out of bounds")
        end

        len = element_count(source)

        values =
          if len == 0, do: [], else: for(index <- 0..(len - 1), do: get_element(source, index))

        {len, &Enum.at(values, &1, :undefined)}

      _ ->
        len = max(Runtime.to_int(Get.get(source, "length")), 0)
        {len, fn index -> Get.get(source, Integer.to_string(index)) end}
    end
  end

  defp typed_array_set_source({:qb_arr, arr}) do
    len = :array.size(arr)
    {len, fn index -> :array.get(index, arr) end}
  end

  defp typed_array_set_source(source) when is_list(source),
    do: {length(source), &Enum.at(source, &1, :undefined)}

  defp typed_array_set_source(source) when is_binary(source) do
    chars = String.graphemes(source)
    {length(chars), &Enum.at(chars, &1, :undefined)}
  end

  defp typed_array_set_source(source) when is_number(source) or is_boolean(source),
    do: {0, fn _ -> :undefined end}

  defp typed_array_set_source({:bigint, _}), do: {0, fn _ -> :undefined end}
  defp typed_array_set_source({:symbol, _}), do: {0, fn _ -> :undefined end}
  defp typed_array_set_source({:symbol, _, _}), do: {0, fn _ -> :undefined end}

  defp typed_array_set_source(source) do
    values = Heap.to_list(source)
    {length(values), &Enum.at(values, &1, :undefined)}
  end

  defp subarray(ref, args) do
    obj = {:obj, ref}
    l = if out_of_bounds?(obj), do: 0, else: len(ref)
    t = type(ref)
    s = relative_index(arg(args, 0, 0), l)

    end_arg = Enum.at(args, 1, :undefined)

    e =
      case end_arg do
        :undefined -> l
        value -> relative_index(value, l)
      end

    new_len = max(0, e - s)
    es = elem_size(t)
    parent = state(ref)
    byte_offset = Map.get(parent, offset(), 0) + s * es

    length_arg =
      if Map.get(parent, "__length_tracking__") and end_arg == :undefined,
        do: :auto,
        else: new_len

    typed_array_species_create_view(
      {:obj, ref},
      t,
      Map.get(parent, "buffer"),
      byte_offset,
      length_arg
    )
  end

  defp copy_within(ref, args, _this) do
    obj = {:obj, ref}

    if out_of_bounds?(obj) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end

    l = len(ref)
    target = relative_index(arg(args, 0, :undefined), l)
    start = relative_index(arg(args, 1, :undefined), l)

    final =
      case Enum.at(args, 2, :undefined) do
        :undefined -> l
        value -> relative_index(value, l)
      end

    if out_of_bounds?(obj) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end

    current_len = len(ref)

    count =
      min(final - start, l - target) |> min(current_len - target) |> min(current_len - start)

    if count > 0 do
      t = type(ref)
      b = buf(ref) || <<>>
      values = for i <- 0..(count - 1), do: read_element(b, start + i, t)

      new_buf =
        values
        |> Enum.with_index(target)
        |> Enum.reduce(b, fn {value, index}, acc -> write_element(acc, index, value, t) end)

      update_buffer(ref, new_buf)
    end

    obj
  end

  defp relative_index(value, len) do
    case TypedArrayCoercion.integer_or_infinity(value) do
      :neg_infinity -> 0
      :infinity -> len
      index when index < 0 -> max(len + index, 0)
      index -> min(index, len)
    end
  end

  defp join(ref, args) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    t = type(ref)

    sep =
      case args do
        [] -> ","
        [:undefined | _] -> ","
        [s | _] -> typed_array_to_string(s)
      end

    b = buf(ref)

    if l == 0 do
      ""
    else
      Enum.map_join(0..(l - 1), sep, &typed_array_join_value(read_element(b, &1, t)))
    end
  end

  defp typed_array_join_value(:undefined), do: ""
  defp typed_array_join_value(nil), do: ""
  defp typed_array_join_value(value), do: typed_array_to_string(value)

  defp to_locale_string(ref) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    obj = {:obj, ref}

    if l == 0 do
      ""
    else
      Enum.map_join(0..(l - 1), ",", fn index ->
        case get_element(obj, index) do
          value when value in [:undefined, nil] ->
            ""

          value ->
            method = Get.get(value, "toLocaleString")
            method |> Invocation.invoke_with_receiver([], value) |> typed_array_to_string()
        end
      end)
    end
  end

  defp typed_array_to_string({:symbol, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp typed_array_to_string({:symbol, _, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a string")

  defp typed_array_to_string(value), do: Runtime.stringify(value)

  defp for_each(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    this_arg = arg(rest, 0, :undefined)

    if l > 0 do
      for i <- 0..(l - 1) do
        Invocation.invoke_with_receiver(cb, [get_element({:obj, ref}, i), i, this], this_arg)
      end
    end

    :undefined
  end

  defp for_each(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp map(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    t = type(ref)
    this_arg = arg(rest, 0, :undefined)

    result = typed_array_species_create({:obj, ref}, t, l)

    if l > 0 do
      for i <- 0..(l - 1) do
        value =
          Invocation.invoke_with_receiver(cb, [get_element({:obj, ref}, i), i, this], this_arg)

        set_element(result, i, value)
      end
    end

    result
  end

  defp map(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp filter(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    t = type(ref)
    this_arg = arg(rest, 0, :undefined)

    vals =
      if l == 0 do
        []
      else
        for i <- 0..(l - 1),
            (
              v = get_element({:obj, ref}, i)
              Runtime.truthy?(Invocation.invoke_with_receiver(cb, [v, i, this], this_arg))
            ),
            do: v
      end

    result = typed_array_species_create({:obj, ref}, t, length(vals))

    vals
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> set_element(result, index, value) end)

    result
  end

  defp filter(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp every(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    this_arg = arg(rest, 0, :undefined)

    l == 0 or
      Enum.all?(0..(l - 1), fn index ->
        cb
        |> Invocation.invoke_with_receiver(
          [get_element({:obj, ref}, index), index, this],
          this_arg
        )
        |> Runtime.truthy?()
      end)
  end

  defp every(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp some(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    this_arg = arg(rest, 0, :undefined)

    l > 0 and
      Enum.any?(0..(l - 1), fn index ->
        cb
        |> Invocation.invoke_with_receiver(
          [get_element({:obj, ref}, index), index, this],
          this_arg
        )
        |> Runtime.truthy?()
      end)
  end

  defp some(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp reduce(ref, args, this) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    cb = arg(args, 0, nil)
    callback!(cb)
    init = arg(args, 1, :__missing__)

    cond do
      l == 0 and init == :__missing__ ->
        JSThrow.type_error!("Reduce of empty typed array with no initial value")

      l == 0 ->
        init

      true ->
        {start, acc} =
          if init == :__missing__, do: {1, get_element({:obj, ref}, 0)}, else: {0, init}

        if start >= l do
          acc
        else
          Enum.reduce(start..(l - 1), acc, fn i, a ->
            Invocation.invoke_with_receiver(
              cb,
              [a, get_element({:obj, ref}, i), i, this],
              :undefined
            )
          end)
        end
    end
  end

  defp reduce_right(ref, args, this) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    cb = arg(args, 0, nil)
    callback!(cb)
    init = arg(args, 1, :__missing__)

    cond do
      l == 0 and init == :__missing__ ->
        JSThrow.type_error!("Reduce of empty typed array with no initial value")

      l == 0 ->
        init

      true ->
        {start, acc} =
          if init == :__missing__,
            do: {l - 2, get_element({:obj, ref}, l - 1)},
            else: {l - 1, init}

        if start < 0 do
          acc
        else
          Enum.reduce(start..0//-1, acc, fn i, a ->
            Invocation.invoke_with_receiver(
              cb,
              [a, get_element({:obj, ref}, i), i, this],
              :undefined
            )
          end)
        end
    end
  end

  defp index_of(ref, [target | rest]) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)

    if l == 0 do
      -1
    else
      obj = {:obj, ref}
      start = relative_index(arg(rest, 0, 0), l)

      cond do
        start >= l ->
          -1

        out_of_bounds?(obj) ->
          -1

        true ->
          Enum.find_value(start..(l - 1), -1, fn i ->
            if strict_same_value?(get_element(obj, i), target), do: i
          end)
      end
    end
  end

  defp index_of(_ref, _args), do: -1

  defp last_index_of(ref, [target | rest]) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)

    if l == 0 do
      -1
    else
      obj = {:obj, ref}
      start = last_index_start(arg(rest, 0, l - 1), l)

      cond do
        start < 0 ->
          -1

        out_of_bounds?(obj) ->
          -1

        true ->
          Enum.find_value(start..0//-1, -1, fn i ->
            if strict_same_value?(get_element(obj, i), target), do: i
          end)
      end
    end
  end

  defp last_index_of(_ref, _args), do: -1

  defp includes(ref, [target | rest]) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)

    if l == 0 do
      false
    else
      start = relative_index(arg(rest, 0, 0), l)

      if start >= l do
        false
      else
        Enum.any?(start..(l - 1), fn i ->
          same_value_zero?(get_element({:obj, ref}, i), target)
        end)
      end
    end
  end

  defp includes(_ref, _args), do: false

  defp last_index_start(value, len) do
    case TypedArrayCoercion.integer_or_infinity(value) do
      :neg_infinity -> -1
      :infinity -> len - 1
      index when index < 0 -> len + index
      index -> min(index, len - 1)
    end
  end

  defp same_value_zero?(a, b), do: Values.same_value_zero?(a, b)
  defp strict_same_value?(a, b), do: Values.strict_eq(a, b)

  defp find(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    this_arg = arg(rest, 0, :undefined)

    if l == 0 do
      :undefined
    else
      Enum.find_value(0..(l - 1), :undefined, fn i ->
        v = get_element({:obj, ref}, i)

        if Runtime.truthy?(Invocation.invoke_with_receiver(cb, [v, i, this], this_arg)) do
          v
        end
      end)
    end
  end

  defp find(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp find_index(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    this_arg = arg(rest, 0, :undefined)

    if l == 0 do
      -1
    else
      Enum.find_value(0..(l - 1), -1, fn i ->
        v = get_element({:obj, ref}, i)

        if Runtime.truthy?(Invocation.invoke_with_receiver(cb, [v, i, this], this_arg)) do
          i
        end
      end)
    end
  end

  defp find_index(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp find_last(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    this_arg = arg(rest, 0, :undefined)

    if l == 0 do
      :undefined
    else
      Enum.find_value((l - 1)..0//-1, :undefined, fn i ->
        v = get_element({:obj, ref}, i)

        if Runtime.truthy?(Invocation.invoke_with_receiver(cb, [v, i, this], this_arg)) do
          v
        end
      end)
    end
  end

  defp find_last(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp find_last_index(ref, [cb | rest], this) do
    callback!(cb)
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    this_arg = arg(rest, 0, :undefined)

    if l == 0 do
      -1
    else
      Enum.find_value((l - 1)..0//-1, -1, fn i ->
        v = get_element({:obj, ref}, i)

        if Runtime.truthy?(Invocation.invoke_with_receiver(cb, [v, i, this], this_arg)) do
          i
        end
      end)
    end
  end

  defp find_last_index(_ref, _args, _this), do: JSThrow.type_error!("callbackfn is not callable")

  defp sort(ref, args) do
    obj = {:obj, ref}
    if out_of_bounds?(obj), do: JSThrow.type_error!("TypedArray is out of bounds")

    compare_fn = arg(args, 0, :undefined)

    if compare_fn != :undefined and not QuickBEAM.VM.Builtin.callable?(compare_fn) do
      JSThrow.type_error!("comparison function is not callable")
    end

    {b, l, t} = {buf(ref), len(ref), type(ref)}

    if l > 0 do
      vals = Enum.map(0..(l - 1), &read_element(b, &1, t)) |> sort_values(compare_fn)

      unless out_of_bounds?(obj) do
        current_len = len(ref)
        vals = Enum.take(vals, current_len)
        new_buf = rebuild_buffer(vals, buf(ref), t)
        update_buffer(ref, new_buf)
      end
    end

    obj
  end

  defp sort_values(values, compare_fn) when is_nullish(compare_fn) do
    values
    |> Enum.with_index()
    |> Enum.sort(fn {left, left_index}, {right, right_index} ->
      case default_sort_order(left, right) do
        :lt -> true
        :gt -> false
        :eq -> left_index <= right_index
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp sort_values(values, compare_fn) do
    values
    |> Enum.with_index()
    |> Enum.sort(fn {left, left_index}, {right, right_index} ->
      order =
        Runtime.to_number(Invocation.invoke_with_receiver(compare_fn, [left, right], :undefined))

      cond do
        order < 0 -> true
        order > 0 -> false
        true -> left_index <= right_index
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp default_sort_order(left, right) do
    cond do
      sort_nan?(left) and sort_nan?(right) -> :eq
      sort_nan?(left) -> :gt
      sort_nan?(right) -> :lt
      numeric_less?(left, right) -> :lt
      numeric_less?(right, left) -> :gt
      negative_zero?(left) and not negative_zero?(right) -> :lt
      not negative_zero?(left) and negative_zero?(right) -> :gt
      true -> :eq
    end
  end

  defp sort_nan?(value), do: Values.nan_number?(value)

  defp numeric_less?(:neg_infinity, :neg_infinity), do: false
  defp numeric_less?(:neg_infinity, _), do: true
  defp numeric_less?(_, :neg_infinity), do: false
  defp numeric_less?(:infinity, _), do: false
  defp numeric_less?(_, :infinity), do: true
  defp numeric_less?({:bigint, left}, {:bigint, right}), do: left < right
  defp numeric_less?(left, right), do: left < right

  defp negative_zero?(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 20]) == "-0.0"

  defp negative_zero?(_), do: false

  defp reverse(ref) do
    obj = {:obj, ref}
    if out_of_bounds?(obj), do: JSThrow.type_error!("TypedArray is out of bounds")

    {b, l, t} = {buf(ref), len(ref), type(ref)}

    if l > 0 do
      vals = Enum.map(0..(l - 1), &read_element(b, &1, t)) |> Enum.reverse()
      new_buf = rebuild_buffer(vals, b, t)
      update_buffer(ref, new_buf)
    end

    obj
  end

  defp to_reversed(ref) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    t = type(ref)

    vals =
      if l == 0 do
        []
      else
        Enum.map((l - 1)..0//-1, &get_element({:obj, ref}, &1))
      end

    constructor(t).([vals], nil)
  end

  defp to_sorted(ref, args) do
    ensure_not_out_of_bounds(ref)
    compare_fn = arg(args, 0, :undefined)

    if compare_fn != :undefined and not QuickBEAM.VM.Builtin.callable?(compare_fn) do
      JSThrow.type_error!("comparison function is not callable")
    end

    l = len(ref)
    t = type(ref)

    vals =
      if l == 0,
        do: [],
        else: Enum.map(0..(l - 1), &get_element({:obj, ref}, &1)) |> sort_values(compare_fn)

    constructor(t).([vals], nil)
  end

  defp with_element(ref, args) do
    ensure_not_out_of_bounds(ref)
    l = len(ref)
    t = type(ref)
    relative = TypedArrayCoercion.integer_or_infinity(arg(args, 0, :undefined))

    index =
      case relative do
        :neg_infinity -> -1
        :infinity -> l
        n when n < 0 -> l + n
        n -> n
      end

    numeric_value = TypedArrayCoercion.element_value(arg(args, 1, :undefined), t)
    current_len = len(ref)

    if index < 0 or index >= current_len do
      JSThrow.range_error!("Invalid index")
    end

    vals = if l == 0, do: [], else: Enum.map(0..(l - 1), &get_element({:obj, ref}, &1))
    vals = if index < l, do: List.replace_at(vals, index, numeric_value), else: vals
    constructor(t).([vals], nil)
  end

  defp slice(ref, args) do
    if out_of_bounds?({:obj, ref}) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end

    l = len(ref)
    t = type(ref)
    start = relative_index(arg(args, 0, 0), l)

    final =
      case Enum.at(args, 1, :undefined) do
        :undefined -> l
        value -> relative_index(value, l)
      end

    new_len = max(0, final - start)
    result = typed_array_species_create({:obj, ref}, t, new_len)

    if new_len > 0 do
      if out_of_bounds?({:obj, ref}) and not length_tracking?(ref) do
        JSThrow.type_error!("TypedArray is out of bounds")
      end

      source = {:obj, ref}

      for index <- 0..(new_len - 1) do
        set_element(result, index, slice_source_value(source, start + index, t))
      end
    end

    result
  end

  defp length_tracking?(ref) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> Map.get(map, "__length_tracking__") == true
      _ -> false
    end
  end

  defp slice_source_value(source, index, type) do
    value = get_element(source, index)

    if value == :undefined do
      typed_zero(type)
    else
      value
    end
  end

  defp typed_zero(type) when type in [:bigint64, :biguint64], do: {:bigint, 0}
  defp typed_zero(_type), do: 0

  defp get_species_ctor({:obj, _ref} = obj) do
    case Get.get(obj, "constructor") do
      :undefined ->
        nil

      ctor ->
        unless species_constructor_object?(ctor) do
          JSThrow.type_error!("constructor is not an object")
        end

        case Get.get(ctor, {:symbol, "Symbol.species"}) do
          species when is_nullish(species) -> nil
          species -> species
        end
    end
  end

  defp species_constructor_object?(value), do: Value.object_like?(value)

  defp typed_array_species_create(obj, default_type, length) do
    case construct_typed_array_species(obj, default_type, [length]) do
      {:obj, result_ref} = typed_result ->
        if out_of_bounds?(typed_result) do
          JSThrow.type_error!("TypedArray is out of bounds")
        end

        if len(result_ref) < length do
          JSThrow.type_error!("TypedArray species result is too short")
        end

        typed_result
    end
  end

  defp typed_array_species_create_view(obj, default_type, buffer_obj, byte_offset, :auto) do
    construct_typed_array_species(obj, default_type, [buffer_obj, byte_offset])
  end

  defp typed_array_species_create_view(obj, default_type, buffer_obj, byte_offset, length) do
    construct_typed_array_species(obj, default_type, [buffer_obj, byte_offset, length])
  end

  defp construct_typed_array_species(obj, default_type, args) do
    case get_species_ctor(obj) do
      nil ->
        constructor(default_type).(args, nil)

      ctor ->
        unless QuickBEAM.VM.Builtin.callable?(ctor) do
          JSThrow.type_error!("TypedArray species constructor is not a constructor")
        end

        ctor
        |> Invocation.construct_runtime(ctor, args)
        |> typed_array_object!()
    end
  end

  defp fill(ref, args) do
    obj = {:obj, ref}

    if out_of_bounds?(obj) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end

    l = len(ref)
    t = type(ref)
    val = arg(args, 0, :undefined) |> TypedArrayCoercion.element_value(t)
    start = relative_index(arg(args, 1, 0), l)

    final =
      case Enum.at(args, 2, :undefined) do
        :undefined -> l
        value -> relative_index(value, l)
      end

    if out_of_bounds?(obj) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end

    if final > start do
      new_buf =
        Enum.reduce(start..(final - 1), buf(ref) || <<>>, fn index, acc ->
          write_element(acc, index, val, t)
        end)

      update_buffer(ref, new_buf)
    end

    obj
  end

  defp update_buffer(ref, new_buf) do
    s = state(ref)
    Heap.put_obj(ref, Map.put(s, buffer(), new_buf))

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        buf_map = Heap.get_obj(buf_ref, %{})

        if is_map(buf_map) do
          offset = Map.get(s, offset(), 0)
          ab_buf = Map.get(buf_map, buffer(), <<>>)

          before =
            if offset > 0, do: binary_part(ab_buf, 0, min(offset, byte_size(ab_buf))), else: <<>>

          after_offset = offset + byte_size(new_buf)

          after_part =
            if after_offset < byte_size(ab_buf),
              do: binary_part(ab_buf, after_offset, byte_size(ab_buf) - after_offset),
              else: <<>>

          merged = before <> new_buf <> after_part
          Heap.put_obj(buf_ref, Map.put(buf_map, buffer(), merged))
        end

      _ ->
        :ok
    end
  end

  # ── Helpers ──

  defp decode_float16(bits) do
    sign = Bitwise.bsr(bits, 15) |> Bitwise.band(1)
    exp = Bitwise.bsr(bits, 10) |> Bitwise.band(0x1F)
    frac = Bitwise.band(bits, 0x3FF)
    s = if sign == 1, do: -1.0, else: 1.0

    cond do
      exp == 0 and frac == 0 -> s * 0.0
      exp == 0 -> s * frac * :math.pow(2, -24)
      exp == 31 and frac == 0 -> if(s == -1.0, do: :neg_infinity, else: :infinity)
      exp == 31 -> :nan
      true -> s * :math.pow(2, exp - 15) * (1 + frac / 1024)
    end
  end

  defp encode_float16(n) when n in [:nan, :NaN], do: 0x7E00
  defp encode_float16(:infinity), do: 0x7C00
  defp encode_float16(:neg_infinity), do: 0xFC00

  defp encode_float16(n) when is_number(n) do
    f = n * 1.0
    sign = if f < 0 or negative_zero?(f), do: 1, else: 0
    sign_bits = Bitwise.bsl(sign, 15)
    abs_f = abs(f)

    cond do
      abs_f == 0.0 ->
        sign_bits

      abs_f < :math.pow(2, -14) ->
        rounded = bankers_round(abs_f / :math.pow(2, -24))

        cond do
          rounded == 0 -> sign_bits
          rounded >= 1024 -> sign_bits |> Bitwise.bor(Bitwise.bsl(1, 10))
          true -> sign_bits |> Bitwise.bor(rounded)
        end

      true ->
        exp = trunc(:math.floor(:math.log2(abs_f)))
        significand = bankers_round(abs_f / :math.pow(2, exp) * 1024)
        {exp, significand} = if significand == 2048, do: {exp + 1, 1024}, else: {exp, significand}

        if exp > 15 do
          sign_bits |> Bitwise.bor(0x7C00)
        else
          frac = Bitwise.band(significand - 1024, 0x3FF)
          exp_biased = exp + 15

          sign_bits
          |> Bitwise.bor(Bitwise.bsl(exp_biased, 10))
          |> Bitwise.bor(frac)
        end
    end
  end

  defp encode_float16(_), do: 0

  defp bankers_round(n) when is_float(n) do
    floor = trunc(n)
    frac = n - floor

    cond do
      frac > 0.5 -> floor + 1
      frac < 0.5 -> floor
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end

  defp bankers_round(n) when is_integer(n), do: n
  defp bankers_round(_), do: 0

  defp ensure_not_out_of_bounds(ref) do
    if out_of_bounds?({:obj, ref}) do
      JSThrow.type_error!("TypedArray is out of bounds")
    end
  end

  defp callback!(cb) do
    unless QuickBEAM.VM.Builtin.callable?(cb) do
      JSThrow.type_error!("callbackfn is not callable")
    end
  end

  defp rebuild_buffer(vals, buf, type) do
    vals
    |> Enum.with_index()
    |> Enum.reduce(buf, fn {v, i}, acc -> write_element(acc, i, v, type) end)
  end

  defp parse_args(args, type) do
    case args do
      [{:obj, buf_ref} = buf_obj | rest] ->
        buf = Heap.get_obj(buf_ref, %{})

        cond do
          match?({:qb_arr, _}, buf) or is_list(buf) ->
            list = object_source_to_list(buf_obj)
            {list_to_buffer(list, type), 0, length(list), nil, false}

          is_map(buf) and Map.get(buf, typed_array()) == true ->
            list = typed_array_source_to_list(buf_obj)
            {list_to_buffer(list, type), 0, length(list), nil, false}

          is_map(buf) and Map.has_key?(buf, buffer()) ->
            if Map.get(buf, "__detached__") do
              JSThrow.type_error!("ArrayBuffer is detached")
            end

            bin = Map.get(buf, buffer())
            es = elem_size(type)
            off = TypedArrayCoercion.index(Enum.at(rest, 0, :undefined))
            length_arg = Enum.at(rest, 1, :undefined)
            auto_length? = length_arg == :undefined
            length_tracking? = auto_length? and Map.has_key?(buf, "maxByteLength")
            available = byte_size(bin) - off

            cond do
              rem(off, es) != 0 ->
                JSThrow.range_error!("Invalid typed array byteOffset")

              off > byte_size(bin) ->
                JSThrow.range_error!("Invalid typed array byteOffset")

              auto_length? and not length_tracking? and rem(available, es) != 0 ->
                JSThrow.range_error!("Invalid typed array length")

              true ->
                len =
                  if auto_length?,
                    do: div(available, es),
                    else: TypedArrayCoercion.index(length_arg)

                if not auto_length? and len * es > available do
                  JSThrow.range_error!("Invalid typed array length")
                end

                {bin, off, len, buf_obj, length_tracking?}
            end

          true ->
            list = object_source_to_list(buf_obj)
            {list_to_buffer(list, type), 0, length(list), nil, false}
        end

      [{:qb_arr, arr} | _] ->
        list = :array.to_list(arr)
        {list_to_buffer(list, type), 0, length(list), nil, false}

      [list | _] when is_list(list) ->
        {list_to_buffer(list, type), 0, length(list), nil, false}

      [length_value | _] ->
        if Value.object_like?(length_value) do
          list = object_source_to_list(length_value)
          {list_to_buffer(list, type), 0, length(list), nil, false}
        else
          len = TypedArrayCoercion.index(length_value)
          {:binary.copy(<<0>>, len * elem_size(type)), 0, len, nil, false}
        end

      _ ->
        {<<>>, 0, 0, nil, false}
    end
  end

  defp typed_array_source_to_list(obj) do
    if out_of_bounds?(obj) do
      JSThrow.type_error!("TypedArray is out of bounds")
    else
      for index <- 0..(element_count(obj) - 1)//1, do: get_element(obj, index)
    end
  end

  defp object_source_to_list(obj) do
    iterator_method = Get.get(obj, {:symbol, "Symbol.iterator"})

    cond do
      QuickBEAM.VM.Builtin.callable?(iterator_method) ->
        iterator = Invocation.invoke_with_receiver(iterator_method, [], obj)
        iterator_to_list(iterator, [])

      not Value.nullish?(iterator_method) ->
        JSThrow.type_error!("object is not iterable")

      true ->
        array_like_to_list(obj)
    end
  end

  defp iterator_to_list(iterator, acc) do
    next_fn = Get.get(iterator, "next")

    unless QuickBEAM.VM.Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    result = Invocation.invoke_with_receiver(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      JSThrow.type_error!("Iterator result is not an object")
    end

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      iterator_to_list(iterator, [Get.get(result, "value") | acc])
    end
  end

  defp array_like_to_list(obj) do
    len = max(Runtime.to_int(Get.get(obj, "length")), 0)
    array_like_to_list_with_length(obj, len)
  end

  defp array_like_to_list_with_length(_obj, len) when len > @max_typed_array_elements do
    JSThrow.range_error!("Invalid typed array length")
  end

  defp array_like_to_list_with_length(_obj, 0), do: []

  defp array_like_to_list_with_length(obj, len) do
    for idx <- 0..(len - 1), do: Get.get(obj, Integer.to_string(idx))
  end

  # ── Element read/write ──

  defp read_element(buf, pos, :uint8) when pos < byte_size(buf), do: :binary.at(buf, pos)
  defp read_element(buf, pos, :uint8_clamped) when pos < byte_size(buf), do: :binary.at(buf, pos)

  defp read_element(buf, pos, :int8) when pos < byte_size(buf) do
    v = :binary.at(buf, pos)
    if v >= 128, do: v - 256, else: v
  end

  defp read_element(buf, pos, :uint16) when pos * 2 + 1 < byte_size(buf),
    do: :binary.decode_unsigned(:binary.part(buf, pos * 2, 2), :little)

  defp read_element(buf, pos, :int16) when pos * 2 + 1 < byte_size(buf) do
    v = :binary.decode_unsigned(:binary.part(buf, pos * 2, 2), :little)
    if v >= 0x8000, do: v - 0x10000, else: v
  end

  defp read_element(buf, pos, :uint32) when pos * 4 + 3 < byte_size(buf),
    do: :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)

  defp read_element(buf, pos, :int32) when pos * 4 + 3 < byte_size(buf) do
    v = :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)
    if v >= 0x80000000, do: v - 0x100000000, else: v
  end

  defp read_element(buf, pos, :float16) when pos * 2 + 1 < byte_size(buf) do
    <<_::binary-size(pos * 2), half::16-little, _::binary>> = buf
    decode_float16(half)
  end

  defp read_element(buf, pos, :float32) when pos * 4 + 3 < byte_size(buf) do
    bits = :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)

    case float32_special(bits) do
      nil ->
        <<f::little-float-32>> = :binary.part(buf, pos * 4, 4)
        f

      value ->
        value
    end
  end

  defp read_element(buf, pos, :float64) when pos * 8 + 7 < byte_size(buf) do
    bits = :binary.decode_unsigned(:binary.part(buf, pos * 8, 8), :little)

    case float64_special(bits) do
      nil ->
        <<f::little-float-64>> = :binary.part(buf, pos * 8, 8)
        f

      value ->
        value
    end
  end

  defp read_element(buf, pos, :bigint64) when pos * 8 + 7 < byte_size(buf) do
    <<n::little-signed-64>> = :binary.part(buf, pos * 8, 8)
    {:bigint, n}
  end

  defp read_element(buf, pos, :biguint64) when pos * 8 + 7 < byte_size(buf) do
    <<n::little-unsigned-64>> = :binary.part(buf, pos * 8, 8)
    {:bigint, n}
  end

  defp read_element(_, _, _), do: :undefined

  defp float32_special(0x7F800000), do: :infinity
  defp float32_special(0xFF800000), do: :neg_infinity

  defp float32_special(bits)
       when Bitwise.band(bits, 0x7F800000) == 0x7F800000 and Bitwise.band(bits, 0x007FFFFF) != 0,
       do: :nan

  defp float32_special(_), do: nil

  defp float64_special(0x7FF0000000000000), do: :infinity
  defp float64_special(0xFFF0000000000000), do: :neg_infinity

  defp float64_special(bits)
       when Bitwise.band(bits, 0x7FF0000000000000) == 0x7FF0000000000000 and
              Bitwise.band(bits, 0x000FFFFFFFFFFFFF) != 0,
       do: :nan

  defp float64_special(_), do: nil

  defp write_element(buf, pos, :undefined, type) when type in [:float16, :float32, :float64],
    do: write_element(buf, pos, :nan, type)

  defp write_element(buf, pos, :undefined, type), do: write_element(buf, pos, 0, type)

  defp write_element(buf, pos, val, :uint8_clamped) when pos < byte_size(buf) do
    v = val |> clamped_uint8_number() |> bankers_round()
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, v::8, rest::binary>>
  end

  defp write_element(buf, pos, val, :uint8) when pos < byte_size(buf) do
    v = integer_number(val) |> Bitwise.band(0xFF)
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, v::8, rest::binary>>
  end

  defp write_element(buf, pos, val, :int8) when pos < byte_size(buf) do
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, integer_number(val)::signed-8, rest::binary>>
  end

  defp write_element(buf, pos, val, :int32) when pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, integer_number(val)::little-signed-32, rest::binary>>
  end

  defp write_element(buf, pos, val, :float64)
       when val in [:nan, :NaN, :infinity, :neg_infinity] and pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, float64_bits(val)::little-64, rest::binary>>
  end

  defp write_element(buf, pos, val, :float64) when pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, float_number(val)::little-float-64, rest::binary>>
  end

  defp write_element(buf, pos, val, :float16) when pos * 2 + 1 < byte_size(buf) do
    half = encode_float16(float_or_special(val))
    <<pre::binary-size(pos * 2), _::16, rest::binary>> = buf
    <<pre::binary, half::16-little, rest::binary>>
  end

  defp write_element(buf, pos, val, :float32)
       when val in [:nan, :NaN, :infinity, :neg_infinity] and pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, float32_bits(val)::little-32, rest::binary>>
  end

  defp write_element(buf, pos, val, :float32) when pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, float_number(val)::little-float-32, rest::binary>>
  end

  defp write_element(buf, pos, val, :bigint64) when pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, TypedArrayCoercion.bigint_value(val)::little-signed-64, rest::binary>>
  end

  defp write_element(buf, pos, val, :biguint64) when pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, TypedArrayCoercion.bigint_value(val)::little-unsigned-64, rest::binary>>
  end

  defp write_element(buf, pos, val, type) do
    es = elem_size(type)
    bp = pos * es

    if bp + es <= byte_size(buf) do
      <<pre::binary-size(bp), _::binary-size(es), rest::binary>> = buf
      <<pre::binary, integer_number(val)::little-unsigned-size(es * 8), rest::binary>>
    else
      buf
    end
  end

  defp float32_bits(n) when n in [:nan, :NaN], do: 0x7FC00000
  defp float32_bits(:infinity), do: 0x7F800000
  defp float32_bits(:neg_infinity), do: 0xFF800000

  defp float64_bits(n) when n in [:nan, :NaN], do: 0x7FF8000000000000
  defp float64_bits(:infinity), do: 0x7FF0000000000000
  defp float64_bits(:neg_infinity), do: 0xFFF0000000000000

  defp clamped_uint8_number(value) do
    case Runtime.to_number(value) do
      :infinity -> 255
      :neg_infinity -> 0
      number when is_integer(number) -> max(0, min(255, number))
      number when is_float(number) -> max(0.0, min(255.0, number))
      _ -> 0
    end
  end

  defp integer_number(value) do
    case Runtime.to_number(value) do
      number when is_integer(number) -> number
      number when is_float(number) -> trunc(number)
      _ -> 0
    end
  end

  defp float_number(value) do
    case Runtime.to_number(value) do
      number when is_integer(number) -> number * 1.0
      number when is_float(number) -> number
      _ -> 0.0
    end
  end

  defp float_or_special(value) do
    case Runtime.to_number(value) do
      number when is_number(number) -> number
      special -> special
    end
  end

  defp list_to_buffer(list, type) do
    es = elem_size(type)
    buf = :binary.copy(<<0>>, length(list) * es)

    list
    |> Enum.with_index()
    |> Enum.reduce(buf, fn {val, i}, acc -> write_element(acc, i, val, type) end)
  end

  defp make_buffer_ref(buffer_data) do
    Heap.wrap(%{
      buffer() => buffer_data,
      "byteLength" => byte_size(buffer_data),
      "resizable" => false,
      "__array_buffer_kind__" => :array_buffer,
      proto() => Runtime.global_class_proto("ArrayBuffer") || Heap.get_object_prototype()
    })
  end
end
