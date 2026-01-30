# KOReader Stats Tracker

Sync your KOReader reading progress to a Cloudflare Worker API with D1 database backend. Track all your books, sessions, and page turn events. I built this to be able to sync my reading stats to my personal website.

## How it works

1. KOReader plugin sends reading events when you turn pages or open/close books
2. Cloudflare Worker stores events in D1 database with full history
3. Query the API anytime - access current status, full history, and session details

## Features

- **Offline support** - Events are queued locally when offline and automatically synced when back online
- **Forward-only tracking** - Only syncs page turns when moving forward through the book, ignoring re-reads of earlier pages
- **Session tracking** - Each reading session gets a unique ID to track when you started and stopped reading
- **Bulk event upload** - Queued events are sent in a single request for efficiency
- **Cover images** - Book covers fetched from OpenLibrary

## API Endpoints

### GET /books/current
Returns the currently reading book (most recently updated)

```bash
curl https://koreader.{account-id}.workers.dev/books/current
```

**Response:**
```json
{
  "id": "9780136083238",
  "title": "The Pragmatic Programmer",
  "author": "David Thomas, Andrew Hunt",
  "cover_url": "https://covers.openlibrary.org/b/isbn/9780136083238-M.jpg",
  "total_pages": 352,
  "current_page": 148,
  "progress_percent": 42,
  "last_read_at": "2024-01-25T10:30:00.000Z"
}
```

### GET /books
Returns all books with aggregated stats

```bash
curl https://koreader.{account-id}.workers.dev/books
```

### GET /books/:bookId
Returns detailed stats for a specific book including sessions and recent page events

```bash
curl https://koreader.{account-id}.workers.dev/books/9780136083238
```

### POST /events
Sync reading events

```bash
curl -X POST https://koreader.{account-id}.workers.dev/events \
  -H "Authorization: Bearer YOUR_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "The Pragmatic Programmer",
    "author": "David Thomas, Andrew Hunt",
    "isbn": "978-0-13-595705-9",
    "current_page": 148,
    "total_pages": 352,
    "progress": 42,
    "session_id": "uuid-here",
    "event_type": "page_turn"
  }'
```

## Setup

### 1. Create D1 Database

```bash
wrangler d1 create reading-tracker
```

Copy the `database_id` from the output.

### 2. Initialize Database Schema

```bash
wrangler d1 execute reading-tracker --file schema.sql
```

### 3. Deploy Cloudflare Worker

**Option A: GitHub Actions (recommended)**

1. Add to your GitHub repo (Settings → Secrets and variables → Actions):
   - Secret: `CLOUDFLARE_API_TOKEN` - Your Cloudflare API token (with Workers and D1 permissions)
   - Variable: `CLOUDFLARE_D1_DATABASE_ID` - The D1 database ID from step 1
2. Push to main or trigger the workflow manually
3. Set the AUTH_TOKEN secret (one-time, persists across deploys):
   ```bash
   wrangler secret put AUTH_TOKEN
   ```

**Option B: Manual deploy**

1. Update `wrangler.toml` with your database ID from step 1.

2. Deploy:
   ```bash
   wrangler login
   wrangler deploy
   ```

3. Set the AUTH_TOKEN secret:
   ```bash
   wrangler secret put AUTH_TOKEN
   ```

Your worker will be available at: `https://koreader.{account-id}.workers.dev`

### 4. Install KOReader Plugin

Copy the plugin to your Kindle:
```bash
cp -r readingstatus.koplugin /media/*/Kindle/koreader/plugins/
```

Create `readingstatus.koplugin/config.lua` with your configuration:
```lua
return {
    update_endpoint = "https://koreader.{account-id}.workers.dev/events",
    auth_token = "YOUR_AUTH_TOKEN",  -- Must match AUTH_TOKEN secret
}
```

### 5. Restart KOReader

Open a book and your reading status will sync automatically.

## Debugging

To enable debug logging in KOReader:

1. Go to **Top menu → 🛠️ (tools icon) → More tools → Developer options → Enable debug logging**
2. Restart KOReader and open a book
3. Check the log file at `/koreader/crash.log` on your Kindle

Look for lines containing `ReadingStatus:` to see sync status and any errors.

## Environment Variables

| Variable | Where to set | Description |
|----------|--------------|-------------|
| `CLOUDFLARE_API_TOKEN` | GitHub secret | Cloudflare API token with Workers and D1 permissions |
| `CLOUDFLARE_D1_DATABASE_ID` | GitHub variable | D1 database ID (injected at deploy time) |

### Creating Cloudflare API Token

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Create Token → Use template "Edit Cloudflare Workers"
3. Add permissions for D1 if needed
4. Add the token as `CLOUDFLARE_API_TOKEN` in GitHub repo secrets
