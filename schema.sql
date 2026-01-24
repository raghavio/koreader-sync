-- Books table
CREATE TABLE IF NOT EXISTS books (
  id TEXT PRIMARY KEY,  -- ISBN if available, otherwise hash(title+author)
  isbn TEXT,            -- stored separately for lookups even when not used as ID
  title TEXT NOT NULL,
  author TEXT,
  total_pages INTEGER,
  created_at TEXT DEFAULT (datetime('now'))
);

-- Current reading status (one row per book, updated on each event)
CREATE TABLE IF NOT EXISTS reading_status (
  book_id TEXT PRIMARY KEY,
  current_page INTEGER,
  progress_percent REAL,
  last_read_at TEXT,
  FOREIGN KEY(book_id) REFERENCES books(id)
);

-- Page turn events (granular tracking)
CREATE TABLE IF NOT EXISTS page_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  book_id TEXT NOT NULL,
  page_number INTEGER,
  progress_percent REAL,
  session_id TEXT,
  timestamp TEXT DEFAULT (datetime('now')),
  FOREIGN KEY(book_id) REFERENCES books(id)
);

-- Reading sessions
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  book_id TEXT NOT NULL,
  started_at TEXT,
  ended_at TEXT,
  start_page INTEGER,
  end_page INTEGER,
  pages_read INTEGER,
  FOREIGN KEY(book_id) REFERENCES books(id)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_page_events_book ON page_events(book_id);
CREATE INDEX IF NOT EXISTS idx_page_events_timestamp ON page_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_sessions_book ON sessions(book_id);
