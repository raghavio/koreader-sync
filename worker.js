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

    if (request.method === "POST" && url.pathname === "/sync-stats") {
      return withAuth(async (req, env) => {
        try {
          const data = await req.json();
          await handleSyncStats(env.DB, data);
          return jsonResponse({ ok: true });
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

    return errorResponse("not found", 404);
  },
};

// External API
const fetchCoverUrl = async (title, authors) => {
  try {
    if (title) {
      const searchParams = new URLSearchParams({
        title: title,
        limit: "1",
      });
      if (authors) {
        searchParams.set("author", authors);
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
const handleSyncStats = async (db, data) => {
  const { book, page_stats, last_sync_time } = data;

  if (!book?.md5) {
    throw new Error("book.md5 is required");
  }

  if (!book?.title) {
    throw new Error("book.title is required");
  }

  // Check if book exists
  let existingBook = await db.prepare(
    "SELECT id, cover_url FROM book WHERE md5 = ?"
  ).bind(book.md5).first();

  let bookId;
  let coverUrl = existingBook?.cover_url;

  if (!existingBook) {
    // Fetch cover for new book
    coverUrl = await fetchCoverUrl(book.title, book.authors);

    // Insert new book
    const result = await db.prepare(`
      INSERT INTO book (title, authors, pages, md5, cover_url, last_open)
      VALUES (?, ?, ?, ?, ?, ?)
    `).bind(
      book.title,
      book.authors || null,
      book.pages || null,
      book.md5,
      coverUrl,
      Math.floor(Date.now() / 1000)
    ).run();

    bookId = result.meta.last_row_id;
  } else {
    bookId = existingBook.id;

    // Update last_open and pages if provided
    await db.prepare(`
      UPDATE book SET last_open = ?, pages = COALESCE(?, pages)
      WHERE id = ?
    `).bind(Math.floor(Date.now() / 1000), book.pages || null, bookId).run();
  }

  // Insert page_stat_data records
  if (page_stats && page_stats.length > 0) {
    const insertStmt = db.prepare(`
      INSERT OR IGNORE INTO page_stat_data (id_book, page, start_time, duration, total_pages)
      VALUES (?, ?, ?, ?, ?)
    `);

    const batch = page_stats.map(stat =>
      insertStmt.bind(
        bookId,
        stat.page,
        stat.start_time,
        stat.duration,
        stat.total_pages
      )
    );

    await db.batch(batch);

    // Update book totals
    const totals = await db.prepare(`
      SELECT
        COUNT(DISTINCT page) as total_read_pages,
        COALESCE(SUM(duration), 0) as total_read_time
      FROM page_stat_data
      WHERE id_book = ?
    `).bind(bookId).first();

    await db.prepare(`
      UPDATE book SET total_read_pages = ?, total_read_time = ?
      WHERE id = ?
    `).bind(totals.total_read_pages, totals.total_read_time, bookId).run();
  }

  // Update sync state
  const newSyncTime = page_stats?.length > 0
    ? Math.max(...page_stats.map(s => s.start_time))
    : last_sync_time || Math.floor(Date.now() / 1000);

  await db.prepare(`
    INSERT INTO sync_state (book_md5, last_sync_time)
    VALUES (?, ?)
    ON CONFLICT(book_md5) DO UPDATE SET last_sync_time = excluded.last_sync_time
  `).bind(book.md5, newSyncTime).run();
};

const getCurrentReading = async (db) => {
  const result = await db.prepare(`
    SELECT
      b.id,
      b.title,
      b.authors,
      b.cover_url,
      b.pages as total_pages,
      b.total_read_time,
      b.total_read_pages,
      p.page as current_page,
      ROUND(p.page * 100.0 / NULLIF(p.total_pages, 0), 1) as progress_percent,
      strftime('%Y-%m-%dT%H:%M:%SZ', p.start_time, 'unixepoch') as last_read_at
    FROM page_stat_data p
    JOIN book b ON b.id = p.id_book
    ORDER BY p.start_time DESC
    LIMIT 1
  `).first();

  if (!result) {
    return { error: "no book data yet" };
  }

  return {
    id: result.id,
    title: result.title,
    authors: result.authors,
    cover_url: result.cover_url,
    total_pages: result.total_pages,
    current_page: result.current_page,
    progress_percent: result.progress_percent,
    total_read_time: result.total_read_time,
    total_read_pages: result.total_read_pages,
    last_read_at: result.last_read_at,
  };
};

const getHistory = async (db) => {
  const books = await db.prepare(`
    SELECT
      b.id,
      b.title,
      b.authors,
      b.cover_url,
      b.pages as total_pages,
      b.total_read_time,
      b.total_read_pages,
      latest.page as current_page,
      ROUND(latest.page * 100.0 / NULLIF(latest.total_pages, 0), 1) as progress_percent,
      strftime('%Y-%m-%dT%H:%M:%SZ', latest.start_time, 'unixepoch') as last_read_at
    FROM book b
    JOIN (
      SELECT id_book, page, total_pages, start_time,
        ROW_NUMBER() OVER (PARTITION BY id_book ORDER BY start_time DESC) as rn
      FROM page_stat_data
    ) latest ON latest.id_book = b.id AND latest.rn = 1
    ORDER BY latest.start_time DESC
  `).all();

  return {
    books: books.results.map(book => ({
      id: book.id,
      title: book.title,
      authors: book.authors,
      cover_url: book.cover_url,
      total_pages: book.total_pages,
      current_page: book.current_page,
      progress_percent: book.progress_percent,
      total_read_time: book.total_read_time,
      total_read_pages: book.total_read_pages,
      last_read_at: book.last_read_at,
    })),
  };
};

const getActivity = async (db) => {
  const stats = await db.prepare(`
    SELECT
      COUNT(DISTINCT id_book || '-' || page) as total_pages_read,
      COALESCE(SUM(duration), 0) as total_time_seconds
    FROM page_stat_data
  `).first();

  const heatmap = await db.prepare(`
    SELECT
      date(start_time, 'unixepoch') as date,
      COUNT(DISTINCT id_book || '-' || page) as pages,
      SUM(duration) as duration
    FROM page_stat_data
    WHERE start_time >= unixepoch('now', '-365 days')
    GROUP BY date(start_time, 'unixepoch')
    ORDER BY date DESC
  `).all();

  // Count distinct active days
  const activeDays = heatmap.results.length || 1;

  const heatmapObj = {};
  for (const row of heatmap.results) {
    heatmapObj[row.date] = {
      pages: row.pages,
      duration: row.duration,
    };
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
