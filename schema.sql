-- Book table - matches KOReader's structure + cover_url
CREATE TABLE IF NOT EXISTS book (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT,
  authors TEXT,
  pages INTEGER,                      -- total pages
  md5 TEXT,                           -- KOReader's unique identifier
  cover_url TEXT,                     -- fetched once from OpenLibrary
  total_read_time INTEGER DEFAULT 0,  -- cached sum from page_stat_data
  total_read_pages INTEGER DEFAULT 0, -- cached count from page_stat_data
  last_open INTEGER                   -- unix timestamp
);
CREATE UNIQUE INDEX IF NOT EXISTS book_md5 ON book(md5);

-- Page stat data - matches KOReader exactly
CREATE TABLE IF NOT EXISTS page_stat_data (
  id_book INTEGER NOT NULL,
  page INTEGER NOT NULL DEFAULT 0,
  start_time INTEGER NOT NULL DEFAULT 0,
  duration INTEGER NOT NULL DEFAULT 0,
  total_pages INTEGER NOT NULL DEFAULT 0,
  UNIQUE (id_book, page, start_time),
  FOREIGN KEY(id_book) REFERENCES book(id)
);
CREATE INDEX IF NOT EXISTS idx_page_stat_book ON page_stat_data(id_book);
CREATE INDEX IF NOT EXISTS idx_page_stat_time ON page_stat_data(start_time);

-- Sync state - track last sync per book
CREATE TABLE IF NOT EXISTS sync_state (
  book_md5 TEXT PRIMARY KEY,
  last_sync_time INTEGER NOT NULL DEFAULT 0
);
