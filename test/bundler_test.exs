defmodule QuickBEAM.JS.BundlerTest do
  use ExUnit.Case, async: true

  describe "bundle_file" do
    @tag :tmp_dir
    test "bundles a single file with no imports", %{tmp_dir: dir} do
      write!(dir, "main.js", "const x = 1 + 2;")

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
      assert js =~ "const x = 1 + 2"
    end

    @tag :tmp_dir
    test "resolves relative imports", %{tmp_dir: dir} do
      write!(dir, "utils.js", "export function add(a, b) { return a + b; }")
      write!(dir, "main.js", """
      import { add } from './utils.js'
      const result = add(1, 2);
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
      assert js =~ "function add"
      assert js =~ "add(1, 2)"
      refute js =~ "import"
    end

    @tag :tmp_dir
    test "resolves relative imports without extension", %{tmp_dir: dir} do
      write!(dir, "math.ts", "export const PI: number = 3.14;")
      write!(dir, "main.ts", """
      import { PI } from './math'
      console.log(PI);
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.ts"))
      assert js =~ "3.14"
    end

    @tag :tmp_dir
    test "resolves index files from directories", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      write!(dir, "lib/index.ts", "export const VERSION: string = '1.0';")
      write!(dir, "main.ts", """
      import { VERSION } from './lib'
      console.log(VERSION);
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.ts"))
      assert js =~ "1.0"
    end

    @tag :tmp_dir
    test "resolves bare specifiers from node_modules", %{tmp_dir: dir} do
      setup_fake_package(dir, "greet", %{
        "package.json" => ~s({"name":"greet","main":"index.js"}),
        "index.js" => "export function hello(name) { return 'hi ' + name; }"
      })

      write!(dir, "main.js", """
      import { hello } from 'greet'
      console.log(hello('world'));
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
      assert js =~ "function hello"
      assert js =~ ~s|hello("world")|
    end

    @tag :tmp_dir
    test "resolves scoped packages", %{tmp_dir: dir} do
      setup_fake_package(dir, "@myorg/utils", %{
        "package.json" => ~s({"name":"@myorg/utils","module":"dist/index.js"}),
        "dist/index.js" => "export const VERSION = '2.0';"
      })

      write!(dir, "main.js", """
      import { VERSION } from '@myorg/utils'
      console.log(VERSION);
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
      assert js =~ "2.0"
    end

    @tag :tmp_dir
    test "resolves package exports field", %{tmp_dir: dir} do
      setup_fake_package(dir, "modern-pkg", %{
        "package.json" => ~s({"name":"modern-pkg","exports":{".":"./src/main.js"}}),
        "src/main.js" => "export const value = 42;"
      })

      write!(dir, "main.js", """
      import { value } from 'modern-pkg'
      console.log(value);
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
      assert js =~ "42"
    end

    @tag :tmp_dir
    test "handles transitive dependencies", %{tmp_dir: dir} do
      write!(dir, "a.js", "export const A = 'a';")
      write!(dir, "b.js", """
      import { A } from './a.js'
      export const B = A + 'b';
      """)
      write!(dir, "main.js", """
      import { B } from './b.js'
      console.log(B);
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
      assert js =~ ~s(const A = "a")
      assert js =~ ~s(A + "b")
    end

    @tag :tmp_dir
    test "circular imports don't hang (detected by OXC topo sort)", %{tmp_dir: dir} do
      write!(dir, "a.js", """
      import { B } from './b.js'
      export const A = 'a';
      """)
      write!(dir, "b.js", """
      import { A } from './a.js'
      export const B = 'b';
      """)
      write!(dir, "main.js", """
      import { A } from './a.js'
      import { B } from './b.js'
      console.log(A, B);
      """)

      assert {:error, ["Circular dependency detected"]} =
               QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
    end

    @tag :tmp_dir
    test "strips TypeScript from .ts files", %{tmp_dir: dir} do
      write!(dir, "main.ts", """
      import { greet } from './helper'
      const result: string = greet('world');
      """)
      write!(dir, "helper.ts", """
      export function greet(name: string): string { return 'hi ' + name; }
      """)

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.ts"))
      refute js =~ ":"
      assert js =~ "function greet"
    end

    @tag :tmp_dir
    test "returns error for missing import", %{tmp_dir: dir} do
      write!(dir, "main.js", """
      import { foo } from './nonexistent'
      """)

      assert {:error, {:module_not_found, _, _}} =
               QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
    end

    @tag :tmp_dir
    test "returns error for missing npm package", %{tmp_dir: dir} do
      write!(dir, "main.js", """
      import { foo } from 'no-such-package'
      """)

      assert {:error, {:module_not_found, "no-such-package", _}} =
               QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"))
    end

    @tag :tmp_dir
    test "passes bundle options through", %{tmp_dir: dir} do
      write!(dir, "main.js", "const x = 1 + 2;")

      assert {:ok, js} = QuickBEAM.JS.bundle_file(Path.join(dir, "main.js"), minify: true)
      refute js =~ "const x"
    end
  end

  describe "runtime script auto-bundling" do
    @tag :tmp_dir
    test "script option bundles imports automatically", %{tmp_dir: dir} do
      write!(dir, "utils.js", "export function double(n) { return n * 2; }")
      write!(dir, "app.js", """
      import { double } from './utils.js'
      globalThis.result = double(21);
      """)

      {:ok, rt} = QuickBEAM.start(script: Path.join(dir, "app.js"))
      assert {:ok, 42} = QuickBEAM.eval(rt, "result")
      QuickBEAM.stop(rt)
    end

    @tag :tmp_dir
    test "script option transforms TypeScript", %{tmp_dir: dir} do
      write!(dir, "app.ts", "const x: number = 42; globalThis.tsResult = x;")

      {:ok, rt} = QuickBEAM.start(script: Path.join(dir, "app.ts"))
      assert {:ok, 42} = QuickBEAM.eval(rt, "tsResult")
      QuickBEAM.stop(rt)
    end

    @tag :tmp_dir
    test "script option bundles TypeScript with imports", %{tmp_dir: dir} do
      write!(dir, "math.ts", """
      export function add(a: number, b: number): number { return a + b; }
      """)
      write!(dir, "app.ts", """
      import { add } from './math'
      globalThis.sum = add(19, 23);
      """)

      {:ok, rt} = QuickBEAM.start(script: Path.join(dir, "app.ts"))
      assert {:ok, 42} = QuickBEAM.eval(rt, "sum")
      QuickBEAM.stop(rt)
    end

    @tag :tmp_dir
    test "plain JS without imports skips bundling", %{tmp_dir: dir} do
      write!(dir, "simple.js", "globalThis.plain = true;")

      {:ok, rt} = QuickBEAM.start(script: Path.join(dir, "simple.js"))
      assert {:ok, true} = QuickBEAM.eval(rt, "plain")
      QuickBEAM.stop(rt)
    end
  end

  defp write!(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp setup_fake_package(dir, name, files) do
    pkg_dir = Path.join([dir, "node_modules", name])

    Enum.each(files, fn {filename, content} ->
      path = Path.join(pkg_dir, filename)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)
  end
end
