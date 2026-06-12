-- Waitlist / "I'm interested" email collector for the public marketing site
-- (aarun.club). One row per email; re-submits are ignored (UNIQUE email).
CREATE TABLE IF NOT EXISTS waitlist (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    email       TEXT NOT NULL UNIQUE,
    source      TEXT,            -- where on the site they signed up (hero/band/…)
    referer     TEXT,            -- HTTP referer, if any
    ua          TEXT,            -- user-agent, for rough device/geo sense
    country     TEXT,            -- Cloudflare cf.country, if present
    created_at  TEXT NOT NULL    -- ISO-8601
);

CREATE INDEX IF NOT EXISTS idx_waitlist_created ON waitlist (created_at DESC);
