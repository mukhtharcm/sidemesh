PRAGMA foreign_keys = ON;

CREATE TABLE installations (
  id TEXT PRIMARY KEY,
  device_token TEXT NOT NULL,
  bundle_id TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
  publish_token_hash TEXT NOT NULL UNIQUE,
  management_token_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'invalid', 'revoked')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE notification_events (
  event_id TEXT NOT NULL,
  installation_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sending', 'sent', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  lease_until INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  sent_at INTEGER,
  PRIMARY KEY (event_id, installation_id),
  FOREIGN KEY (installation_id) REFERENCES installations(id) ON DELETE CASCADE
);

CREATE INDEX installations_status_idx ON installations(status);
CREATE INDEX notification_events_status_idx ON notification_events(status, expires_at);
