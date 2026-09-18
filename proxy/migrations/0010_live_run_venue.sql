-- Pin the confirmed venue and city on the live run row. The status feed only
-- carries the last 200 events, and on 2026-09-18 the venue confirmation
-- (event 27s in) had scrolled off by the first Home Base check, so the agent
-- told the runner "no venue confirmed" while he was standing in it.
ALTER TABLE live_run ADD COLUMN venue TEXT;
ALTER TABLE live_run ADD COLUMN city TEXT;
