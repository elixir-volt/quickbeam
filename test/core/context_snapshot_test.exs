defmodule QuickBEAM.Core.ContextSnapshotTest do
  use ExUnit.Case, async: true

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} context restores named heap snapshots" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1, mode: @mode)
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool, apis: false)

      assert {:ok, 1} = QuickBEAM.Context.eval(ctx, "globalThis.harnessValue = 1")
      assert :ok = QuickBEAM.Context.snapshot(ctx, :harness)

      assert {:ok, 2} = QuickBEAM.Context.eval(ctx, "globalThis.harnessValue = 2")

      assert {:ok, "polluted"} =
               QuickBEAM.Context.eval(ctx, "Array.prototype.snapshotPollution = 'polluted'")

      assert :ok = QuickBEAM.Context.restore(ctx, :harness)
      assert {:ok, 1} = QuickBEAM.Context.eval(ctx, "globalThis.harnessValue")

      assert {:ok, "undefined"} =
               QuickBEAM.Context.eval(ctx, "typeof Array.prototype.snapshotPollution")

      assert {:ok, 3} =
               QuickBEAM.Context.eval(ctx, "globalThis.harnessValue = 3; harnessValue",
                 restore: :harness
               )

      assert {:ok, 1} = QuickBEAM.Context.eval(ctx, "globalThis.harnessValue", restore: :harness)
    end
  end

  test "snapshots preserve builtin error constructor prototypes after GC" do
    Code.require_file("../support/test262.ex", __DIR__)

    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1, mode: :beam_compiler)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool, apis: false)

    assert {:ok, _} = QuickBEAM.Context.eval(ctx, QuickBEAM.Test262.harness_source([]))
    assert :ok = QuickBEAM.Context.snapshot(ctx, :harness)

    assert {:ok, ["TypeError", true, "TypeError", false]} =
             QuickBEAM.Context.eval(
               ctx,
               "try { ({}).missing(); } catch (e) { [e.name, e.constructor === TypeError, e.constructor.name, e.constructor === Object] }",
               restore: :harness
             )

    source = File.read!("test/test262/test/language/expressions/call/11.2.3-3_1.js")
    assert {:ok, nil} = QuickBEAM.Context.eval(ctx, source, restore: :harness)
  end

  test "missing BEAM snapshots return an explicit error" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1, mode: :beam_compiler)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool, apis: false)

    assert {:error, :snapshot_not_found} = QuickBEAM.Context.restore(ctx, :missing)
    assert {:error, :snapshot_not_found} = QuickBEAM.Context.eval(ctx, "1", restore: :missing)
  end

  test "NIF contexts report snapshots as unsupported" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool, apis: false)

    assert {:error, :snapshots_not_supported} = QuickBEAM.Context.snapshot(ctx, :harness)
    assert {:error, :snapshots_not_supported} = QuickBEAM.Context.restore(ctx, :harness)

    assert {:error, :snapshots_not_supported} =
             QuickBEAM.Context.eval(ctx, "1", restore: :harness)
  end
end
