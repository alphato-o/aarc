-- What a CONFIRMED venue is actually like, researched by the agent once and
-- reused on every run there.
--
-- Founder, 2026-08-17: "once i confirm park hyatt, i want you to actually look
-- at the gym, what it looks like, what's my view if i am running on a
-- treadmill in there... Ricky kept saying i face a wall and there are TVs and
-- mirrors in the gym, it's not the case."
--
-- He was right, and the fault was ours: the treadmill prompt LITERALLY
-- instructed "the mirror they keep glancing at" and "the TV bolted to the
-- wall". Ricky was obeying. Generic gym furniture is a reasonable default when
-- we know nothing; it is a lie once we know the man is on the 59th floor
-- looking at the CBD skyline through a wall of glass.
CREATE TABLE IF NOT EXISTS venue_profile (
  venue_key  TEXT PRIMARY KEY,   -- normalised venue name (lowercase, squeezed)
  venue      TEXT NOT NULL,      -- display name as the runner confirmed it
  profile    TEXT NOT NULL,      -- prose the voices can actually use
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
