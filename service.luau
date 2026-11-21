--!nonstrict
-- Missed Notifications watcher — headless [[service]] entry.
--
-- Keeps a plugin-side list of "unread" notifications:
--   * eavesdrops every org.freedesktop.Notifications.Notify call with
--     dbus-monitor, so app name, summary and body are captured no matter
--     the session state (locked or not);
--   * consecutive notifications with the same app and summary update the
--     last entry instead of piling up (chat apps resending);
--   * the list is cleared when the control center is opened (the "unread"
--     list mode only; the "all" mode keeps a rolling recap) or when the
--     widget is clicked (control channel);
--   * notifications withdrawn by their sending app (read in the app
--     itself) leave the list: the daemon's assigned ids are correlated
--     through the captured method returns, and NotificationClosed
--     signals with reason 3 remove the matching entry.
--
-- Noctalia v5 keeps its own notification history encrypted and offers no
-- public unread API, so this is an eavesdrop-based approximation: "received
-- since the list was last cleared" rather than the shell's exact unread
-- model. Dismissed toasts still count as unread in Noctalia too, which
-- keeps the two models close.

local MAX_STORED = 30

local items = {}
local storePath = nil

local function log(msg)
  noctalia.log("[missed-notifications] " .. msg)
end

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

-- ------------------------------------------------------------------
-- Persistence: the list lives in the plugin data dir so it survives
-- service restarts (plugin reloads, settings changes, shell restarts).
-- ------------------------------------------------------------------
local function saveStore()
  if not storePath then
    return
  end
  local ok, raw = pcall(function() return noctalia.json.encode({ items = items }) end)
  if ok and type(raw) == "string" then
    pcall(function() noctalia.writeFile(storePath, raw) end)
  end
end

local function restoreStore()
  local ok, dir = pcall(function() return noctalia.pluginDataDir() end)
  if not ok or type(dir) ~= "string" or dir == "" then
    log("no plugin data dir: list not persisted")
    return
  end
  pcall(function() noctalia.mkdirAll(dir) end)
  storePath = dir .. "/items.json"

  local okRead, raw = pcall(function() return noctalia.readFile(storePath) end)
  if not okRead or type(raw) ~= "string" or raw == "" then
    return
  end
  local okDecode, saved = pcall(function() return noctalia.json.decode(raw) end)
  if not okDecode or type(saved) ~= "table" or type(saved.items) ~= "table" then
    return
  end
  local restored = {}
  for _, item in ipairs(saved.items) do
    if type(item) == "table" then
      table.insert(restored, {
        app = tostring(item.app or ""),
        summary = tostring(item.summary or ""),
        body = tostring(item.body or ""),
        icon = item.icon ~= nil and tostring(item.icon) or "",
        desktop = item.desktop ~= nil and tostring(item.desktop) or nil,
        receivedAt = type(item.receivedAt) == "number" and item.receivedAt or nil,
        count = type(item.count) == "number" and item.count or 1,
      })
    end
  end
  while #restored > MAX_STORED do
    table.remove(restored, 1)
  end
  items = restored
  log("restored " .. #items .. " stored notification(s)")
end

local function publish()
  noctalia.state.set("missed", {
    items = items,
    count = #items,
  })
  saveStore()
end

local function clearList(reason)
  if #items == 0 then
    return
  end
  items = {}
  log("list cleared (" .. reason .. ")")
  publish()
end

-- ------------------------------------------------------------------
-- Notification eavesdropping (dbus-monitor)
-- ------------------------------------------------------------------
-- Three kinds of captured messages matter:
--   * Notify method calls — app name, icon, summary, body, the call
--     serial, and the desktop-entry hint after the body:
--       method call ... serial=9 ...; member=Notify
--          string "app_name"  (first four string lines)
--   * the daemon's method returns — the assigned notification id,
--     correlated through reply_serial -> the call's serial:
--       method return ... reply_serial=9
--          uint32 410
--   * NotificationClosed signals — reason 3 means the sending app
--     withdrew the notification (read in the app itself), so the entry
--     leaves the list. Other reasons (expired, user-dismissed) keep the
--     entry, matching Noctalia's own unread model:
--       signal ...; member=NotificationClosed
--          uint32 410
--          uint32 3

local msgKind = nil -- "notify" | "return" | "closed"
local nStrings = {}
local closedValues = {}
local hintKey = nil
local current = nil
local pendingSerial = nil
local pendingReplySerial = nil

-- Call serial -> item awaiting the daemon-assigned id (bounded FIFO).
local pendingBySerial = {}
local serialQueue = {}

local function rememberSerial(serial, item)
  pendingBySerial[serial] = item
  table.insert(serialQueue, serial)
  while #serialQueue > 200 do
    local old = table.remove(serialQueue, 1)
    pendingBySerial[old] = nil
  end
end

local function unescapeDbus(s)
  return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

-- A withdrawn notification (reason 3) leaves the list; a grouped entry
-- loses one occurrence instead.
local function handleClosed(id, reason)
  if reason ~= 3 then
    return
  end
  for i, item in ipairs(items) do
    local ids = type(item.daemonIds) == "table" and item.daemonIds or nil
    if ids then
      for j, did in ipairs(ids) do
        if did == id then
          table.remove(ids, j)
          if (item.count or 1) > 1 then
            item.count = item.count - 1
          else
            table.remove(items, i)
          end
          log("notification " .. tostring(id) .. " withdrawn by its app")
          publish()
          return
        end
      end
    end
  end
end

local function onNotification(app, icon, summary, body)
  if summary == "" and body == "" then
    return nil
  end
  -- Group with a previous entry with the same app and summary, wherever
  -- it sits in the list (a different notification in between must not
  -- split the group). The grouped entry keeps the latest body, counts
  -- the occurrences, and is renewed at the end of the list.
  for i = #items, 1, -1 do
    local item = items[i]
    if item.app == app and item.summary == summary then
      table.remove(items, i)
      item.body = body
      item.icon = icon
      item.receivedAt = os.time()
      item.count = (item.count or 1) + 1
      table.insert(items, item)
      publish()
      return item
    end
  end
  local item = {
    app = app,
    summary = summary,
    body = body,
    icon = icon,
    desktop = nil,
    receivedAt = os.time(),
    count = 1,
  }
  table.insert(items, item)
  while #items > MAX_STORED do
    table.remove(items, 1)
  end
  publish()
  return item
end

local function resetMsg()
  msgKind = nil
  nStrings = {}
  closedValues = {}
  hintKey = nil
end

local function handleNotifyLine(line)
  -- Header classification (order matters: specific members first).
  if line:find("member=Notify", 1, true) then
    resetMsg()
    msgKind = "notify"
    pendingSerial = tonumber(line:match("serial=(%d+)"))
    current = nil
    return
  end
  if line:find("member=NotificationClosed", 1, true) then
    resetMsg()
    msgKind = "closed"
    return
  end
  if line:find("^method return") then
    local rs = tonumber(line:match("reply_serial=(%d+)"))
    resetMsg()
    -- Only returns answering a captured Notify call matter; the daemon
    -- also returns server-information and introspection noise.
    if rs and pendingBySerial[rs] then
      msgKind = "return"
      pendingReplySerial = rs
    end
    return
  end
  if line:find("^method call") or line:find("^signal") or line:find("^error") then
    resetMsg()
    return
  end

  -- Body lines, per message kind.
  if msgKind == "return" then
    local v = line:match("^%s*uint32%s+(%d+)%s*$")
    if v then
      local item = pendingBySerial[pendingReplySerial]
      pendingBySerial[pendingReplySerial] = nil
      msgKind = nil
      if item then
        item.daemonIds = item.daemonIds or {}
        table.insert(item.daemonIds, tonumber(v))
      end
    end
    return
  end
  if msgKind == "closed" then
    local v = line:match("^%s*uint32%s+(%d+)%s*$")
    if v then
      table.insert(closedValues, tonumber(v))
      if #closedValues == 2 then
        msgKind = nil
        handleClosed(closedValues[1], closedValues[2])
      end
    end
    return
  end
  if msgKind ~= "notify" then
    return
  end

  -- Inside the hints dict: the "desktop-entry" key is followed by a
  -- variant string with the value (e.g. "org.telegram.desktop").
  if hintKey == "desktop-entry" then
    local v = line:match('^%s*variant%s+string%s+"(.*)"%s*$')
    if v then
      hintKey = nil
      if current then
        current.desktop = unescapeDbus(v)
        publish()
      end
    elseif line:match('^%s*string%s+"') then
      hintKey = nil -- a different dict key: not our value
    end
    return
  end
  -- Plain string fields: app name, icon, summary, body (first four only;
  -- action strings and dict keys later in the message must not be mixed in).
  if #nStrings < 4 then
    local s = line:match('^%s*string%s+"(.*)"%s*$')
    if s then
      table.insert(nStrings, unescapeDbus(s))
      if #nStrings == 4 then
        current = onNotification(nStrings[1] or "", nStrings[2] or "", nStrings[3] or "", nStrings[4] or "")
        if current and pendingSerial then
          rememberSerial(pendingSerial, current)
        end
      end
      return
    end
  end
  -- Hints come after the body: look for the desktop-entry dict key.
  if line:find('^%s*string%s+"desktop%-entry"%s*$') then
    hintKey = "desktop-entry"
  end
end

local function startNotifyWatch()
  if not noctalia.commandExists("dbus-monitor") then
    log("dbus-monitor not found on PATH")
    noctalia.notifyError("Missed Notifications", noctalia.tr("notify.error"))
    return
  end
  noctalia.runStream(
    'dbus-monitor --session --monitor "type=\'method_call\',interface=\'org.freedesktop.Notifications\',member=\'Notify\'" "type=\'method_return\',sender=\'org.freedesktop.Notifications\'" "type=\'signal\',interface=\'org.freedesktop.Notifications\',member=\'NotificationClosed\'"',
    function(line)
      handleNotifyLine(line)
    end
  )
end

-- ------------------------------------------------------------------
-- Watchdog: if the dbus-monitor process dies silently, respawn it.
-- Checked from update() at most once every 30 s. The pgrep pattern uses
-- a character class ("Notif[y]") so the checking shell itself — whose
-- command line contains the pattern literal — never matches.
-- ------------------------------------------------------------------
local lastWatchdogCheck = 0

local function watchdogCheck()
  local now = os.time()
  if now - lastWatchdogCheck < 30 then
    return
  end
  lastWatchdogCheck = now
  if not noctalia.commandExists("pgrep") then
    return
  end
  noctalia.runAsync(
    'pgrep -f "dbus-monitor.*Notif[y]" > /dev/null 2>&1',
    function(result)
      if result.exitCode ~= 0 then
        log("notification watcher not running: respawning dbus-monitor")
        startNotifyWatch()
      end
    end)
end

-- ------------------------------------------------------------------
-- "Viewed" detection: the control center opening is the closest
-- externally observable event to Noctalia's own "notifications tab
-- opened" read marker. The tab itself is not distinguishable over IPC.
-- Only the "unread" list mode clears on it: "all" mode keeps a rolling
-- recap of the last notifications regardless of the read marker.
-- ------------------------------------------------------------------
local function centerOpenPoll()
  if cfg("list_mode", "unread") ~= "unread" then
    return
  end
  noctalia.runAsync(
    "noctalia msg status",
    function(result)
      if result.exitCode == 0 and type(result.stdout) == "string"
        and result.stdout:find('"activePanelId"%s*:%s*"control%-center"') then
        clearList("control center opened")
      end
    end)
end

-- ------------------------------------------------------------------
-- Control channel (click-to-clear from the widget)
-- ------------------------------------------------------------------
pcall(function()
  noctalia.state.watch("control", function(value)
    if type(value) == "table" and value.clear then
      clearList("widget click")
    end
  end)
end)

function update()
  noctalia.setUpdateInterval(2000)
  centerOpenPoll()
  watchdogCheck()
end

restoreStore()
publish()
startNotifyWatch()
