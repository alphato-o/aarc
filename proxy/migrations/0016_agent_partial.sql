-- The running transcript of a talk-back line while he is still speaking
-- (founder, 2026-10-17: "I would expect to see what I am actually speaking
-- on the screen"). One row per line, overwritten as it grows.
CREATE TABLE IF NOT EXISTS agent_partial (
  client_id  TEXT PRIMARY KEY,
  text       TEXT NOT NULL,
  run_id     TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS agent_partial_updated ON agent_partial(updated_at);
