# KOReader Stats Tracker

Sync your KOReader reading stats to a Cloudflare Worker API with D1 database backend. Track all your books and page turn events. I built this to be able to sync my reading stats to my personal website.

This plugin is pretty much a fork of the existing KOReader plugin, except it sends the data to an API endpoint and supports an extra trigger event (onDeviceSuspend).

See [Migrating Existing Data](#migrating-existing-data) to sync your existing data from KOReader to this service.

## How it works

1. Plugin tracks per-page reading time
2. Syncs to Cloudflare Worker every 5 page turns, on book close, and on power off
3. Worker stores data in D1 and provides API for querying stats

## Features

- **Accurate reading time** - Tracks per-page duration (>5 and <90 seconds per page, matching KOReader's original plugin logic)
- **Page-level granularity** - Every page read is tracked with timestamp and duration
- **Suspend sync** - Syncs when you close the cover or device sleeps (the most common way to stop reading)
- **Cover images** - Book covers fetched from OpenLibrary
- **Reading heatmap** - API for daily reading activity with pages and duration

## API Endpoints

### GET /books/current
Returns the currently reading book (most recently updated)

```bash
curl https://koreader.{account-id}.workers.dev/books/current
```

**Response:**
```json
{
  "id": 1,
  "title": "The Pragmatic Programmer",
  "authors": "David Thomas, Andrew Hunt",
  "cover_url": "https://covers.openlibrary.org/b/id/12345-L.jpg",
  "total_pages": 352,
  "current_page": 148,
  "progress_percent": 42.0,
  "total_read_time": 18000,
  "total_read_pages": 148,
  "last_read_at": "2024-01-25T10:30:00"
}
```

### GET /books
Returns all books sorted by last read

```bash
curl https://koreader.{account-id}.workers.dev/books
```

**Response:**
```json
{
  "books": [
    {
      "id": 1,
      "title": "The Pragmatic Programmer",
      "authors": "David Thomas, Andrew Hunt",
      "cover_url": "https://covers.openlibrary.org/b/id/12345-L.jpg",
      "total_pages": 352,
      "current_page": 148,
      "progress_percent": 42.0,
      "total_read_time": 18000,
      "total_read_pages": 148,
      "last_read_at": "2024-01-25T10:30:00"
    }
  ]
}
```

### GET /activity
Returns reading activity stats and a heatmap of pages read per day (last 365 days)

```bash
curl https://koreader.{account-id}.workers.dev/activity
```

**Response:**
```json
{
  "stats": {
    "total_pages_read": 2450,
    "total_time_seconds": 180000,
    "avg_pages_per_day": 35,
    "avg_time_per_day_seconds": 2571
  },
  "heatmap": {
    "2024-01-25": { "pages": 42, "duration": 3600 },
    "2024-01-24": { "pages": 38, "duration": 3200 }
  }
}
```

### POST /sync-stats
Sync reading stats from KOReader (requires auth)

```bash
curl -X POST https://koreader.{account-id}.workers.dev/sync-stats \
  -H "Authorization: Bearer YOUR_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "book": {
      "title": "The Pragmatic Programmer",
      "authors": "David Thomas, Andrew Hunt",
      "pages": 352,
      "md5": "abc123..."
    },
    "page_stats": [
      { "page": 145, "start_time": 1706200000, "duration": 45, "total_pages": 352 }
    ],
    "last_sync_time": 1706100000
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

1. Add to your GitHub repo (Settings > Secrets and variables > Actions):
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
    sync_endpoint = "https://koreader.{account-id}.workers.dev/sync-stats",
    auth_token = "YOUR_AUTH_TOKEN",  -- Must match AUTH_TOKEN secret
}
```

### 5. Restart KOReader

Open a book and your reading stats will sync automatically.

## Plugin Details

### How Tracking Works

The plugin tracks reading time in-memory (no local database):

1. **Page timing**: When you turn to a new page, the plugin records how long you spent on the previous page
2. **Duration filtering**: Only page reads between 5-90 seconds are recorded (same logic as KOReader's original statistics plugin)
3. **Batched sync**: Stats are sent to the API every 5 page turns

### When Does Sync Happen?

| Event | Trigger |
|-------|---------|
| Every 5 page turns | `onPageUpdate` - frequent updates while reading |
| Book closed | `onCloseDocument` - sync remaining pages |
| Device suspend | `onSuspend` - cover closed, sleep button, or auto-sleep |

### Offline Behavior

When offline, sync is skipped and pending stats are kept in memory. They'll be synced on the next trigger when online. Note: if the device crashes or battery dies before syncing, unsent page stats are lost. With 5-page sync intervals, this is anyway minimal data loss.

## Debugging

To enable debug logging in KOReader:

1. Go to **Top menu > Tools > More tools > Developer options > Enable debug logging**
2. Restart KOReader and open a book
3. Check the log file at `/koreader/crash.log` on your Kindle

Look for lines containing `ReadingStatus:` to see sync status and any errors.

## Migrating Existing Data

If you have existing reading stats in KOReader's built-in statistics database, you can migrate them to D1.

### Prerequisites
- `sqlite3`, `curl`, `jq` installed on your computer
- Copy `statistics.sqlite3` from your Kindle: `/koreader/settings/statistics.sqlite3`
- `readingstatus.koplugin/config.lua` configured with your endpoint and token

### Run Migration

```bash
./migrate.sh /path/to/statistics.sqlite3
```

The script reads your API endpoint and token from `readingstatus.koplugin/config.lua` and migrates all books with their page-level reading history.

The migration is idempotent (safe to run multiple times) - duplicate page stats are ignored.

## Environment Variables

| Variable | Where to set | Description |
|----------|--------------|-------------|
| `CLOUDFLARE_API_TOKEN` | GitHub secret | Cloudflare API token with Workers and D1 permissions |
| `CLOUDFLARE_D1_DATABASE_ID` | GitHub variable | D1 database ID (injected at deploy time) |

### Creating Cloudflare API Token

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Create Token > Use template "Edit Cloudflare Workers"
3. Add permissions for D1 if needed
4. Add the token as `CLOUDFLARE_API_TOKEN` in GitHub repo secrets
