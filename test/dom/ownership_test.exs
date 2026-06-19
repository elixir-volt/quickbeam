defmodule QuickBEAM.DOM.OwnershipTest do
  use ExUnit.Case, async: true

  test "wrapper cache survives removal, reset, and shutdown" do
    for _ <- 1..5 do
      {:ok, rt} = QuickBEAM.start()

      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const root = document.createElement('section');
               document.body.appendChild(root);
               for (let i = 0; i < 100; i++) {
                 const child = document.createElement('div');
                 child.id = 'node-' + i;
                 root.appendChild(child);
                 if (document.getElementById(child.id) !== child) throw new Error('identity mismatch');
               }
               root.textContent = 'detached';
               document.body.textContent = '';
               true;
               """)

      assert :ok = QuickBEAM.reset(rt)

      assert {:ok, "BODY"} = QuickBEAM.eval(rt, "document.body.tagName")
      QuickBEAM.stop(rt)
    end
  end
end
