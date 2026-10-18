-- What music played when, per run (founder, 2026-10-18: the race video needs
-- to know what he was hearing at every moment). 'live' rows come from the
-- in-run poll (at = when the track started); 'history' rows from Spotify's
-- recently-played backfill (at = Spotify's played_at), which covers the
-- stretches the phone was offline.
CREATE TABLE IF NOT EXISTS music_play (
  run_id      TEXT NOT NULL,
  source      TEXT NOT NULL,
  at          TEXT NOT NULL,
  event       TEXT NOT NULL,
  track_id    TEXT,
  title       TEXT NOT NULL,
  artist      TEXT,
  album       TEXT,
  duration_ms INTEGER,
  PRIMARY KEY (run_id, source, at, event)
);
