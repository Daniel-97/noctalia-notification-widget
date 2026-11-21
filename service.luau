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
--     widget is clicked (control channel).
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
-- A captured Notify message looks like:
--   method call time=... sender=:1.42 -> destination=:1.7 serial=9 path=/...; interface=org.freedesktop.Notifications; member=Notify
--      string "app_name"
--      uint32 0
--      string "icon"
--      string "Summary"
--      string "Body"
--      array [...]
--      array [...]
--      int32 5000
-- We only need the first four string lines (app, icon, summary, body).

local inNotify = false
local nStrings = {}
local hintKey = nil
local current = nil

local function unescapeDbus(s)
  return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

local function onNotification(app, icon, summary, body)
  if summary == "" and body == "" then
    return nil
  end
  local last = items[#items]
  if last and last.app == app and last.summary == summary then
    -- Same app and summary as the last entry: treat as an update of the
    -- same notification (chat apps resending) instead of a new one.
    last.body = body
    last.icon = icon
    last.receivedAt = os.time()
    publish()
    return last
  end
  local item = {
    app = app,
    summary = summary,
    body = body,
    icon = icon,
    desktop = nil,
    receivedAt = os.time(),
  }
  table.insert(items, item)
  while #items > MAX_STORED do
    table.remove(items, 1)
  end
  publish()
  return item
end

local function handleNotifyLine(line)
  if line:find("member=Notify", 1, true) then
    inNotify = true
    nStrings = {}
    hintKey = nil
    current = nil
    return
  end
  if not inNotify then
    return
  end
  -- A new message started: the captured one was already recorded at its
  -- body string, so there is nothing left to do for it.
  if line:find("^method call") or line:find("^method return") or line:find("^signal") or line:find("^error") then
    inNotify = false
    hintKey = nil
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
    'dbus-monitor --session --monitor "type=\'method_call\',interface=\'org.freedesktop.Notifications\',member=\'Notify\'"',
    function(line)
      handleNotifyLine(line)
    end
  )
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
end

restoreStore()
publish()
startNotifyWatch()
