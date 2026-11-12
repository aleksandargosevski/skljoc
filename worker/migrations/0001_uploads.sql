CREATE TABLE uploads (
  id TEXT PRIMARY KEY,
  object_key TEXT NOT NULL,
  filename TEXT NOT NULL,
  content_type TEXT NOT NULL,
  size INTEGER NOT NULL DEFAULT 0,
  width INTEGER,
  height INTEGER,
  duration REAL,
  created_at INTEGER NOT NULL,
  -- Unix seconds; NULL means the upload never expires.
  expires_at INTEGER,
  is_private INTEGER NOT NULL DEFAULT 0,
  password_hash TEXT,
  -- One-time links: gone after the first view.
  burn INTEGER NOT NULL DEFAULT 0,
  burned_at INTEGER,
  views INTEGER NOT NULL DEFAULT 0,
  last_viewed_at INTEGER,
  poster_key TEXT,
  -- Set while a multipart upload is still in progress.
  multipart_upload_id TEXT
);

CREATE INDEX uploads_created_at ON uploads (created_at DESC);
CREATE INDEX uploads_expires_at ON uploads (expires_at) WHERE expires_at IS NOT NULL;
