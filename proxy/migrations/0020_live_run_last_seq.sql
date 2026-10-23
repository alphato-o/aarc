-- Highest event seq stored for a run: a batch resent after a lost response
-- is skipped instead of landing twice (235+ phones number their events).
ALTER TABLE live_run ADD COLUMN last_seq INTEGER;
