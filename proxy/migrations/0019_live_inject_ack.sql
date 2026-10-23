-- A line handed to the phone is only done once the phone acks it; an unacked
-- line is served again (23 Oct: a reply handed out mid-reconnect was lost).
ALTER TABLE live_inject ADD COLUMN served_at TEXT;
