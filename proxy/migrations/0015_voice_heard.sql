-- When a Control Room line actually started playing in his ear (founder,
-- 2026-10-17: the race video needs both voices on one timeline, his from the
-- Action 6, ours from these timestamps). Written by the phone.
CREATE TABLE IF NOT EXISTS voice_heard (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  text      TEXT NOT NULL,
  voice_id  TEXT NOT NULL,
  heard_at  TEXT NOT NULL,   -- ISO 8601 from the phone's clock
  run_id    TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS voice_heard_at ON voice_heard(heard_at);
