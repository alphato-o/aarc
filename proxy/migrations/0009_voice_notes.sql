-- Post-run voice notes: the runner talks into his phone while the memory is
-- fresh, we keep the audio AND a cleaned-up transcript.
--
-- Founder, 2026-08-31 (recorded as a voice note about wanting voice notes):
-- "You should add a voice note after every run just because my memory is so
-- fresh and then I can note down what went wrong... I'd expect my notes to
-- display in both original voice audio and cleaned up text."
--
-- Audio lives in R2 under voicenotes/<runId>/<noteId>.m4a; this table holds
-- the text and the processing state so the phone can poll for it later. The
-- transcript is deliberately stored in two columns: what was actually said,
-- and the tidied version. Overwriting the raw text with a cleaned one would
-- throw away the only record of what he really uttered.
CREATE TABLE IF NOT EXISTS voice_note (
  note_id     TEXT PRIMARY KEY,
  run_id      TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (datetime('now')),
  audio_key   TEXT,                      -- R2 object key
  duration_s  REAL,
  status      TEXT NOT NULL DEFAULT 'pending',  -- pending | done | failed
  provider    TEXT,                      -- which STT actually ran
  raw_text    TEXT,                      -- verbatim transcript
  clean_text  TEXT,                      -- tidied, punctuated, de-ummed
  error       TEXT
);

CREATE INDEX IF NOT EXISTS idx_voice_note_run ON voice_note(run_id, created_at);
