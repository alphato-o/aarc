-- Talk-back during a run (founder, 2026-10-17): a thread row now says where it
-- came from (typed in the terminal, or spoken through Siri mid-run) and which
-- run it belongs to, so the agent can answer into that run's ears.
ALTER TABLE agent_thread ADD COLUMN source TEXT;
ALTER TABLE agent_thread ADD COLUMN run_id TEXT;
ALTER TABLE agent_thread ADD COLUMN meta TEXT;
