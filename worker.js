// Response Helpers
const CORS_HEADERS = Object.freeze({
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Content-Type": "application/json",
});

const jsonResponse = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: CORS_HEADERS });

const errorResponse = (message, status) =>
  jsonResponse({ error: message }, status);

const corsResponse = () =>
  new Response(null, { headers: CORS_HEADERS });

const withErrorHandling = (handler) => async (...args) => {
  try {
    const result = await handler(...args);
    return jsonResponse(result);
  } catch (e) {
    return errorResponse(e.message, e.status || 500);
  }
};

const withAuth = (handler) => async (request, env, ...rest) => {
  const authHeader = request.headers.get("Authorization");
  if (!env.AUTH_TOKEN || authHeader !== `Bearer ${env.AUTH_TOKEN}`) {
    return errorResponse("unauthorized", 401);
  }
  return handler(request, env, ...rest);
};

// Main Handler
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return corsResponse();
    }

    if (request.method === "POST" && url.pathname === "/events") {
      return withAuth(async (req, env) => {
        try {
          const events = await req.json();
          const results = [];
          for (const event of events) {
            try {
              await handleUpdate(env.DB, event);
              results.push({ ok: true });
            } catch (e) {
              results.push({ ok: false, error: e.message });
            }
          }
          const successCount = results.filter(r => r.ok).length;
          return jsonResponse({
            ok: successCount === events.length,
            processed: events.length,
            succeeded: successCount,
            failed: events.length - successCount,
          });
        } catch (e) {
          return errorResponse(e.message, 400);
        }
      })(request, env);
    }

    if (request.method === "GET" && url.pathname === "/activity") {
      return withErrorHandling(() => getActivity(env.DB))();
    }

    if (request.method === "GET" && url.pathname === "/books/current") {
      return withErrorHandling(() => getCurrentReading(env.DB))();
    }

    if (request.method === "GET" && url.pathname === "/books") {
      return withErrorHandling(() => getHistory(env.DB))();
    }

    const bookMatch = url.pathname.match(/^\/books\/([^/]+)$/);
    if (request.method === "GET" && bookMatch) {
      const bookId = decodeURIComponent(bookMatch[1]);
      return withErrorHandling(async () => {
        const result = await getBookDetails(env.DB, bookId);
        if (!result) {
          throw Object.assign(new Error("book not found"), { status: 404 });
        }
        return result;
      })();
    }

    return errorResponse("not found", 404);
  },
};

// Utility Functions
const cleanIsbn = (isbn) => isbn?.replace(/[-\s]/g, "") || null;

const generateBookId = (isbn, title, author) => {
  if (isbn) return isbn;
  const str = `${title || ""}:${author || ""}`.toLowerCase();
  const hash = [...str].reduce(
    (h, c) => ((h << 5) - h + c.charCodeAt(0)) | 0,
    0
  );
  return `book_${Math.abs(hash).toString(16)}`;
};

// Formatting Functions
const formatBook = (book, coverUrl) => ({
  id: book.id,
  title: book.title,
  author: book.author,
  cover_url: coverUrl,
  total_pages: book.total_pages,
  current_page: book.current_page,
  progress_percent: book.progress_percent,
  last_read_at: book.last_read_at,
});

const formatBookDetails = (book, coverUrl, stats, sessions, recentEvents) => ({
  id: book.id,
  title: book.title,
  author: book.author,
  cover_url: coverUrl,
  total_pages: book.total_pages,
  current_page: book.current_page,
  progress_percent: book.progress_percent,
  created_at: book.created_at,
  last_read_at: book.last_read_at,
  stats: {
    total_page_events: stats?.total_page_events || 0,
    first_read: stats?.first_read,
    last_read: stats?.last_read,
    total_sessions: sessions.length,
  },
  sessions,
  recent_events: recentEvents,
});

// External API
const fetchCoverUrl = async (isbn, title, author) => {
  try {
    if (isbn) {
      const coverUrl = `https://covers.openlibrary.org/b/isbn/${isbn}-L.jpg`;
      return coverUrl;
    }

    if (title) {
      const searchParams = new URLSearchParams({
        title: title,
        limit: "1",
      });
      if (author) {
        searchParams.set("author", author);
      }
      const searchUrl = `https://openlibrary.org/search.json?${searchParams}`;
      const response = await fetch(searchUrl);
      if (response.ok) {
        const data = await response.json();
        if (data.docs?.[0]?.cover_i) {
          return `https://covers.openlibrary.org/b/id/${data.docs[0].cover_i}-L.jpg`;
        }
      }
    }
  } catch (e) {
    console.error("Cover fetch error:", e);
  }
  return null;
};

// Database Operations
const handleUpdate = async (db, data) => {
  const { title, author, current_page, total_pages, progress, session_id, event_type } = data;

  if (!title) {
    throw new Error("title is required");
  }

  const isbn = cleanIsbn(data.isbn);
  const bookId = generateBookId(isbn, title, author);
  const now = new Date().toISOString();

  await db.prepare(`
    INSERT INTO books (id, isbn, title, author, total_pages, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO NOTHING
  `).bind(bookId, isbn || null, title, author || null, total_pages || null, now).run();

  await db.prepare(`
    INSERT INTO reading_status (book_id, current_page, progress_percent, last_read_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(book_id) DO UPDATE SET
      current_page = excluded.current_page,
      progress_percent = excluded.progress_percent,
      last_read_at = excluded.last_read_at
  `).bind(bookId, current_page || 0, progress || 0, now).run();

  if (event_type === "session_start") {
    await db.prepare(`
      INSERT OR IGNORE INTO sessions (id, book_id, started_at, start_page)
      VALUES (?, ?, ?, ?)
    `).bind(session_id, bookId, now, current_page || 0).run();
  } else if (event_type === "session_end") {
    const session = await db.prepare("SELECT start_page FROM sessions WHERE id = ?").bind(session_id).first();
    const pagesRead = Math.max(0, (current_page || 0) - (session?.start_page || 0));
    await db.prepare(`
      UPDATE sessions SET ended_at = ?, end_page = ?, pages_read = ?
      WHERE id = ?
    `).bind(now, current_page || 0, pagesRead, session_id).run();
  }

  if (session_id) {
    await db.prepare(`
      INSERT INTO page_events (book_id, page_number, progress_percent, session_id, timestamp)
      VALUES (?, ?, ?, ?, ?)
    `).bind(bookId, current_page || 0, progress || 0, session_id, now).run();
  }
};

const getCurrentReading = async (db) => {
  const result = await db.prepare(`
    SELECT
      b.id,
      b.isbn,
      b.title,
      b.author,
      b.total_pages,
      rs.current_page,
      rs.progress_percent,
      rs.last_read_at
    FROM reading_status rs
    JOIN books b ON b.id = rs.book_id
    ORDER BY rs.last_read_at DESC
    LIMIT 1
  `).first();

  if (!result) {
    return { error: "no book data yet" };
  }

  const coverUrl = await fetchCoverUrl(result.isbn, result.title, result.author);
  return formatBook(result, coverUrl);
};

const getHistory = async (db) => {
  const books = await db.prepare(`
    SELECT
      b.id,
      b.isbn,
      b.title,
      b.author,
      b.total_pages,
      rs.current_page,
      rs.progress_percent,
      rs.last_read_at
    FROM books b
    LEFT JOIN reading_status rs ON rs.book_id = b.id
    ORDER BY rs.last_read_at DESC NULLS LAST
  `).all();

  const booksWithCovers = await Promise.all(
    books.results.map(async (book) =>
      formatBook(book, await fetchCoverUrl(book.isbn, book.title, book.author))
    )
  );

  return { books: booksWithCovers };
};

const getBookDetails = async (db, bookId) => {
  const book = await db.prepare(`
    SELECT
      b.*,
      rs.current_page,
      rs.progress_percent,
      rs.last_read_at
    FROM books b
    LEFT JOIN reading_status rs ON rs.book_id = b.id
    WHERE b.id = ?
  `).bind(bookId).first();

  if (!book) {
    return null;
  }

  const sessions = await db.prepare(`
    SELECT * FROM sessions WHERE book_id = ? ORDER BY started_at DESC
  `).bind(bookId).all();

  const recentEvents = await db.prepare(`
    SELECT * FROM page_events WHERE book_id = ? ORDER BY timestamp DESC LIMIT 100
  `).bind(bookId).all();

  const stats = await db.prepare(`
    SELECT
      COUNT(*) as total_page_events,
      MIN(timestamp) as first_read,
      MAX(timestamp) as last_read
    FROM page_events WHERE book_id = ?
  `).bind(bookId).first();

  const coverUrl = await fetchCoverUrl(book.isbn, book.title, book.author);

  return formatBookDetails(book, coverUrl, stats, sessions.results, recentEvents.results);
};

const getActivity = async (db) => {
  const stats = await db.prepare(`
    SELECT
      COALESCE(SUM(pages_read), 0) as total_pages_read,
      COALESCE(SUM(
        CAST((julianday(ended_at) - julianday(started_at)) * 86400 AS INTEGER)
      ), 0) as total_time_seconds,
      COUNT(DISTINCT date(started_at)) as active_days
    FROM sessions
    WHERE ended_at IS NOT NULL
  `).first();

  const heatmap = await db.prepare(`
    SELECT
      date(started_at) as date,
      SUM(pages_read) as pages
    FROM sessions
    WHERE ended_at IS NOT NULL
      AND started_at >= date('now', '-365 days')
    GROUP BY date(started_at)
    ORDER BY date DESC
  `).all();

  const activeDays = stats.active_days || 1;

  const heatmapObj = {};
  for (const row of heatmap.results) {
    heatmapObj[row.date] = row.pages;
  }

  return {
    stats: {
      total_pages_read: stats.total_pages_read,
      total_time_seconds: stats.total_time_seconds,
      avg_pages_per_day: Math.round(stats.total_pages_read / activeDays),
      avg_time_per_day_seconds: Math.round(stats.total_time_seconds / activeDays),
    },
    heatmap: heatmapObj,
  };
};
