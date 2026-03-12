defmodule QuickBEAM.PerformanceTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "performance.now()" do
    test "still works after augmentation", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               typeof performance.now === 'function' && performance.now() > 0
               """)
    end
  end

  describe "performance.timeOrigin" do
    test "is a positive number", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               typeof performance.timeOrigin === 'number' && performance.timeOrigin > 0
               """)
    end

    test "is close to Date.now()", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               Math.abs(performance.timeOrigin - Date.now()) < 5000
               """)
    end
  end

  describe "performance.mark()" do
    test "creates a mark and returns PerformanceMark", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('test');
               mark instanceof PerformanceMark
               """)
    end

    test "mark has correct name and entryType", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('myMark');
               mark.name === 'myMark' && mark.entryType === 'mark'
               """)
    end

    test "mark has startTime and duration=0", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('m');
               typeof mark.startTime === 'number' && mark.startTime >= 0 && mark.duration === 0
               """)
    end

    test "mark with custom startTime via options", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('custom', { startTime: 42.5 });
               mark.startTime === 42.5
               """)
    end

    test "mark with detail", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('detailed', { detail: { key: 'value' } });
               mark.detail.key === 'value'
               """)
    end

    test "mark without detail has null detail", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('noDetail');
               mark.detail === null
               """)
    end

    test "mark extends PerformanceEntry", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('e');
               mark instanceof PerformanceEntry
               """)
    end
  end

  describe "performance.measure()" do
    test "measure between two marks", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark('start', { startTime: 100 });
               performance.mark('end', { startTime: 250 });
               const m = performance.measure('dur', 'start', 'end');
               m.name === 'dur' && m.entryType === 'measure' && m.duration === 150 && m.startTime === 100
               """)
    end

    test "measure from mark to now", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark('s');
               const m = performance.measure('elapsed', 's');
               m.duration >= 0 && m.entryType === 'measure'
               """)
    end

    test "measure from timeOrigin to now (no args)", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('total');
               m.startTime === 0 && m.duration >= 0
               """)
    end

    test "measure with options object (start/end)", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark('a', { startTime: 10 });
               performance.mark('b', { startTime: 30 });
               const m = performance.measure('opts', { start: 'a', end: 'b' });
               m.startTime === 10 && m.duration === 20
               """)
    end

    test "measure with options object (start/duration)", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('sd', { start: 5, duration: 15 });
               m.startTime === 5 && m.duration === 15
               """)
    end

    test "measure with options object (end/duration)", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('ed', { end: 50, duration: 20 });
               m.startTime === 30 && m.duration === 20
               """)
    end

    test "measure with detail", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('d', { start: 0, end: 10, detail: 'info' });
               m.detail === 'info'
               """)
    end

    test "measure returns PerformanceMeasure", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('inst');
               m instanceof PerformanceMeasure && m instanceof PerformanceEntry
               """)
    end

    test "measure throws for nonexistent mark", %{rt: rt} do
      assert {:error, _} =
               QuickBEAM.eval(rt, "performance.measure('bad', 'nonexistent')")
    end
  end

  describe "performance.getEntries()" do
    test "returns all entries in insertion order", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('a');
               performance.mark('b');
               performance.measure('m', 'a', 'b');
               const entries = performance.getEntries();
               entries.length === 3 &&
                 entries[0].name === 'a' &&
                 entries[1].name === 'b' &&
                 entries[2].name === 'm'
               """)
    end
  end

  describe "performance.getEntriesByType()" do
    test "filters by mark type", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('x');
               performance.mark('y');
               performance.measure('z', 'x', 'y');
               const marks = performance.getEntriesByType('mark');
               marks.length === 2 && marks.every(e => e.entryType === 'mark')
               """)
    end

    test "filters by measure type", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('p');
               performance.mark('q');
               performance.measure('r', 'p', 'q');
               const measures = performance.getEntriesByType('measure');
               measures.length === 1 && measures[0].name === 'r'
               """)
    end
  end

  describe "performance.getEntriesByName()" do
    test "filters by name", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('target');
               performance.mark('other');
               performance.mark('target');
               const found = performance.getEntriesByName('target');
               found.length === 2 && found.every(e => e.name === 'target')
               """)
    end

    test "filters by name and type", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('same', { startTime: 0 });
               performance.measure('same', { start: 0, end: 10 });
               const marks = performance.getEntriesByName('same', 'mark');
               const measures = performance.getEntriesByName('same', 'measure');
               marks.length === 1 && marks[0].entryType === 'mark' &&
                 measures.length === 1 && measures[0].entryType === 'measure'
               """)
    end
  end

  describe "performance.clearMarks()" do
    test "removes all marks but not measures", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('a', { startTime: 0 });
               performance.mark('b', { startTime: 10 });
               performance.measure('m', { start: 0, end: 10 });
               performance.clearMarks();
               performance.getEntriesByType('mark').length === 0 &&
                 performance.getEntriesByType('measure').length === 1
               """)
    end

    test "removes only marks with given name", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('keep');
               performance.mark('remove');
               performance.mark('keep');
               performance.clearMarks('remove');
               const marks = performance.getEntriesByType('mark');
               marks.length === 2 && marks.every(e => e.name === 'keep')
               """)
    end
  end

  describe "performance.clearMeasures()" do
    test "removes all measures but not marks", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('a', { startTime: 0 });
               performance.measure('m', { start: 0, end: 10 });
               performance.clearMeasures();
               performance.getEntriesByType('measure').length === 0 &&
                 performance.getEntriesByType('mark').length === 1
               """)
    end

    test "removes only measures with given name", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.clearMarks();
               performance.clearMeasures();
               performance.mark('a', { startTime: 0 });
               performance.mark('b', { startTime: 10 });
               performance.measure('keep', { start: 0, end: 5 });
               performance.measure('remove', { start: 0, end: 10 });
               performance.clearMeasures('remove');
               const measures = performance.getEntriesByType('measure');
               measures.length === 1 && measures[0].name === 'keep'
               """)
    end
  end

  describe "performance.toJSON()" do
    test "returns object with timeOrigin", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const json = performance.toJSON();
               typeof json.timeOrigin === 'number' && json.timeOrigin > 0
               """)
    end
  end

  describe "PerformanceEntry.toJSON()" do
    test "mark toJSON contains all fields", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('j', { startTime: 5, detail: 'hi' });
               const json = mark.toJSON();
               json.name === 'j' && json.entryType === 'mark' &&
                 json.startTime === 5 && json.duration === 0 && json.detail === 'hi'
               """)
    end

    test "measure toJSON contains all fields", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('j', { start: 10, end: 30, detail: 42 });
               const json = m.toJSON();
               json.name === 'j' && json.entryType === 'measure' &&
                 json.startTime === 10 && json.duration === 20 && json.detail === 42
               """)
    end
  end
end
