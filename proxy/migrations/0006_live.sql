-- Live in-run channel: the app streams events for a flagged REAL run, and the
-- agent ("home") can push a spoken line back. Ephemeral — one row per run.
CREATE TABLE IF NOT EXISTS live_run (
  run_id        TEXT PRIMARY KEY,
  started_at    TEXT NOT NULL,
  last_event_at TEXT,
  ended_at      TEXT,
  recent_events TEXT NOT NULL DEFAULT '[]'   -- rolling JSON array (last ~200)
);

CREATE TABLE IF NOT EXISTS live_inject (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id      TEXT NOT NULL,
  text        TEXT NOT NULL,
  voice_id    TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (datetime('now')),
  consumed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_live_inject_pending ON live_inject(run_id, consumed_at);
