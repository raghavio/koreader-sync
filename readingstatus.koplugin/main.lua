--[[
Reading Status Sync Plugin for KOReader
Syncs your current reading status to a Cloudflare Worker API
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("rapidjson")
local logger = require("logger")
local UIManager = require("ui/uimanager")

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

local UPDATE_ENDPOINT = config.update_endpoint
local AUTH_TOKEN = config.auth_token

if not UPDATE_ENDPOINT or not AUTH_TOKEN then
    logger.warn("ReadingStatus: Please configure update_endpoint and auth_token in config.lua")
    return { disabled = true }
end

local ReadingStatus = WidgetContainer:extend{
    name = "readingstatus",
    is_doc_only = true,
}

-- Throttle syncs to avoid spamming the API
local last_sync_time = 0
local SYNC_INTERVAL = 60  -- seconds between syncs

-- Session tracking
local current_session_id = nil
local max_page_reached = 0

-- Generate a simple UUID-like session ID. Taken from https://gist.github.com/jrus/3197011
local function generateSessionId()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

function ReadingStatus:init()
    math.randomseed(os.time())
    logger.dbg("ReadingStatus: plugin initialized, endpoint:", UPDATE_ENDPOINT)
end

-- Called when reader is ready (book opened)
function ReadingStatus:onReaderReady()
    -- Start a new reading session
    current_session_id = generateSessionId()
    max_page_reached = 0
    self:syncStatus(true, "session_start")
end

-- Called when closing the document
function ReadingStatus:onCloseDocument()
    self:syncStatus(true, "session_end")
    current_session_id = nil
end

-- Called on page turns (throttled, forward movement only)
function ReadingStatus:onPageUpdate(pageno)
    -- Only sync when reaching a new highest page in this session.
    -- Going back to re-read earlier pages doesn't count as progress,
    -- and we'll sync again once the reader moves past their previous max.
    if pageno and pageno > max_page_reached then
        max_page_reached = pageno
        self:syncStatus(false, "page_turn")
    end
end

function ReadingStatus:syncStatus(force, event_type)
    local now = os.time()

    -- Throttle unless forced
    if not force and (now - last_sync_time) < SYNC_INTERVAL then
        return
    end
    last_sync_time = now

    -- Get document properties
    local props = self.ui.doc_props or {}
    local percent = 0
    local current_page = 0
    local total_pages = 0

    if self.ui.doc_settings then
        percent = self.ui.doc_settings:readSetting("percent_finished") or 0
    end

    -- Get page info from the document
    if self.ui.document then
        current_page = self.ui.document:getCurrentPage() or 0
        total_pages = self.ui.document:getPageCount() or 0
    end

    local payload = json.encode({
        title = props.title or "Unknown",
        author = props.authors or "Unknown",
        isbn = props.isbn or nil,
        current_page = current_page,
        total_pages = total_pages,
        progress = math.floor(percent * 100),
        session_id = current_session_id,
        event_type = event_type or "page_turn",
    })

    -- Send async to avoid blocking UI
    UIManager:scheduleIn(0.1, function()
        local response = {}
        local result, status = http.request{
            url = UPDATE_ENDPOINT,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#payload),
                ["Authorization"] = "Bearer " .. AUTH_TOKEN,
            },
            source = ltn12.source.string(payload),
            sink = ltn12.sink.table(response),
        }

        if result and status == 200 then
            logger.dbg("ReadingStatus: synced", props.title, "page:", current_page, "event:", event_type)
        else
            logger.warn("ReadingStatus: sync failed", "status:", status, "response:", table.concat(response))
        end
    end)
end

return ReadingStatus
