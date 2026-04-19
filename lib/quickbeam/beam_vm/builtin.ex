defmodule QuickBEAM.BeamVM.Builtin do
  @moduledoc false

  @doc """
  All builtins use a uniform 2-arity calling convention: `fn args, this ->`.
  Statics ignore `this`. This eliminates arity dispatch at every call site.

  ## Usage

      use QuickBEAM.BeamVM.Builtin

      defproto "push", this, args do ... end     # proto_property("push")
      defstatic "isArray", args do ... end        # static_property("isArray")

  ## Calling convention

  Every `{:builtin, name, cb}` callback is always `cb.(args, this)`.
  No arity checking needed. `Builtin.call/3` invokes it.
  """

  defmacro __using__(_opts) do
    quote do
      import QuickBEAM.BeamVM.Builtin, only: [defproto: 4, defstatic: 3]
    end
  end

  defmacro defproto(name, this_var, args_var, do: body) do
    quote do
      def proto_property(unquote(name)) do
        {:builtin, unquote(name), fn unquote(args_var), unquote(this_var) -> unquote(body) end}
      end
    end
  end

  defmacro defstatic(name, args_var, do: body) do
    quote do
      def static_property(unquote(name)) do
        {:builtin, unquote(name), fn unquote(args_var), _this -> unquote(body) end}
      end
    end
  end

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
