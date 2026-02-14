ALTER TABLE jobs ADD COLUMN parent_id TEXT REFERENCES jobs(id);
ALTER TABLE jobs ADD COLUMN chain_config TEXT;
ALTER TABLE jobs ADD COLUMN chain_id TEXT;
ALTER TABLE jobs ADD COLUMN chain_step INTEGER;

CREATE INDEX IF NOT EXISTS idx_jobs_parent ON jobs(parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_chain ON jobs(chain_id) WHERE chain_id IS NOT NULL;
