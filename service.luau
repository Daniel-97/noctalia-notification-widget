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
--     signals with reason 3 remove the matching entry;
--   * the list is memory-only by design: notification content (bodies,
--     contact names) never touches the disk, so service restarts start
--     from an empty list. Privacy over continuity.
--
-- Noctalia v5 keeps its own notification history encrypted and offers no
-- public unread API, so this is an eavesdrop-based approximation: "received
-- since the list was last cleared" rather than the shell's exact unread
-- model. Dismissed toasts still count as unread in Noctalia too, which
-- keeps the two models close.

local MAX_STORED = 30

local items = {}

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
-- The list lives in memory only, by design: notification content
-- (bodies, contact names) never touches the disk. The price is that
-- service restarts — plugin reloads, settings changes, shell restarts
-- — start from an empty list, which is the privacy trade-off this
-- plugin deliberately makes.
-- ------------------------------------------------------------------

local function publish()
  noctalia.state.set("missed", {
    items = items,
    count = #items,
  })
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
-- Age-based pruning: entries older than the configured hours leave the
-- list on their own (0 keeps them forever). Runs on every service tick,
-- which is cheap — the list is capped at MAX_STORED anyway.
-- ------------------------------------------------------------------
local function pruneOldEntries()
  local hours = tonumber(cfg("max_age_hours", 24)) or 0
  if hours <= 0 then
    return
  end
  local cutoff = os.time() - hours * 3600
  local kept = {}
  local removed = 0
  for _, item in ipairs(items) do
    local t = tonumber(item.receivedAt)
    if type(t) == "number" and t < cutoff then
      removed = removed + 1
    else
      table.insert(kept, item)
    end
  end
  if removed > 0 then
    items = kept
    log("pruned " .. removed .. " expired notification(s)")
    publish()
  end
end

-- ------------------------------------------------------------------
-- Notification eavesdropping (dbus-monitor)
-- ------------------------------------------------------------------
-- Three kinds of captured messages matter:
--   * Notify method calls — app name, icon, summary, body, the call
--     serial, and the hints that follow the body (desktop-entry,
--     urgency, transient). The entry is only committed at the
--     message's last line (its expire timeout), when every field is
--     known — transient notifications are skipped there, honoring the
--     app's own "do not persist me" declaration:
--       method call ... serial=9 ...; member=Notify
--          string "app_name"  (first four string lines)
--   * the daemon's method returns — the assigned notification id,
--     correlated through the caller's unique name plus the call serial
--     (serials are unique only per connection, so the caller must be
--     part of the key — fresh clients and sandbox proxies reuse the
--     same small numbers):
--       method return ... -> destination=:1.99 ... reply_serial=9
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
local hintDesktop = nil
local hintUrgent = false
local hintTransient = false
local hintImagePath = nil
local pendingSerial = nil
local pendingSender = nil
local pendingReplyKey = nil

-- Caller unique name + call serial -> item awaiting the daemon-assigned
-- id (bounded FIFO). Serials are unique only per connection, so the key
-- pairs the serial with the caller's unique name: fresh clients
-- (notify-send, gdbus, busctl) and sandbox proxies all reuse the same
-- small serial numbers.
local pendingBySerial = {}
local serialQueue = {}

local function rememberSerial(serial, item)
  local key = (pendingSender or "") .. "/" .. tostring(serial)
  pendingBySerial[key] = item
  table.insert(serialQueue, key)
  while #serialQueue > 200 do
    local old = table.remove(serialQueue, 1)
    pendingBySerial[old] = nil
  end
end

local function unescapeDbus(s)
  return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

-- A withdrawn notification (reason 3) leaves the list. Apps replace a
-- live notification for follow-up messages (replaces_id reuses the same
-- id), so one id can carry several occurrences: closing it withdraws
-- them all — every id occurrence goes and the group count drops by as
-- many, removing the entry when nothing is left.
local function handleClosed(id, reason)
  if reason ~= 3 then
    return
  end
  for i, item in ipairs(items) do
    local ids = type(item.daemonIds) == "table" and item.daemonIds or nil
    if ids then
      local withdrawn = 0
      for j = #ids, 1, -1 do
        if ids[j] == id then
          table.remove(ids, j)
          withdrawn = withdrawn + 1
        end
      end
      if withdrawn > 0 then
        item.count = math.max(0, (tonumber(item.count) or 1) - withdrawn)
        if item.count <= 0 then
          table.remove(items, i)
        end
        log("notification " .. tostring(id) .. " withdrawn by its app (" .. withdrawn .. " occurrence(s))")
        publish()
        return
      end
    end
  end
end

-- Fields are applied inside onNotification so the state snapshot it
-- publishes is complete: setting the desktop hint after the internal
-- publish used to leave the widget's copy one publish behind (no app
-- name, no icon until some later event).
local function onNotification(app, icon, summary, body, desktop, urgent, image)
  if summary == "" and body == "" then
    return nil
  end
  -- Group with a previous entry with the same app and summary, wherever
  -- it sits in the list (a different notification in between must not
  -- split the group). The grouped entry keeps the latest body, counts
  -- the occurrences, and is renewed at the end of the list.
  if cfg("group_notifications", true) == true then
    for i = #items, 1, -1 do
      local item = items[i]
      if item.app == app and item.summary == summary then
        table.remove(items, i)
        item.body = body
        item.icon = icon
        item.receivedAt = os.time()
        item.count = (item.count or 1) + 1
        if desktop then
          item.desktop = desktop
        end
        if image then
          item.image = image
        end
        item.urgent = urgent
        table.insert(items, item)
        publish()
        return item
      end
    end
  end
  local item = {
    app = app,
    summary = summary,
    body = body,
    icon = icon,
    desktop = desktop,
    urgent = urgent,
    image = image,
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

-- The Notify message ends with its expire timeout (int32), after every
-- hint is known: the entry is committed once there — atomic, with the
-- desktop-entry, urgency and transient declarations already collected.
local function flushNotify()
  if msgKind ~= "notify" or #nStrings < 4 then
    return
  end
  msgKind = nil
  if hintTransient then
    log("transient notification skipped (" .. tostring(nStrings[3]) .. ")")
    return
  end
  local item = onNotification(
    nStrings[1] or "", nStrings[2] or "", nStrings[3] or "", nStrings[4] or "",
    hintDesktop, hintUrgent, hintImagePath)
  if item and pendingSerial then
    rememberSerial(pendingSerial, item)
  end
end

local function resetMsg()
  -- A new message started: commit the fully-collected notification
  -- first. This is the ONLY commit point: hint values and container
  -- shapes differ wildly between apps (Signal embeds avatars as
  -- image-data structs with their own int32 lines), so the message
  -- boundary is the one deterministic place where everything is known.
  flushNotify()
  msgKind = nil
  nStrings = {}
  closedValues = {}
  hintKey = nil
  hintDesktop = nil
  hintUrgent = false
  hintTransient = false
  hintImagePath = nil
end

-- Known hint keys we care about, in the hints dict after the body.
local function hintKeyFor(line)
  if line:find('^%s*string%s+"desktop%-entry"%s*$') then
    return "desktop-entry"
  end
  if line:find('^%s*string%s+"urgency"%s*$') then
    return "urgency"
  end
  if line:find('^%s*string%s+"transient"%s*$') then
    return "transient"
  end
  if line:find('^%s*string%s+"image%-path"%s*$') then
    return "image-path"
  end
  return nil
end

local function handleNotifyLine(line)
  -- Header classification (order matters: specific members first).
  if line:find("member=Notify", 1, true) then
    resetMsg()
    msgKind = "notify"
    pendingSerial = tonumber(line:match("serial=(%d+)"))
    pendingSender = line:match("sender=([^ ]+)") or ""
    return
  end
  if line:find("member=NotificationClosed", 1, true) then
    resetMsg()
    msgKind = "closed"
    return
  end
  if line:find("^method return") then
    local rs = tonumber(line:match("reply_serial=(%d+)"))
    local dest = line:match("destination=([^ ]+)") or ""
    resetMsg()
    -- Only returns answering a captured Notify call matter; the daemon
    -- also returns server-information and introspection noise. The
    -- return names the original caller as its destination, which pairs
    -- with the call's sender to key the pending map.
    local key = dest .. "/" .. tostring(rs)
    if rs and pendingBySerial[key] then
      msgKind = "return"
      pendingReplyKey = key
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
      local item = pendingBySerial[pendingReplyKey]
      pendingBySerial[pendingReplyKey] = nil
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

  -- Inside the hints dict: a known key is followed by its variant value.
  -- Keys can arrive in any order, so a new dict key re-runs the lookup.
  -- Values are only collected here; the entry is committed at the end
  -- of the message, with everything known.
  if hintKey ~= nil then
    if hintKey == "urgency" then
      local v = line:match("^%s*variant%s+byte%s+(%d+)%s*$")
      if v then
        -- Urgency byte: 0 low, 1 normal, 2 critical.
        hintUrgent = tonumber(v) == 2
        hintKey = nil
      end
    elseif hintKey == "transient" then
      -- The spec has transient as a boolean, but some toolkits send a
      -- bare 1 instead — accept both.
      local v = line:match("^%s*variant%s+boolean%s+true%s*$")
        or line:match("^%s*variant%s+byte%s+1%s*$")
        or line:match("^%s*variant%s+int32%s+1%s*$")
        or line:match("^%s*variant%s+uint32%s+1%s*$")
      if v then
        hintTransient = true
        hintKey = nil
      end
    elseif hintKey == "image-path" then
      local v = line:match('^%s*variant%s+string%s+"(.*)"%s*$')
      if v then
        -- Apps send a plain path or a file:// URI; the widget renders
        -- it as the leading image in place of the app icon.
        hintImagePath = (unescapeDbus(v):gsub("^file://", ""))
        hintKey = nil
      end
    else
      -- desktop-entry: a plain string id such as org.telegram.desktop.
      local v = line:match('^%s*variant%s+string%s+"(.*)"%s*$')
      if v then
        hintDesktop = unescapeDbus(v)
        hintKey = nil
      end
    end
    if hintKey ~= nil and line:match('^%s*string%s+"') then
      hintKey = hintKeyFor(line) -- a different dict key: not our value
    end
    return
  end
  -- Plain string fields: app name, icon, summary, body (first four only;
  -- action strings and dict keys later in the message must not be mixed in).
  if #nStrings < 4 then
    local s = line:match('^%s*string%s+"(.*)"%s*$')
    if s then
      table.insert(nStrings, unescapeDbus(s))
      return
    end
  end
  -- Hints come after the body: look for known dict keys.
  hintKey = hintKeyFor(line)
end

local function startNotifyWatch()
  if not noctalia.commandExists("dbus-monitor") then
    log("dbus-monitor not found on PATH")
    -- Once only: the watchdog retries every 30 s, and re-toasting the
    -- same missing dependency would spam the desktop forever.
    if not startNotifyWatch.errorNotified then
      startNotifyWatch.errorNotified = true
      noctalia.notifyError("Missed Notifications", noctalia.tr("notify.error"))
    end
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
  pruneOldEntries()
  centerOpenPoll()
  watchdogCheck()
end

pruneOldEntries()
publish()
startNotifyWatch()
