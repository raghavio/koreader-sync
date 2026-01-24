# KOReader Stats Tracker

Sync your KOReader reading progress to a Cloudflare Worker API with D1 database backend. Track all your books, sessions, and page turn events. I built this to be able to sync my reading stats to my personal website.

## How it works

1. KOReader plugin sends reading events when you turn pages or open/close books
2. Cloudflare Worker stores events in D1 database with full history
3. Query the API anytime - access current status, full history, and session details

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

1. Fork this repo
2. Add these secrets to your GitHub repo (Settings → Secrets → Actions):
   - `CLOUDFLARE_API_TOKEN` - Your Cloudflare API token (with Workers and D1 permissions)
   - `CLOUDFLARE_D1_DATABASE_ID` - The D1 database ID from step 1
   - `AUTH_TOKEN` - A secret token for protecting the `/events` endpoint
3. Push to main or trigger the workflow manually

**Option B: Manual deploy**

1. Update `wrangler.toml` with your database ID from step 1.

2. Set the `AUTH_TOKEN` environment variable:
   ```bash
   export AUTH_TOKEN="your-secret-token-here"
   ```

3. Deploy:
   ```bash
   wrangler login
   wrangler deploy
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

Open a book and your reading status will sync automatically. Check the plugin logs for sync status.

## Environment Variables

Set in GitHub Actions secrets or `wrangler.toml`:

| Variable | Description |
|----------|-------------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with Workers and D1 permissions |
| `CLOUDFLARE_D1_DATABASE_ID` | D1 database ID (injected at deploy time) |
| `AUTH_TOKEN` | Secret token for protecting `/events` endpoint |

### Creating Cloudflare API Token

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Create Token → Use template "Edit Cloudflare Workers"
3. Add permissions for D1 if needed
4. Add the token as `CLOUDFLARE_API_TOKEN` in GitHub repo secrets
