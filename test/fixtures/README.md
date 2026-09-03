# Test fixtures

- `findings-run-42.json` - 25 findings served by `test/stub-api.py` for run 42: every severity and validity, `autoInvalidated` crossed with `unreviewed`/`valid`, empty `sourceLocations`, titles with `|`, backticks, HTML and unicode, snippets with backticks and triple fences, a duplicate finding (105/118), a location with only `startLine`, a path with spaces and unicode, and a multi-location finding.
- `event-*.json` - GitHub event payloads (pull request, fork pull request, merge group, push).
- `report-*.json` - `report.json` documents produced by `test/make-fixtures.sh` from the stub, used as inputs for the golden-file tests. Regenerate with `make fixtures` after changing the processing code, then review the golden diffs.
- `sarif-schema-2.1.0.json` - the SARIF 2.1.0 JSON Schema (draft-07 flavour) from https://json.schemastore.org/sarif-2.1.0.json, used to validate the SARIF the action emits.
