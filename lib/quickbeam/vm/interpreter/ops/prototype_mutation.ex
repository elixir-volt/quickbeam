defmodule QuickBEAM.VM.Interpreter.Ops.PrototypeMutation do
  @moduledoc "Prototype mutation opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      import QuickBEAM.VM.Heap.Keys, only: [proto: 0]
      import QuickBEAM.VM.Value, only: [is_object: 1]
      alias QuickBEAM.VM.Heap

      defp run({@op_set_proto, []}, pc, frame, [proto, obj | rest], gas, ctx) do
        case obj do
          {:obj, ref} ->
            map = Heap.get_obj(ref, %{})

            if is_map(map) and (is_object(proto) or proto == nil) do
              Heap.put_obj(ref, Map.put(map, proto(), proto))
            end

          _ ->
            :ok
        end

        run(pc + 1, frame, [obj | rest], gas, ctx)
      end
    end
  end
end
