defmodule QuickBEAM do
  @type runtime :: GenServer.server()
  @type js_result :: {:ok, term()} | {:error, String.t()}

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    QuickBEAM.Runtime.start_link(opts)
  end

  @spec eval(runtime(), String.t()) :: js_result()
  def eval(runtime, code) do
    QuickBEAM.Runtime.eval(runtime, code)
  end

  @spec call(runtime(), String.t(), list()) :: js_result()
  def call(runtime, fn_name, args \\ []) do
    QuickBEAM.Runtime.call(runtime, fn_name, args)
  end

  @spec load_module(runtime(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def load_module(runtime, name, code) do
    QuickBEAM.Runtime.load_module(runtime, name, code)
  end

  @spec reset(runtime()) :: :ok | {:error, String.t()}
  def reset(runtime) do
    QuickBEAM.Runtime.reset(runtime)
  end

  @spec stop(runtime()) :: :ok
  def stop(runtime) do
    QuickBEAM.Runtime.stop(runtime)
  end

  @spec send_message(runtime(), term()) :: :ok
  def send_message(runtime, message) do
    QuickBEAM.Runtime.send_message(runtime, message)
  end
end
