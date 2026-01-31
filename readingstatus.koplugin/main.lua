--[[
Reading Status Sync Plugin for KOReader
Tracks page reading and syncs to a Cloudflare Worker API
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("rapidjson")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local util = require("util")

-- Load config from config.lua
local config_loaded, config = pcall(function()
    local plugin_path = debug.getinfo(1, "S").source:match("@(.*/)")
    package.path = plugin_path .. "?.lua;" .. package.path
    return dofile(plugin_path .. "config.lua")
end)

if not config_loaded or not config then
    logger.warn("ReadingStatus: config.lua not found. Copy config.lua.example to config.lua and configure it.")
    return { disabled = true }
end

local SYNC_ENDPOINT = config.update_endpoint
local AUTH_TOKEN = config.auth_token

if not SYNC_ENDPOINT or not AUTH_TOKEN then
    logger.warn("ReadingStatus: Please configure update_endpoint and auth_token in config.lua")
    return { disabled = true }
end

local ReadingStatus = WidgetContainer:extend{
    name = "readingstatus",
    is_doc_only = true,
}

-- Sync configuration
local SYNC_EVERY_N_PAGES = 5

-- In-memory page stats (pending sync)
local pending_stats = {}      -- array of {page, start_time, duration, total_pages}
local page_turn_count = 0     -- count since last sync

-- Current page tracking (to calculate duration)
local current_page_start = nil  -- timestamp when current page was opened
local current_page = nil        -- current page number
local current_book = nil        -- {title, authors, pages, md5}

-- Record a page stat entry to pending queue
local function recordPageStat(page, duration)
    if duration > 0 and current_book then
        table.insert(pending_stats, {
            page = page,
            start_time = os.time() - duration,
            duration = duration,
            total_pages = current_book.pages or 0,
        })
        logger.dbg("ReadingStatus: recorded page", page, "duration", duration)
    end
end

-- Finalize current page's duration before moving on
local function flushCurrentPage()
    if current_page and current_page_start then
        local duration = os.time() - current_page_start
        -- Only record if within reasonable bounds (5-90 seconds like KOReader)
        if duration >= 5 and duration <= 90 then
            recordPageStat(current_page, duration)
        end
        current_page_start = nil
    end
end

-- Send sync data to server
local function sendSyncToServer(data)
    local body = json.encode(data)
    local response = {}
    local _, status = http.request{
        url = SYNC_ENDPOINT,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Authorization"] = "Bearer " .. AUTH_TOKEN,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    return status == 200
end

-- Sync pending stats to API
local function syncToServer(force)
    if #pending_stats == 0 and not force then
        return true
    end
    if not NetworkMgr:isOnline() then
        logger.dbg("ReadingStatus: offline, skipping sync")
        return false, "offline"
    end
    if not current_book then
        return false
    end

    logger.dbg("ReadingStatus: syncing", #pending_stats, "page stats for:", current_book.title)

    local payload = {
        book = current_book,
        page_stats = pending_stats,
    }

    if sendSyncToServer(payload) then
        logger.dbg("ReadingStatus: sync successful")
        pending_stats = {}  -- clear on success
        page_turn_count = 0
        return true
    end
    logger.warn("ReadingStatus: sync failed for:", current_book.title)
    return false
end

function ReadingStatus:init()
    logger.dbg("ReadingStatus: plugin initialized, endpoint:", SYNC_ENDPOINT)
end

-- Called when reader is ready (book opened)
function ReadingStatus:onReaderReady()
    local props = self.ui.doc_props or {}
    if not props.title then
        logger.dbg("ReadingStatus: no title, skipping")
        return
    end

    -- Generate md5 from document file (same as KOReader's statistics plugin)
    local md5 = util.partialMD5(self.ui.document.file)

    current_book = {
        title = props.title,
        authors = props.authors,
        pages = self.ui.document:getPageCount(),
        md5 = md5,
    }
    current_page = self.ui.document:getCurrentPage()
    current_page_start = os.time()
    page_turn_count = 0
    pending_stats = {}

    logger.dbg("ReadingStatus: opened book:", current_book.title, "page:", current_page)
end

-- Called on page turns
function ReadingStatus:onPageUpdate(pageno)
    if not current_book then return end

    -- Flush previous page's duration
    flushCurrentPage()

    -- Start tracking new page
    current_page = pageno
    current_page_start = os.time()
    page_turn_count = page_turn_count + 1

    -- Sync every N pages
    if page_turn_count >= SYNC_EVERY_N_PAGES then
        UIManager:scheduleIn(0.5, function()
            syncToServer(false)
        end)
    end
end

-- Called when closing the document
function ReadingStatus:onCloseDocument()
    flushCurrentPage()
    syncToServer(true)  -- force sync remaining
    current_book = nil
    current_page = nil
    current_page_start = nil
    pending_stats = {}
    page_turn_count = 0
    logger.dbg("ReadingStatus: closed document, synced remaining stats")
end

-- Called when device is about to suspend (cover closed, sleep button, auto-sleep)
function ReadingStatus:onSuspend()
    if not current_book then return end
    flushCurrentPage()
    syncToServer(true)  -- sync before sleep
    -- Reset page start time since we'll resume from suspend
    if current_page then
        current_page_start = os.time()
    end
    logger.dbg("ReadingStatus: suspended, synced stats")
end

return ReadingStatus
