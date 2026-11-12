-- Every short link on the domain: an uploaded file, or a redirect to another URL.
CREATE TABLE links (
  -- The path: random for uploads (aB3x9KqZ), or chosen for redirects (cv).
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('file', 'redirect')),
  -- Redirects
  target_url TEXT,
  -- Files
  object_key TEXT,
  filename TEXT,
  content_type TEXT,
  size INTEGER NOT NULL DEFAULT 0,
  width INTEGER,
  height INTEGER,
  duration REAL,
  poster_key TEXT,
  -- Set while a multipart upload is still in progress.
  multipart_upload_id TEXT,
  -- Both
  created_at INTEGER NOT NULL,
  -- Unix seconds; NULL means the link never expires.
  expires_at INTEGER,
  is_private INTEGER NOT NULL DEFAULT 0,
  password_hash TEXT,
  -- One-time links: gone after the first view.
  burn INTEGER NOT NULL DEFAULT 0,
  burned_at INTEGER,
  -- Views of a file's page, or clicks on a redirect.
  views INTEGER NOT NULL DEFAULT 0,
  last_viewed_at INTEGER
);

CREATE INDEX links_kind_created_at ON links (kind, created_at DESC);
CREATE INDEX links_expires_at ON links (expires_at) WHERE expires_at IS NOT NULL;
