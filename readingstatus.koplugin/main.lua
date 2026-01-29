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
local NetworkMgr = require("ui/network/manager")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")

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

-- Offline queue settings
local MAX_QUEUE_SIZE = 100  -- Prevent storage bloat
local QUEUE_FILE_NAME = "readingstatus_queue.json"
local offline_notification_shown = false

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

-- Queue persistence functions
local function getQueueFilePath()
    return DataStorage:getSettingsDir() .. "/" .. QUEUE_FILE_NAME
end

local function loadQueue()
    local path = getQueueFilePath()
    local file = io.open(path, "r")
    if not file then
        return { events = {}, offline_notification_shown = false }
    end
    local content = file:read("*all")
    file:close()
    local ok, data = pcall(json.decode, content)
    if ok and data then
        return {
            events = data.events or {},
            offline_notification_shown = data.offline_notification_shown or false
        }
    end
    return { events = {}, offline_notification_shown = false }
end

local function saveQueue(data)
    local path = getQueueFilePath()
    local file = io.open(path, "w")
    if file then
        file:write(json.encode(data))
        file:close()
    else
        logger.warn("ReadingStatus: failed to save queue to", path)
    end
end

local function enqueueEvent(payload)
    local queue = loadQueue()
    table.insert(queue.events, payload)
    -- Drop oldest events if queue is full
    while #queue.events > MAX_QUEUE_SIZE do
        table.remove(queue.events, 1)
        logger.dbg("ReadingStatus: dropped oldest event from queue (max size reached)")
    end
    saveQueue(queue)
    logger.dbg("ReadingStatus: queued event, queue size:", #queue.events)
end

local function showOfflineNotificationOnce()
    if offline_notification_shown then
        return
    end
    offline_notification_shown = true
    -- Persist the notification state
    local queue = loadQueue()
    queue.offline_notification_shown = true
    saveQueue(queue)
    -- Show the notification
    UIManager:show(InfoMessage:new{
        text = "Reading progress will sync when back online.",
        timeout = 3,
    })
end

local function resetOfflineNotificationState()
    if not offline_notification_shown then
        return
    end
    offline_notification_shown = false
    local queue = loadQueue()
    queue.offline_notification_shown = false
    saveQueue(queue)
end

local function sendEventsToServer(payloads)
    local body = "[" .. table.concat(payloads, ",") .. "]"
    local response = {}
    local result, status = http.request{
        url = UPDATE_ENDPOINT,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Authorization"] = "Bearer " .. AUTH_TOKEN,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    if result and status == 200 then
        local ok, data = pcall(json.decode, table.concat(response))
        if ok and data then
            return true, data.succeeded or 0, data.failed or 0
        end
        return true, 1, 0
    end
    return false, 0, 0, status, table.concat(response)
end

local function flushQueue()
    local queue = loadQueue()
    if #queue.events == 0 then
        return true
    end

    logger.dbg("ReadingStatus: flushing queue, events:", #queue.events)

    local success, succeeded, failed, status, response = sendEventsToServer(queue.events)
    if success then
        resetOfflineNotificationState()
        if failed == 0 then
            queue.events = {}
            saveQueue(queue)
            logger.dbg("ReadingStatus: queue flushed successfully, sent:", succeeded)
            return true
        else
            -- Some events failed - we don't know which, so clear anyway to avoid duplicates
            queue.events = {}
            saveQueue(queue)
            logger.warn("ReadingStatus: queue flushed with errors, succeeded:", succeeded, "failed:", failed)
            return true
        end
    else
        logger.warn("ReadingStatus: queue flush failed, status:", status, "response:", response)
        return false
    end
end

local function attemptSync(payload, is_critical)
    -- Check network status
    if not NetworkMgr:isOnline() then
        showOfflineNotificationOnce()
        enqueueEvent(payload)
        return
    end

    -- Add current event to queue and flush all at once
    enqueueEvent(payload)
    local success = flushQueue()

    if success then
        logger.dbg("ReadingStatus: synced successfully")
    else
        showOfflineNotificationOnce()

        -- For critical events, register callback to retry when online
        if is_critical then
            NetworkMgr:willRerunWhenOnline(function()
                flushQueue()
            end)
        end
    end
end

function ReadingStatus:init()
    math.randomseed(os.time())
    logger.dbg("ReadingStatus: plugin initialized, endpoint:", UPDATE_ENDPOINT)

    -- Load persisted queue state
    local queue = loadQueue()
    offline_notification_shown = queue.offline_notification_shown or false

    -- Try flushing queue on startup if online (with delay to let system settle)
    if #queue.events > 0 then
        logger.dbg("ReadingStatus: found", #queue.events, "queued events")
        UIManager:scheduleIn(5, function()
            if NetworkMgr:isOnline() then
                flushQueue()
            end
        end)
    end
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

    local is_critical = (event_type == "session_start" or event_type == "session_end")

    -- Send async to avoid blocking UI
    UIManager:scheduleIn(0.1, function()
        attemptSync(payload, is_critical)
    end)
end

return ReadingStatus
