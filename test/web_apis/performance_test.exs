defmodule QuickBEAM.WebAPIs.PerformanceTest do
  @moduledoc "Merged from WPT: user-timing, performance-timeline + additional coverage"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "performance.timeOrigin" do
    test "timeOrigin is a number", %{rt: rt} do
      assert {:ok, "number"} =
               QuickBEAM.eval(rt, "typeof performance.timeOrigin")
    end

    test "is a positive number", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               typeof performance.timeOrigin === 'number' && performance.timeOrigin > 0
               """)
    end

    test "timeOrigin is close to Date.now() at startup", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               Math.abs(performance.timeOrigin - Date.now()) < 1000
               """)
    end

    test "is close to Date.now()", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               Math.abs(performance.timeOrigin - Date.now()) < 5000
               """)
    end
  end

  describe "performance.now()" do
    test "still works after timeline augmentation", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const t = performance.now();
               typeof t === 'number' && t > 0
               """)
    end

    test "still works after augmentation", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               typeof performance.now === 'function' && performance.now() > 0
               """)
    end
  end

  describe "performance.mark()" do
    test "returns a mark with correct properties", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark("test-mark");
               mark.name === "test-mark" &&
                 mark.entryType === "mark" &&
                 mark.duration === 0 &&
                 typeof mark.startTime === "number"
               """)
    end

    test "creates a mark and returns PerformanceMark", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('test');
               mark.constructor.name === 'PerformanceMark'
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

    test "mark is a PerformanceMark", %{rt: rt} do
      assert {:ok, "PerformanceMark"} =
               QuickBEAM.eval(rt, """
               performance.mark("check-type").constructor.name
               """)
    end

    test "mark startTime defaults to performance.now()", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const before = performance.now();
               const mark = performance.mark("timed");
               const after = performance.now();
               mark.startTime >= before && mark.startTime <= after
               """)
    end

    test "mark with custom startTime", %{rt: rt} do
      assert {:ok, 42.5} =
               QuickBEAM.eval(rt, """
               performance.mark("custom", { startTime: 42.5 }).startTime
               """)
    end

    test "mark with custom startTime via options", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('custom', { startTime: 42.5 });
               mark.startTime === 42.5
               """)
    end

    test "mark duration is always 0", %{rt: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, """
               performance.mark("zero-dur", { startTime: 100 }).duration
               """)
    end

    test "mark has detail property", %{rt: rt} do
      assert {:ok, "info"} =
               QuickBEAM.eval(rt, """
               performance.mark("detailed", { detail: "info" }).detail
               """)
    end

    test "mark with detail", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark('detailed', { detail: { key: 'value' } });
               mark.detail.key === 'value'
               """)
    end

    test "mark detail defaults to null", %{rt: rt} do
      assert {:ok, nil} =
               QuickBEAM.eval(rt, """
               performance.mark("no-detail").detail
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
               'name' in mark && 'entryType' in mark && 'startTime' in mark && 'duration' in mark
               """)
    end
  end

  describe "performance.measure()" do
    test "measure between two marks has correct duration", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("m-start", { startTime: 10 });
               performance.mark("m-end", { startTime: 30 });
               const measure = performance.measure("m", "m-start", "m-end");
               measure.startTime === 10 && measure.duration === 20
               """)
    end

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

    test "measure returns PerformanceMeasure", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('inst');
               m.constructor.name === 'PerformanceMeasure' && 'startTime' in m && 'duration' in m
               """)
    end

    test "measure is a PerformanceMeasure", %{rt: rt} do
      assert {:ok, "PerformanceMeasure"} =
               QuickBEAM.eval(rt, """
               performance.mark("ms");
               performance.measure("check-measure", "ms").constructor.name
               """)
    end

    test "measure has entryType 'measure'", %{rt: rt} do
      assert {:ok, "measure"} =
               QuickBEAM.eval(rt, """
               performance.mark("ms2");
               performance.measure("et", "ms2").entryType
               """)
    end

    test "measure from timeOrigin to now (no args)", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure('total');
               m.startTime === 0 && m.duration >= 0
               """)
    end

    test "measure with no args measures from timeOrigin to now", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = performance.measure("full");
               m.startTime === 0 && m.duration > 0
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

    test "measure with options object", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("opt-start", { startTime: 5 });
               performance.mark("opt-end", { startTime: 15 });
               const m = performance.measure("opts", { start: "opt-start", end: "opt-end" });
               m.startTime === 5 && m.duration === 10
               """)
    end

    test "measure with numeric start in options", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("num-end", { startTime: 25 });
               const m = performance.measure("num", { start: 10, end: "num-end" });
               m.startTime === 10 && m.duration === 15
               """)
    end

    test "measure with duration option", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("dur-start", { startTime: 5 });
               const m = performance.measure("dur", { start: "dur-start", duration: 20 });
               m.startTime === 5 && m.duration === 20
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

    test "measure throws for nonexistent mark", %{rt: rt} do
      assert {:error, _} =
               QuickBEAM.eval(rt, "performance.measure('bad', 'nonexistent')")
    end

    test "measure throws on unknown mark name", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               let threw = false;
               try { performance.measure("bad", "nonexistent"); } catch(e) { threw = true; }
               threw
               """)
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

  describe "getEntries" do
    test "getEntries returns all entries in order", %{rt: rt} do
      assert {:ok, "a,b,c"} =
               QuickBEAM.eval(rt, """
               performance.mark("a", { startTime: 1 });
               performance.mark("b", { startTime: 2 });
               performance.mark("c", { startTime: 3 });
               performance.getEntries().map(e => e.name).join(",")
               """)
    end

    test "getEntriesByType filters correctly", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("x", { startTime: 1 });
               performance.mark("y", { startTime: 5 });
               performance.measure("xy", "x", "y");
               const marks = performance.getEntriesByType("mark");
               const measures = performance.getEntriesByType("measure");
               marks.every(e => e.entryType === "mark") &&
                 measures.every(e => e.entryType === "measure") &&
                 measures.length >= 1
               """)
    end

    test "getEntriesByName filters correctly", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("target", { startTime: 1 });
               performance.mark("other", { startTime: 2 });
               performance.mark("target", { startTime: 3 });
               const results = performance.getEntriesByName("target");
               results.length === 2 && results.every(e => e.name === "target")
               """)
    end

    test "getEntriesByName with type filter", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("shared", { startTime: 1 });
               performance.mark("shared-end", { startTime: 10 });
               performance.measure("shared", "shared", "shared-end");
               const marks = performance.getEntriesByName("shared", "mark");
               const measures = performance.getEntriesByName("shared", "measure");
               marks.every(e => e.entryType === "mark") &&
                 measures.every(e => e.entryType === "measure")
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

  describe "clearMarks and clearMeasures" do
    test "clearMarks clears only marks", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("cm1", { startTime: 1 });
               performance.mark("cm2", { startTime: 5 });
               performance.measure("cmm", "cm1", "cm2");
               performance.clearMarks();
               const marks = performance.getEntriesByType("mark");
               const measures = performance.getEntriesByType("measure");
               marks.length === 0 && measures.length >= 1
               """)
    end

    test "clearMeasures clears only measures", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("cm3", { startTime: 1 });
               performance.mark("cm4", { startTime: 5 });
               performance.measure("cmm2", "cm3", "cm4");
               performance.clearMeasures();
               const marks = performance.getEntriesByType("mark");
               const measures = performance.getEntriesByType("measure");
               marks.length >= 2 && measures.length === 0
               """)
    end

    test "clearMarks with name clears only named marks", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("keep", { startTime: 1 });
               performance.mark("remove", { startTime: 2 });
               performance.mark("keep", { startTime: 3 });
               performance.clearMarks("remove");
               const all = performance.getEntriesByType("mark");
               all.every(e => e.name !== "remove") &&
                 all.filter(e => e.name === "keep").length >= 2
               """)
    end

    test "clearMeasures with name clears only named measures", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("s1", { startTime: 1 });
               performance.mark("s2", { startTime: 5 });
               performance.measure("keep-m", "s1", "s2");
               performance.measure("remove-m", "s1", "s2");
               performance.clearMeasures("remove-m");
               const measures = performance.getEntriesByType("measure");
               measures.some(e => e.name === "keep-m") &&
                 measures.every(e => e.name !== "remove-m")
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

  describe "toJSON" do
    test "performance.toJSON() returns object with timeOrigin", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const json = performance.toJSON();
               typeof json === 'object' && typeof json.timeOrigin === 'number'
               """)
    end

    test "toJSON timeOrigin matches performance.timeOrigin", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.toJSON().timeOrigin === performance.timeOrigin
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

  describe "entry toJSON" do
    test "mark toJSON has all properties", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mark = performance.mark("json-mark", { startTime: 5, detail: "d" });
               const json = mark.toJSON();
               json.name === "json-mark" && json.entryType === "mark" &&
                 json.startTime === 5 && json.duration === 0 && json.detail === "d"
               """)
    end

    test "measure toJSON has all properties", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               performance.mark("jm1", { startTime: 10 });
               performance.mark("jm2", { startTime: 20 });
               const measure = performance.measure("json-measure", "jm1", "jm2");
               const json = measure.toJSON();
               json.name === "json-measure" && json.entryType === "measure" &&
                 json.startTime === 10 && json.duration === 10
               """)
    end
  end
end
