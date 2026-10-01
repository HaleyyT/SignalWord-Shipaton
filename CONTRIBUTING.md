# Contributing

## Before opening a pull request

- Keep the change small and describe its user or safety impact.
- Run `npm run verify`.
- Add or update deterministic tests for code changes.
- For iOS trigger, permissions, location, or delivery behavior, record the applicable physical-device evidence in `docs/build-notes.md`.
- Confirm no public wording exceeds the evidence in `docs/CLAIMS_LEDGER.md`.
- Never commit credentials, contact destinations, tokens, precise coordinates, or real user screenshots.

## Commit convention

Use short imperative messages that identify the result, such as `Add secure viewer contract tests` or `Document local development workflow`. Separate code, generated dependency locks, and unrelated documentation changes when that makes review clearer.
