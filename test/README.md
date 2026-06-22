# Tests

Tests are split by whether they require a live ClickHouse server.

- `unit/`: protocol, parser, serialization, compression, fixture replay, and
  other tests that run without ClickHouse.
- `integration/`: live-server behavior such as handshake, query execution,
  inserts, compression negotiation, and server packet handling.

Run unit tests with:

```sh
just test-unit
```

Run integration tests after starting ClickHouse:

```sh
just start
just test-integration
```
