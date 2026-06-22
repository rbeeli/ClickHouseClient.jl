# AGENTS.md

Guidelines for maintaining `ClickHouseClient.jl`.

## Project Goals

- Build a mature, Julia-native ClickHouse client for the native TCP protocol.
- Prefer intuitive APIs that feel natural to Julia users: Tables.jl integration,
  columnar data paths, clear result objects, and predictable exceptions.
- Preserve protocol correctness before adding convenience features. Native packet
  layout, revision gates, compression bytes, and type serialization must match
  ClickHouse behavior.

## Engineering Standards

- Keep public APIs documented. Any new exported symbol, query option, type
  mapping, compression mode, or behavior change must update `docs/src/` in the
  same change.
- Keep tests close to the changed behavior. Add local protocol/type round-trip
  tests when a live ClickHouse server is not required, and add integration tests
  when server behavior matters.
- Group tests by functionality or domain. Keep `runtests.jl` files focused on
  orchestration and put substantive test coverage in separate files instead of
  accumulating unrelated cases in a single monolithic file.
- Favor type-stable code and concrete containers on hot paths. Avoid `Any`
  vectors, untyped dictionaries, and avoidable dynamic dispatch in column
  encoders, decoders, compression, and block materialization.
- Minimize allocations in native read/write paths. Reuse schema/order metadata
  where practical, avoid unnecessary copies, and be careful with conversions that
  materialize whole result sets.
- Use Julia interfaces instead of bespoke adapters when possible. Tables.jl
  should be the common surface for tabular input and output.
- Avoid silent data loss. Date/time precision, decimal scale, nullable values,
  FixedString byte length, and integer width conversions should validate and
  throw clear errors.
- Preserve column order for query results. Do not route ordered server results
  through unordered dictionaries unless the API explicitly asks for a dictionary.
- Server diagnostics should be retained. Do not drop ClickHouse error codes,
  names, messages, stack traces, nested exceptions, progress, logs, or profile
  events when the protocol provides them.

## Protocol And Type Work

- Check ClickHouse upstream protocol definitions before changing advertised
  protocol revisions or packet layouts.
- Only advertise or enable protocol features the client can handle safely. If a
  feature is intentionally unsupported, gate it clearly and fail with
  `UnsupportedProtocolFeature`.
- Add or update type parser tests for nested types, quoted parameters, escaped
  quotes, commas inside strings, and empty/invalid input.
- For new ClickHouse types, implement result type, read path, write path, state
  prefix handling, nullable/array/tuple interactions, and documentation.

## Performance Expectations

- Benchmark or inspect allocations for changes in:
  - block read/write paths,
  - compression/decompression,
  - `select`/`select_df` materialization,
  - `insert`, `insert_records`, and `insert_table`,
  - complex type encoders such as `LowCardinality`, `Variant`, `Dynamic`, and
    `JSON`.
- Do not add broad abstractions to hot paths unless they remove real complexity
  and compile to efficient code.

## Dependency Policy

- Keep dependencies purposeful. A dependency is acceptable when it supplies a
  mature Julia interface or proven codec/protocol behavior that would be risky
  to reimplement.
- Add direct dependencies when the package uses their public API directly, even
  if another dependency currently brings them transitively.
- Update `[compat]` whenever adding dependencies.

## Review Checklist

- Package loads with `julia --project=. -e 'using ClickHouseClient'`.
- Relevant unit tests pass without requiring a live ClickHouse server.
- Live-server integration tests are run when changing handshake, query, insert,
  compression, or server packet behavior.
- Documentation and examples match the current API.
- No unrelated generated docs, build artifacts, or user changes are included.

## Local Development

- `justfile` provides commands for launching a local ClickHouse server.
