[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs,zig}"],
  plugins: [Zig.Formatter],
  locals_without_parens: [
    builtin: 2,
    builtin: 3,
    static: 1,
    static: 2,
    method: 1,
    method: 2,
    prototype: 1,
    prototype: 2,
    static_value: 2,
    static_value: 3,
    prototype_value: 2,
    prototype_value: 3,
    constant: 2,
    getter: 1,
    getter: 2,
    accessor: 2,
    static_accessor: 2
  ]
]
