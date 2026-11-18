# Test fixtures

`pp/` contains unmodified sample and test files from the Portfolio Performance project
(https://github.com/portfolio-performance/portfolio, Eclipse Public License 1.0). They are used
only as interoperability test data for the importer:

- `kommer.xml` — demo portfolio shipped with the PP UI (file version 60)
- `client52.xml`, `client69.xml`, `client_with_*_references.xml`, `client_with_security_events.xml`,
  `client69.binary.portfolio`, `client53.encrypted.portfolio` (upstream name `client53.xml+pwd.portfolio`)
  — from `name.abuchen.portfolio.tests/src/fileversions`
- `currency_sample.xml`, `classification_test_case.xml`, `client_performance_snapshot.xml`,
  `security_tax_and_fee_account_transactions.xml`, `trade_test_case.xml`, `Issue*.xml` — test scenarios
- `client69.xml.zip` — `client69.xml` stored as `data.xml` in a ZIP archive (created locally with `zip -9`),
  mirroring PP's "compressed XML" container

`csv/` contains hand-written CSV samples in the shapes PP and common brokers export.

`pp/synthetic_all_types.xml` is hand-written (every transaction type once, deeply nested XStream
structure, XPath references); `pp/synthetic_all_types_ids.xml` is the same document converted to
`id`/`reference` style by an independent script.

## Independent reference data

- `pp_reference.json` — entity counts, the unified ledger, account balances, share positions and price
  checksums of every real PP fixture, computed by `tools/pp_reference.py` (Python + lxml: references are
  resolved by a real XPath engine, nothing is shared with the Swift code). Compared in `ReferenceTests.swift`.
- `csv_value_reference.json` — 500 numbers and 300 dates in broker notations with expected values from
  Python's `decimal` / `datetime` (`tools/csv_value_reference.py`).

Regenerate from this directory:

    uv run --with lxml python -I tools/pp_reference.py pp pp_reference.json
    python3 tools/csv_value_reference.py csv_value_reference.json
