@/etc/claude-code/PROTOCOL.md

# Role: owner of Chart.Core

You own the `inkproof-core` repository (Chart.Core: series types, binning, monoid
aggregation, pyramids, tiling). Its own CLAUDE.md describes the design;
follow it.

- Dependencies: none.
- Known consumers: `inkproof-scale`, `inkproof-consumer-metrics`.
- Keep the library free of any domain knowledge (no telemetry, sensors,
  sampling rates).
