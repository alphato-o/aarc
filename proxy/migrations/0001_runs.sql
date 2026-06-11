-- Migration 0001: per-run event log (database: aarc-runs, binding: DB)
-- Apply:
--   npx wrangler d1 migrations apply aarc-runs --remote
-- (and without --remote for the local dev DB)

CREATE TABLE IF NOT EXISTS runs (
    run_id      TEXT PRIMARY KEY,
    started_at  TEXT,
    uploaded_at TEXT,
    event_count INTEGER,
    meta        TEXT
);

CREATE TABLE IF NOT EXISTS run_events (
    run_id TEXT,
    t      REAL,
    wall   TEXT,
    type   TEXT,
    detail TEXT,
    data   TEXT
);

CREATE INDEX IF NOT EXISTS idx_run_events_run_t ON run_events (run_id, t);
