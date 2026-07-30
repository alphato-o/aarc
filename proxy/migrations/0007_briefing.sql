-- Home Base briefing channel. The agent ("home") pushes short, dated intel
-- items — today's buzz on X, an AI launch that stings, a rival's funding round,
-- a system-status fact from the run itself — and EVERY prompt builder injects
-- the fresh ones into both voices' prompts as live material.
--
-- This is the thing only the agent can do: Ricky and Jessica have no internet.
-- Written by admin scope (POST /live/briefing), read server-side.
CREATE TABLE IF NOT EXISTS home_briefing (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL DEFAULT 'buzz',   -- buzz | rival | system | note
  text       TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT                             -- NULL = live until deleted
);

CREATE INDEX IF NOT EXISTS idx_home_briefing_fresh ON home_briefing(expires_at, id);
