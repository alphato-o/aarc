-- Dashboard QR sign-in v1: pending auth codes.
-- A code is created when the login page renders, approved by the iOS app
-- via POST /dash/auth/approve (X-AARC-Device == DEVICE_TOKEN), and consumed
-- by the first approved poll. Codes expire after 10 minutes (enforced in
-- the Worker, rows are garbage-collected on each login-page render).
CREATE TABLE IF NOT EXISTS dash_auth (
    code TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    approved INTEGER NOT NULL DEFAULT 0
);
