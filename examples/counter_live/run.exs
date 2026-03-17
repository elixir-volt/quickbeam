IO.puts("""
╔══════════════════════════════════════════════════════╗
║         QuickBEAM Counter + LiveView Example         ║
║  Each session = one ~58 KB JS context from a pool    ║
╚══════════════════════════════════════════════════════╝

Open http://localhost:4000
Each browser tab gets its own JS context with independent state.
""")

Process.sleep(:infinity)
