-- Personal-troll bullets, editable from the dashboard (too long to edit on
-- the phone). Single row; the iOS app pulls it at launch and sends a rotated
-- subset with each LLM request.
CREATE TABLE IF NOT EXISTS personal_notes (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    body        TEXT NOT NULL DEFAULT '',
    updated_at  TEXT NOT NULL DEFAULT ''
);
INSERT OR IGNORE INTO personal_notes (id, body, updated_at) VALUES (1, '', '');
