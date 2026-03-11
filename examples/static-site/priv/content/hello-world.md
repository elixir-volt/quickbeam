---
title: Hello World
date: 2025-01-15
---

This is the first post on the blog, built entirely by the **BEAM**.

No Node.js process was harmed in the making of this page:

- TypeScript compiled by [OXC](https://oxc.rs)
- npm packages bundled at startup
- Markdown rendered by [marked](https://marked.js.org)
- File I/O through Erlang's `file` module
- The whole thing supervised by OTP

```elixir
QuickBEAM.start(script: "priv/ts/build.ts", apis: [:node])
```
