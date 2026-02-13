ALTER TABLE jobs ADD COLUMN routing TEXT;
ALTER TABLE jobs ADD COLUMN routing_target TEXT;
ALTER TABLE jobs ADD COLUMN routing_index INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_jobs_routing_target ON jobs(routing_target) WHERE routing_target IS NOT NULL;
