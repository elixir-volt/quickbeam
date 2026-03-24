Application.ensure_all_started(:telemetry)
ExUnit.start(exclude: [:napi_sqlite])
