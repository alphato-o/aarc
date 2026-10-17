-- Race day: the live feed is append-only for a race run, so the Control Room
-- can replay the whole race (GPS fixes, metrics, battery, every spoken line)
-- instead of the 200-event rolling window.
ALTER TABLE live_run ADD COLUMN race INTEGER NOT NULL DEFAULT 0;
ALTER TABLE live_run ADD COLUMN course TEXT;
CREATE TABLE IF NOT EXISTS live_event (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id     TEXT NOT NULL,
  t          INTEGER NOT NULL,
  type       TEXT NOT NULL,
  detail     TEXT NOT NULL DEFAULT '',
  data       TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_live_event_run ON live_event(run_id, id);
