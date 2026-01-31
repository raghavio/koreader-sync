#!/bin/bash
# migrate.sh - Migrate KOReader statistics.sqlite3 to D1 via /sync-stats API
#
# Usage: ./migrate.sh /path/to/statistics.sqlite3
#
# Prerequisites: sqlite3, curl, jq

set -e

DB_PATH="${1:?Usage: ./migrate.sh /path/to/statistics.sqlite3}"

if [ ! -f "$DB_PATH" ]; then
    echo "Error: Database file not found: $DB_PATH"
    exit 1
fi

# Check required tools
for cmd in sqlite3 curl jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed"
        exit 1
    fi
done

# Find config file (relative to script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/readingstatus.koplugin/config.lua"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "Create readingstatus.koplugin/config.lua with sync_endpoint and auth_token"
    exit 1
fi

# Parse config.lua for endpoint and token
# Handles both sync_endpoint and update_endpoint (legacy)
ENDPOINT=$(grep -E 'sync_endpoint|update_endpoint' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
TOKEN=$(grep 'auth_token' "$CONFIG_FILE" | sed 's/.*"\([^"]*\)".*/\1/')

# Normalize endpoint to /sync-stats
ENDPOINT=$(echo "$ENDPOINT" | sed 's|/events$|/sync-stats|; s|/sync_stats$|/sync-stats|')
if [[ ! "$ENDPOINT" =~ /sync-stats$ ]]; then
    ENDPOINT="${ENDPOINT%/}/sync-stats"
fi

if [ -z "$ENDPOINT" ] || [ -z "$TOKEN" ]; then
    echo "Error: Could not parse sync_endpoint or auth_token from config.lua"
    exit 1
fi

echo "Migrating from: $DB_PATH"
echo "To endpoint: $ENDPOINT"
echo ""

# Get all books with page stats (excluding books without real authors)
# Note: pages comes from the latest page_stat_data.total_pages, not book.notes
BOOKS=$(sqlite3 -json "$DB_PATH" "
    SELECT b.id, b.title, b.authors, b.md5,
           (SELECT total_pages FROM page_stat_data WHERE id_book = b.id ORDER BY start_time DESC LIMIT 1) as pages
    FROM book b
    WHERE b.md5 IS NOT NULL
      AND b.authors IS NOT NULL
      AND b.authors != ''
      AND b.authors != 'N/A'
      AND EXISTS (SELECT 1 FROM page_stat_data p WHERE p.id_book = b.id)
")

if [ -z "$BOOKS" ] || [ "$BOOKS" = "[]" ]; then
    echo "No books with page stats found in database"
    exit 0
fi

TOTAL=$(echo "$BOOKS" | jq length)
echo "Found $TOTAL books to migrate"
echo ""

SUCCESS=0
FAILED=0

echo "$BOOKS" | jq -c '.[]' | while read -r book; do
    BOOK_ID=$(echo "$book" | jq -r '.id')
    MD5=$(echo "$book" | jq -r '.md5')
    TITLE=$(echo "$book" | jq -r '.title')

    # Get page stats for this book
    PAGE_STATS=$(sqlite3 -json "$DB_PATH" "
        SELECT page, start_time, duration, total_pages
        FROM page_stat_data
        WHERE id_book = $BOOK_ID
        ORDER BY start_time
    ")

    STAT_COUNT=$(echo "$PAGE_STATS" | jq length)

    # Build payload
    PAYLOAD=$(jq -n \
        --argjson book "$book" \
        --argjson stats "$PAGE_STATS" \
        '{
            book: {
                md5: $book.md5,
                title: $book.title,
                authors: $book.authors,
                pages: ($book.pages | tonumber? // null)
            },
            page_stats: $stats
        }')

    echo -n "Migrating: $TITLE ($STAT_COUNT page events)... "

    RESPONSE=$(curl -s -X POST "$ENDPOINT" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    if echo "$RESPONSE" | jq -e '.ok' > /dev/null 2>&1; then
        echo "OK"
    else
        ERROR=$(echo "$RESPONSE" | jq -r '.error // "unknown error"')
        echo "FAILED: $ERROR"
    fi
done

echo ""
echo "Migration complete!"
