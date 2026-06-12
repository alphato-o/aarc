-- Migration 0003: soft-delete + recycle bin for runs (database: aarc-runs, binding: DB)
-- Apply:
--   npx wrangler d1 migrations apply aarc-runs --remote
-- (and without --remote for the local dev DB)
--
-- deleted_at is NULL for active runs and an ISO-8601 timestamp once the run
-- is soft-deleted. The iPhone is the source of truth: deleting a run on the
-- phone calls POST /api/runs/:id/delete; the dashboard recycle bin can
-- restore (deleted_at -> NULL) or purge (hard DELETE). Re-ingesting a run_id
-- clears deleted_at (UPSERT in ingestRunHandler).

ALTER TABLE runs ADD COLUMN deleted_at TEXT;
