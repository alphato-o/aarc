-- Direct line between the runner and the agent ("talk right to you").
-- Founder, 2026-10-13: a terminal in the app that mirrors this chat, so he
-- can ask for things from the gym when Claude Code remote control is dead.
CREATE TABLE IF NOT EXISTS agent_thread (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  role       TEXT NOT NULL,            -- 'user' (phone) | 'agent'
  text       TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  seen_at    TEXT                      -- agent marks user rows read; phone marks agent rows
);
CREATE INDEX IF NOT EXISTS agent_thread_role_seen ON agent_thread(role, seen_at);
