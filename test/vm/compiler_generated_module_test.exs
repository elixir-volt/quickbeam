defmodule QuickBEAM.VM.CompilerGeneratedModuleTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Compiler.{Contract, Deopt, GeneratedModule, ModulePool, Runtime}

  alias QuickBEAM.VM.Compiler.GeneratedModule.{
    Artifact,
    CodeLifecycle,
    Emitter,
    ImportPolicy,
    Template
  }

  alias QuickBEAM.VM.{Execution, Frame, Function}

  test "compiles a slot-specific module with only allowlisted runtime imports" do
    module = hd(Contract.pool_modules())
    key = key(1)

    assert {:ok, %Artifact{} = artifact} = Emitter.emit(key, module, deopt_template())

    assert artifact.module == module
    assert artifact.digest == :crypto.hash(:sha256, artifact.binary)
    assert {:ok, imports} = ImportPolicy.imports(artifact.binary)

    assert imports == [
             {Runtime, :deopt, 4},
             {:erlang, :get_module_info, 1},
             {:erlang, :get_module_info, 2}
           ]

    assert :ok = ImportPolicy.validate(artifact.binary)
  end

  test "loads and invokes generated code only while a pool lease is active" do
    pool = start_pool(capacity: 1)
    key = key(1)
    assert {:ok, lease} = ModulePool.checkout(pool, key, deopt_template())
    assert :ok = ModulePool.validate_lease(pool, lease)

    frame = frame()
    execution = execution()

    assert {:deopt, %Deopt{} = deopt} = lease.module.run(lease, frame, execution)

    assert deopt.artifact_key == key
    assert deopt.pool_epoch == lease.epoch
    assert deopt.generation == lease.generation
    assert deopt.frame == frame

    assert :ok = ModulePool.checkin(pool, lease)
    assert :ok = ModulePool.drain(pool)
    assert :code.is_loaded(lease.module) == false
  end

  test "reuses one static module across distinct generated artifacts" do
    pool = start_pool(capacity: 1)

    modules =
      for id <- 1..25 do
        assert {:ok, lease} = ModulePool.checkout(pool, key(id), deopt_template())

        assert {:deopt, %Deopt{artifact_key: artifact_key}} =
                 lease.module.run(lease, frame(), execution())

        assert artifact_key == key(id)
        assert :ok = ModulePool.checkin(pool, lease)
        lease.module
      end

    assert Enum.uniq(modules) == [hd(Contract.pool_modules())]
    assert ModulePool.stats(pool).counts == %{ready: 1}
  end

  test "rejects a generated external call outside the runtime ABI" do
    module = hd(Contract.pool_modules())
    expression = remote_call(File, :cwd!, [])

    assert {:error, {:disallowed_generated_calls, [{File, :cwd!, 0}]}} =
             Emitter.emit(
               key(1),
               module,
               template(expression, [:_Lease, :_Frame, :_Execution])
             )
  end

  test "rejects malformed module attributes, exports, and artifact digests" do
    module = hd(Contract.pool_modules())
    bad_module = replace_attribute(deopt_template(), :module, Other.Generated.Module)

    assert {:error, {:invalid_compiler_module_attributes, [Other.Generated.Module]}} =
             Emitter.emit(key(1), module, bad_module)

    bad_exports = replace_attribute(deopt_template(), :export, other: 3)

    assert {:error, {:invalid_compiler_exports, [[other: 3]]}} =
             Emitter.emit(key(1), module, bad_exports)

    assert {:ok, artifact} = Emitter.emit(key(1), module, deopt_template())
    tampered = %{artifact | digest: <<0::256>>}
    assert {:error, :artifact_digest_mismatch} = CodeLifecycle.install(module, tampered)
  end

  test "soft purge quarantines a slot instead of killing a live code reference" do
    pool = start_pool(capacity: 1)
    parent = self()

    runner =
      spawn(fn ->
        {:ok, lease} = ModulePool.checkout(pool, key(1), blocking_template())
        :ok = ModulePool.checkin(pool, lease)
        send(parent, {:generated_runner_ready, self(), lease.module})
        lease.module.run(lease, frame(), execution())
      end)

    assert_receive {:generated_runner_ready, ^runner, module}
    assert {:error, :compiler_pool_busy} = ModulePool.checkout(pool, key(2), deopt_template())
    assert Process.alive?(runner)

    assert [%{status: :quarantined, reason: {:live_generated_code, ^module, :current}}] =
             ModulePool.stats(pool).slots

    monitor = Process.monitor(runner)
    send(runner, :release)
    assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}
    assert :ok = CodeLifecycle.retire(module)
  end

  defp start_pool(opts) do
    start_supervised!(
      {ModulePool,
       Keyword.merge(
         [backend: GeneratedModule, task_supervisor: QuickBEAM.VM.TaskSupervisor],
         opts
       )}
    )
  end

  defp deopt_template do
    expression =
      remote_call(Runtime, :deopt, [
        {:atom, 1, :unsupported_opcode},
        {:var, 1, :Lease},
        {:var, 1, :Frame},
        {:var, 1, :Execution}
      ])

    template(expression)
  end

  defp blocking_template do
    expression =
      {:receive, 1,
       [
         {:clause, 1, [{:atom, 1, :release}], [], [{:atom, 1, :ok}]}
       ]}

    template(expression, [:_Lease, :_Frame, :_Execution])
  end

  defp template(expression, argument_names \\ [:Lease, :Frame, :Execution]) do
    arguments = Enum.map(argument_names, &{:var, 1, &1})

    %Template{
      forms: [
        {:attribute, 1, :module, Template.placeholder_module()},
        {:attribute, 1, :export, [run: 3]},
        {:function, 1, :run, 3,
         [
           {:clause, 1, arguments, [], [expression]}
         ]},
        {:eof, 1}
      ]
    }
  end

  defp remote_call(module, function, arguments) do
    {:call, 1, {:remote, 1, {:atom, 1, module}, {:atom, 1, function}}, arguments}
  end

  defp replace_attribute(%Template{forms: forms} = template, name, value) do
    forms =
      Enum.map(forms, fn
        {:attribute, line, ^name, _old} -> {:attribute, line, name, value}
        form -> form
      end)

    %{template | forms: forms}
  end

  defp frame do
    function = %Function{id: 0, atoms: {}, instructions: {{0, []}}}

    %Frame{
      function: function,
      callable: function,
      locals: {},
      args: {},
      this: :undefined
    }
  end

  defp execution do
    %Execution{
      atoms: {},
      max_stack_depth: 32,
      remaining_steps: 100,
      step_limit: 100
    }
  end

  defp key(integer), do: :crypto.hash(:sha256, <<integer::unsigned-64>>)
end
