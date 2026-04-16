defmodule QuickBEAM.BeamVM.WPTLanguageTest do
  @moduledoc """
  WPT-style tests for JS language semantics in beam mode.
  Covers scoping, closures, iteration patterns, error handling,
  and complex expressions that stress the interpreter.
  """
  use ExUnit.Case, async: false

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  defp ev(rt, code), do: QuickBEAM.eval(rt, code, mode: :beam)
  defp ok(rt, code, expected), do: assert({:ok, expected} = ev(rt, code))

  # ═══════════════════════════════════════════════════════════════════════
  # Variable scoping
  # ═══════════════════════════════════════════════════════════════════════

  describe "var scoping" do
    test "var is function-scoped", %{rt: rt} do
      ok(rt, "(function(){ if(true){ var x = 1 } return x })()", 1)
    end

    test "var hoisting", %{rt: rt} do
      ok(rt, "(function(){ var x = 1; { var x = 2 } return x })()", 2)
    end
  end

  describe "let scoping" do
    test "let is block-scoped", %{rt: rt} do
      ok(rt, "(function(){ let x = 1; { let x = 2 } return x })()", 1)
    end

    test "let in for loop creates new binding per iteration", %{rt: rt} do
      ok(rt, "(function(){ var fns = []; for(let i=0; i<3; i++) fns.push(function(){ return i }); return fns[0]() + fns[1]() + fns[2]() })()", 3)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Closure patterns
  # ═══════════════════════════════════════════════════════════════════════

  describe "closure patterns" do
    test "counter", %{rt: rt} do
      ok(rt, """
      (function(){
        function counter(start) {
          var n = start;
          return { inc: function(){ return ++n }, get: function(){ return n } }
        }
        var c = counter(10);
        c.inc(); c.inc(); c.inc();
        return c.get()
      })()
      """, 13)
    end

    test "accumulator", %{rt: rt} do
      ok(rt, """
      (function(){
        var total = 0;
        function add(n) { total += n }
        add(10); add(20); add(30);
        return total
      })()
      """, 60)
    end

    test "closure in array callbacks", %{rt: rt} do
      ok(rt, """
      (function(){
        var nums = [1,2,3,4,5];
        var sum = 0;
        nums.forEach(function(n){ sum += n });
        return sum
      })()
      """, 15)
    end

    test "nested closures share outer scope", %{rt: rt} do
      ok(rt, """
      (function(){
        var x = 0;
        function a(){ x += 1 }
        function b(){ x += 10 }
        a(); b(); a();
        return x
      })()
      """, 12)
    end

    @tag :pending_this
    test "IIFE captures variables", %{rt: rt} do
      ok(rt, """
      (function(){
        var result = [];
        for(var i=0; i<3; i++){
          (function(j){
            result.push(function(){ return j })
          })(i)
        }
        return result[0]() + result[1]() + result[2]()
      })()
      """, 3)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Iteration patterns
  # ═══════════════════════════════════════════════════════════════════════

  describe "iteration patterns" do
    test "nested for loops", %{rt: rt} do
      ok(rt, """
      (function(){
        var sum = 0;
        for(var i=0; i<3; i++){
          for(var j=0; j<3; j++){
            sum += i * 3 + j
          }
        }
        return sum
      })()
      """, 36)
    end

    test "while with break", %{rt: rt} do
      ok(rt, """
      (function(){
        var i = 0;
        while(true){
          if(i >= 5) break;
          i++;
        }
        return i
      })()
      """, 5)
    end

    test "for with continue", %{rt: rt} do
      ok(rt, """
      (function(){
        var sum = 0;
        for(var i=0; i<10; i++){
          if(i % 2 !== 0) continue;
          sum += i;
        }
        return sum
      })()
      """, 20)
    end

    test "map/filter chain", %{rt: rt} do
      ok(rt, """
      (function(){
        return [1,2,3,4,5,6,7,8,9,10]
          .filter(function(x){ return x % 2 === 0 })
          .map(function(x){ return x * x })
          .reduce(function(a,b){ return a + b }, 0)
      })()
      """, 220)
    end

    test "forEach building object", %{rt: rt} do
      ok(rt, """
      (function(){
        var pairs = [["a",1],["b",2],["c",3]];
        var obj = {};
        pairs.forEach(function(p){ obj[p[0]] = p[1] });
        return obj.a + obj.b + obj.c
      })()
      """, 6)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Try/catch/finally patterns
  # ═══════════════════════════════════════════════════════════════════════

  describe "error handling" do
    test "catch and continue", %{rt: rt} do
      ok(rt, """
      (function(){
        var result = 0;
        try { throw "err" } catch(e) { result = 1 }
        result += 10;
        return result
      })()
      """, 11)
    end

    test "finally always runs", %{rt: rt} do
      ok(rt, """
      (function(){
        var x = 0;
        try { x = 1; throw "err" } catch(e) { x += 10 } finally { x += 100 }
        return x
      })()
      """, 111)
    end

    test "nested try/catch", %{rt: rt} do
      ok(rt, """
      (function(){
        try {
          try { throw "inner" }
          catch(e) { throw "outer:" + e }
        }
        catch(e) { return e }
      })()
      """, "outer:inner")
    end

    test "try/catch in loop", %{rt: rt} do
      ok(rt, """
      (function(){
        var errors = 0;
        for(var i=0; i<5; i++){
          try {
            if(i % 2 === 0) throw "err";
          } catch(e) { errors++ }
        }
        return errors
      })()
      """, 3)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Object patterns
  # ═══════════════════════════════════════════════════════════════════════

  describe "object patterns" do
    test "computed property names", %{rt: rt} do
      ok(rt, """
      (function(){
        var key = "hello";
        var obj = {};
        obj[key] = "world";
        return obj.hello
      })()
      """, "world")
    end

    @tag :pending_this
    test "object with methods", %{rt: rt} do
      ok(rt, """
      (function(){
        var obj = {
          x: 10,
          double: function(){ return this.x * 2 }
        };
        return obj.double()
      })()
      """, 20)
    end

    test "property deletion", %{rt: rt} do
      ok(rt, """
      (function(){
        var o = {a:1, b:2, c:3};
        delete o.b;
        return Object.keys(o).length
      })()
      """, 2)
    end

    test "in operator", %{rt: rt} do
      ok(rt, """
      (function(){
        var o = {a:1, b:2};
        return ("a" in o) && !("c" in o)
      })()
      """, true)
    end

    test "for-in collects all keys", %{rt: rt} do
      ok(rt, """
      (function(){
        var obj = {x:1, y:2, z:3};
        var keys = [];
        for(var k in obj) keys.push(k);
        return keys.length
      })()
      """, 3)
    end

    test "nested object access", %{rt: rt} do
      ok(rt, """
      (function(){
        var data = {
          users: [
            {name: "Alice", scores: [90, 85, 92]},
            {name: "Bob", scores: [78, 88, 95]}
          ]
        };
        return data.users[1].scores[2]
      })()
      """, 95)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Recursive algorithms
  # ═══════════════════════════════════════════════════════════════════════

  describe "recursion" do
    test "factorial", %{rt: rt} do
      ok(rt, """
      (function(){
        function factorial(n){ return n <= 1 ? 1 : n * factorial(n-1) }
        return factorial(10)
      })()
      """, 3628800)
    end

    test "fibonacci", %{rt: rt} do
      ok(rt, """
      (function(){
        function fib(n){ return n <= 1 ? n : fib(n-1) + fib(n-2) }
        return fib(15)
      })()
      """, 610)
    end

    @tag :pending_gas
    test "binary search", %{rt: rt} do
      ok(rt, """
      (function(){
        function bsearch(arr, target, lo, hi){
          if(lo > hi) return -1;
          var mid = Math.floor((lo + hi) / 2);
          if(arr[mid] === target) return mid;
          if(arr[mid] < target) return bsearch(arr, target, mid+1, hi);
          return bsearch(arr, target, lo, mid-1);
        }
        var arr = [2,5,8,12,16,23,38,56,72,91];
        return bsearch(arr, 23, 0, arr.length-1)
      })()
      """, 5)
    end

    @tag :pending_gas
    test "tree traversal", %{rt: rt} do
      ok(rt, """
      (function(){
        function sum(node){
          if(!node) return 0;
          return node.v + sum(node.l) + sum(node.r)
        }
        var tree = {v:1, l:{v:2, l:{v:4,l:null,r:null}, r:{v:5,l:null,r:null}}, r:{v:3,l:null,r:null}};
        return sum(tree)
      })()
      """, 15)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # String processing
  # ═══════════════════════════════════════════════════════════════════════

  describe "string processing" do
    test "word count", %{rt: rt} do
      ok(rt, ~s|(function(){ return "hello world foo bar".split(" ").length })()|, 4)
    end

    test "reverse words", %{rt: rt} do
      ok(rt, ~s|(function(){ return "hello world".split(" ").reverse().join(" ") })()|, "world hello")
    end

    test "capitalize first letter", %{rt: rt} do
      ok(rt, ~s|(function(){ var s = "hello"; return s.charAt(0).toUpperCase() + s.slice(1) })()|, "Hello")
    end

    test "camelCase to kebab-case", %{rt: rt} do
      ok(rt, """
      (function(){
        var s = "helloWorld";
        var result = "";
        for(var i = 0; i < s.length; i++){
          var c = s.charAt(i);
          if(c === c.toUpperCase() && i > 0){
            result += "-" + c.toLowerCase();
          } else {
            result += c;
          }
        }
        return result
      })()
      """, "hello-world")
    end

    test "count occurrences", %{rt: rt} do
      ok(rt, """
      (function(){
        var s = "abcabcabc";
        var count = 0;
        var idx = s.indexOf("abc");
        while(idx !== -1){
          count++;
          idx = s.indexOf("abc", idx + 1);
        }
        return count
      })()
      """, 3)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Array algorithms
  # ═══════════════════════════════════════════════════════════════════════

  describe "array algorithms" do
    test "unique values", %{rt: rt} do
      ok(rt, """
      (function(){
        var arr = [1,2,2,3,3,3,4];
        var unique = [];
        arr.forEach(function(x){
          if(unique.indexOf(x) === -1) unique.push(x)
        });
        return unique
      })()
      """, [1, 2, 3, 4])
    end

    test "flatten nested arrays", %{rt: rt} do
      ok(rt, """
      (function(){
        function flatten(arr){
          var result = [];
          arr.forEach(function(item){
            if(Array.isArray(item)){
              flatten(item).forEach(function(x){ result.push(x) });
            } else {
              result.push(item);
            }
          });
          return result
        }
        return flatten([1,[2,[3,4]],5])
      })()
      """, [1, 2, 3, 4, 5])
    end

    test "group by", %{rt: rt} do
      ok(rt, """
      (function(){
        var items = [{type:"a",v:1},{type:"b",v:2},{type:"a",v:3}];
        var groups = {};
        items.forEach(function(item){
          if(!groups[item.type]) groups[item.type] = [];
          groups[item.type].push(item.v);
        });
        return groups.a.length + groups.b.length
      })()
      """, 3)
    end

    test "zip two arrays", %{rt: rt} do
      ok(rt, """
      (function(){
        var a = [1,2,3], b = ["a","b","c"];
        var result = [];
        for(var i=0; i<a.length; i++) result.push([a[i], b[i]]);
        return result[1][0] + result[1][1]
      })()
      """, "2b")
    end

    test "insertion sort", %{rt: rt} do
      ok(rt, """
      (function(){
        var arr = [5,3,8,1,2];
        for(var i=1; i<arr.length; i++){
          var key = arr[i];
          var j = i - 1;
          while(j >= 0 && arr[j] > key){
            arr[j+1] = arr[j];
            j--;
          }
          arr[j+1] = key;
        }
        return arr
      })()
      """, [1, 2, 3, 5, 8])
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Switch statement
  # ═══════════════════════════════════════════════════════════════════════

  describe "switch" do
    test "matching case", %{rt: rt} do
      ok(rt, """
      (function(){
        switch(2){
          case 1: return "one";
          case 2: return "two";
          case 3: return "three";
          default: return "other";
        }
      })()
      """, "two")
    end

    test "default case", %{rt: rt} do
      ok(rt, """
      (function(){
        switch(99){
          case 1: return "one";
          default: return "other";
        }
      })()
      """, "other")
    end

    test "fall-through", %{rt: rt} do
      ok(rt, """
      (function(){
        var result = "";
        switch(1){
          case 1: result += "a";
          case 2: result += "b";
          case 3: result += "c"; break;
          case 4: result += "d";
        }
        return result
      })()
      """, "abc")
    end

    test "string switch", %{rt: rt} do
      ok(rt, ~s|(function(){ switch("hello"){ case "hello": return true; default: return false } })()|, true)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Conditional expressions
  # ═══════════════════════════════════════════════════════════════════════

  describe "conditional expressions" do
    test "nullish coalescing", %{rt: rt} do
      ok(rt, "null ?? 42", 42)
      ok(rt, "undefined ?? 42", 42)
      ok(rt, "0 ?? 42", 0)
      ok(rt, ~s|"" ?? 42|, "")
    end

    test "optional chaining", %{rt: rt} do
      ok(rt, "null?.foo", nil)
      ok(rt, "undefined?.bar", nil)
      ok(rt, "({a: 1})?.a", 1)
    end

    test "optional chaining nested", %{rt: rt} do
      ok(rt, "({a: {b: 42}})?.a?.b", 42)
      ok(rt, "({a: null})?.a?.b", nil)
    end

    test "short-circuit evaluation", %{rt: rt} do
      ok(rt, "(function(){ var x = 0; true || (x = 1); return x })()", 0)
      ok(rt, "(function(){ var x = 0; false && (x = 1); return x })()", 0)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Destructuring (extended)
  # ═══════════════════════════════════════════════════════════════════════

  describe "destructuring extended" do
    test "array destructuring", %{rt: rt} do
      ok(rt, "(function(){ var [a,b,c] = [10,20,30]; return a+b+c })()", 60)
    end

    test "object destructuring", %{rt: rt} do
      ok(rt, "(function(){ var {a,b} = {a:1,b:2,c:3}; return a+b })()", 3)
    end

    test "nested destructuring", %{rt: rt} do
      ok(rt, "(function(){ var {a: {b}} = {a: {b: 42}}; return b })()", 42)
    end

    test "swap via destructuring", %{rt: rt} do
      ok(rt, "(function(){ var a=1, b=2; [a,b] = [b,a]; return a*10+b })()", 21)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Template literals
  # ═══════════════════════════════════════════════════════════════════════

  describe "template literals" do
    test "expression", %{rt: rt} do
      ok(rt, ~s|`${2 + 3}`|, "5")
    end

    test "multipart", %{rt: rt} do
      ok(rt, ~s|(function(){ var a=1, b=2; return `${a} + ${b} = ${a+b}` })()|, "1 + 2 = 3")
    end

    test "nested ternary", %{rt: rt} do
      ok(rt, ~s|(function(){ var x = 5; return `${x > 3 ? "big" : "small"}` })()|, "big")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Real-world patterns
  # ═══════════════════════════════════════════════════════════════════════

  describe "real-world patterns" do
    @tag :pending_gas
    test "memoized fibonacci", %{rt: rt} do
      ok(rt, """
      (function(){
        var memo = {};
        function fib(n){
          if(n in memo) return memo[n];
          if(n <= 1) return n;
          memo[n] = fib(n-1) + fib(n-2);
          return memo[n]
        }
        return fib(30)
      })()
      """, 832040)
    end

    test "event emitter pattern", %{rt: rt} do
      ok(rt, """
      (function(){
        var handlers = {};
        function on(evt, fn){ if(!handlers[evt]) handlers[evt]=[]; handlers[evt].push(fn) }
        function emit(evt, data){ if(handlers[evt]) handlers[evt].forEach(function(fn){ fn(data) }) }
        var log = [];
        on("data", function(d){ log.push(d) });
        on("data", function(d){ log.push(d*2) });
        emit("data", 5);
        return log
      })()
      """, [5, 10])
    end

    test "linked list", %{rt: rt} do
      ok(rt, """
      (function(){
        function node(val, next){ return {val:val, next:next} }
        var list = node(1, node(2, node(3, null)));
        var sum = 0;
        var curr = list;
        while(curr !== null){
          sum += curr.val;
          curr = curr.next;
        }
        return sum
      })()
      """, 6)
    end

    test "pipeline with reduce", %{rt: rt} do
      ok(rt, """
      (function(){
        var transforms = [
          function(x){ return x + 10 },
          function(x){ return x * 2 },
          function(x){ return x - 5 }
        ];
        return transforms.reduce(function(val, fn){ return fn(val) }, 3)
      })()
      """, 21)
    end

    test "deep clone", %{rt: rt} do
      ok(rt, """
      (function(){
        var original = {a: 1, b: [2, 3], c: {d: 4}};
        var clone = JSON.parse(JSON.stringify(original));
        clone.a = 99;
        return original.a
      })()
      """, 1)
    end

    test "matrix operations", %{rt: rt} do
      ok(rt, """
      (function(){
        var m = [[1,2],[3,4]];
        var sum = 0;
        for(var i=0; i<m.length; i++){
          for(var j=0; j<m[i].length; j++){
            sum += m[i][j];
          }
        }
        return sum
      })()
      """, 10)
    end
  end
end
