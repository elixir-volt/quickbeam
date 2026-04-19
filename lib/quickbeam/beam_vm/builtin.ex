defmodule QuickBEAM.BeamVM.Builtin do
  @moduledoc false

  @doc """
  Macros for defining JS builtin methods with zero boilerplate.

  All builtins use a uniform 2-arity `fn args, this ->` convention.

  ## Proto methods (instance methods)

      proto "push" do
        # `this` and `args` are injected bindings
        list = Heap.get_obj(elem(this, 1), [])
        new_list = list ++ args
        Heap.put_obj(elem(this, 1), new_list)
        length(new_list)
      end

  ## Static methods

      static "isArray" do
        # `args` is injected, `this` is ignored
        case hd(args) do ...  end
      end

  ## Static constants

      static_val "PI", :math.pi()

  ## Object maps (Math, Console)

      js_object "Math" do
        method "floor" do floor(Runtime.to_float(hd(args))) end
        val "PI", :math.pi()
      end

  Catch-all `proto_property(_) -> :undefined` and
  `static_property(_) -> :undefined` are generated automatically.
  """

  defmacro __using__(_opts) do
    quote do
      import QuickBEAM.BeamVM.Builtin,
        only: [proto: 2, static: 2, static_val: 2, js_object: 2]

      Module.register_attribute(__MODULE__, :__has_proto, accumulate: false)
      Module.register_attribute(__MODULE__, :__has_static, accumulate: false)
      @before_compile QuickBEAM.BeamVM.Builtin
    end
  end

  defmacro __before_compile__(env) do
    has_proto = Module.get_attribute(env.module, :__has_proto)
    has_static = Module.get_attribute(env.module, :__has_static)

    proto_fallback =
      if has_proto do
        quote do
          def proto_property(_), do: :undefined
        end
      end

    static_fallback =
      if has_static do
        quote do
          def static_property(_), do: :undefined
        end
      end

    [proto_fallback, static_fallback]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      blocks -> {:__block__, [], blocks}
    end
  end

  @doc "Define a proto method. Injects `this` and `args` bindings."
  defmacro proto(name, do: body) do
    quote do
      @__has_proto true
      def proto_property(unquote(name)) do
        {:builtin, unquote(name),
         fn var!(args), var!(this) ->
           _ = var!(args)
           _ = var!(this)
           unquote(body)
         end}
      end
    end
  end

  @doc "Define a static method. Injects `args` binding."
  defmacro static(name, do: body) do
    quote do
      @__has_static true
      def static_property(unquote(name)) do
        {:builtin, unquote(name),
         fn var!(args), _this ->
           _ = var!(args)
           unquote(body)
         end}
      end
    end
  end

  @doc "Define a static constant value."
  defmacro static_val(name, value) do
    quote do
      @__has_static true
      def static_property(unquote(name)), do: unquote(value)
    end
  end

  @doc """
  Define a JS object with methods and values.
  Generates a function returning `{:builtin, name, %{...}}`.

      js_object "Math" do
        method "floor" do floor(Runtime.to_float(hd(args))) end
        val "PI", :math.pi()
      end
  """
  defmacro js_object(name, do: {:__block__, _, entries}) do
    map_entries = Enum.map(entries, &build_object_entry/1)

    quote do
      def object do
        {:builtin, unquote(name), %{unquote_splicing(map_entries)}}
      end
    end
  end

  defmacro js_object(name, do: single) do
    map_entries = [build_object_entry(single)]

    quote do
      def object do
        {:builtin, unquote(name), %{unquote_splicing(map_entries)}}
      end
    end
  end

  defp build_object_entry({:method, _, [name, [do: body]]}) do
    {name,
     quote do
       {:builtin, unquote(name),
        fn var!(args), var!(this) ->
          _ = var!(args)
          _ = var!(this)
          unquote(body)
        end}
     end}
  end

  defp build_object_entry({:val, _, [name, value]}) do
    {name, value}
  end

  # ── Runtime dispatch ──

  @doc "Invoke a builtin callback. Always 2-arity: cb.(args, this)."
  def call({:builtin, _, cb}, args, this), do: cb.(args, this)
  def call({:bound, _, inner}, args, this), do: call(inner, args, this)
  def call(f, args, _this) when is_function(f, 2), do: f.(args, nil)
  def call(f, args, _this) when is_function(f, 1), do: f.(args)
  def call(f, args, _this) when is_function(f), do: apply(f, args)

  def call(_, _, _),
    do: throw({:js_throw, QuickBEAM.BeamVM.Heap.make_error("not a function", "TypeError")})

  def callable?(%QuickBEAM.BeamVM.Bytecode.Function{}), do: true
  def callable?({:closure, _, %QuickBEAM.BeamVM.Bytecode.Function{}}), do: true
  def callable?({:builtin, _, _}), do: true
  def callable?({:bound, _, _}), do: true
  def callable?(f) when is_function(f), do: true
  def callable?(_), do: false
end
