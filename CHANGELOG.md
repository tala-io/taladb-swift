# Changelog

## 0.1.1 — 2026-10-04

- Fixed: new live queries no longer wait behind running ones, so screens show their content immediately.
- `close()` waits for at most one poll, however many live queries are open.
- Added Swift Package Index configuration.

## 0.1.0 — 2026-10-03

- First release: TalaDB for native iOS and macOS apps in Swift.
- `Codable` and JSON collections, filters, updates, and secondary, compound, full-text and vector indexes.
- Live queries as `AsyncThrowingStream`.
- BM25 full-text search, vector search (flat and HNSW) and hybrid search.
- Encryption at rest and migrations.
- Built on TalaDB engine v0.12.0; iOS 13+ and macOS 10.15+.
