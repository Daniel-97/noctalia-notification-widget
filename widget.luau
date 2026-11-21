--!nonstrict
-- Missed Notifications widget — [[desktop_widget]] entry.
-- Renders the list published by the watcher service: a bell header with the
-- count, then one line per notification (app · summary, body optional).
-- Hidden when the list is empty. Click clears the list.

local state = noctalia.state.get("missed")
if type(state) ~= "table" then
  state = { locked = false, items = {}, count = 0 }
end

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

-- ------------------------------------------------------------------
-- Texts: resolved from the plugin's own translation files, so a language
-- override can be offered even though the shell follows the system
-- locale (LANG). "auto" probes the shell-resolved translation to pick
-- the matching file; "en"/"it" force a language.
-- ------------------------------------------------------------------
local transCache = {}

local function loadLangTable(lang)
  if transCache[lang] ~= nil then
    return transCache[lang]
  end
  local table_ = false
  local ok, raw = pcall(function()
    return noctalia.readFile(noctalia.pluginDir() .. "/translations/" .. lang .. ".json")
  end)
  if ok and type(raw) == "string" and raw ~= "" then
    local okDecode, decoded = pcall(function() return noctalia.json.decode(raw) end)
    if okDecode and type(decoded) == "table" then
      table_ = decoded
    end
  end
  transCache[lang] = table_
  return table_
end

local function lookup(t, key)
  if type(t) ~= "table" then
    return nil
  end
  local node = t
  for part in string.gmatch(key, "([^.]+)") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[part]
  end
  if type(node) == "string" then
    return node
  end
  return nil
end

local function resolveLang()
  local override = tostring(cfg("language", "auto"))
  if override == "en" or override == "it" then
    return override
  end
  -- auto: the shell resolves translations by system locale; probe a key
  -- whose values differ between the shipped languages.
  local ok, s = pcall(function() return noctalia.tr("widget.age_now") end)
  if ok and type(s) == "string" and s ~= "" and s ~= "widget.age_now" then
    if lookup(loadLangTable("it"), "widget.age_now") == s then
      return "it"
    end
    if lookup(loadLangTable("en"), "widget.age_now") == s then
      return "en"
    end
  end
  return "en"
end

local function T(key)
  return lookup(loadLangTable(resolveLang()), key)
end

local function trs(key, fallback)
  local s = T(key)
  if type(s) == "string" and s ~= "" then
    return s
  end
  return fallback
end

-- tr() with a %d substitution; falls back to a hardcoded template if the
-- translation is missing or cannot be formatted.
local function trf(key, count, fallback)
  local s = T(key)
  if type(s) == "string" and s:find("%%d") then
    local okFmt, out = pcall(function() return s:format(count) end)
    if okFmt then
      return out
    end
  end
  return fallback:format(count)
end

local function truncate(s, n)
  s = tostring(s or "")
  if #s <= n then
    return s
  end
  return string.sub(s, 1, n - 1) .. "…"
end

-- Text size: the plugin API exposes no way to read the widget box size
-- chosen in the editor, so the content cannot auto-fit an enlarged box.
-- Instead the plugin renders at explicit sizes controlled by this setting.
local scale = 1.3

local function refreshScale()
  local raw = tonumber(tostring(cfg("text_scale", "1.3"))) or 1.3
  scale = math.max(0.8, math.min(2.5, raw))
end

local function fs(base)
  return math.floor(base * scale + 0.5)
end

-- ------------------------------------------------------------------
-- App icon resolution: desktop-entry hint first, then the notification's
-- app_icon field, then the bare app name. Cached per (id, size).
-- ------------------------------------------------------------------
local iconCache = {}

local function iconPathFor(item, size)
  local candidates = {}
  if item.desktop and item.desktop ~= "" then
    table.insert(candidates, item.desktop)
  end
  if item.icon and item.icon ~= "" then
    table.insert(candidates, item.icon)
  end
  if item.app and item.app ~= "" then
    table.insert(candidates, item.app)
  end
  for _, id in ipairs(candidates) do
    -- Some apps put a direct file path or file:// URI in the icon field.
    local direct = id
    if direct:sub(1, 7) == "file://" then
      direct = direct:sub(8)
    end
    if direct:sub(1, 1) == "/" then
      if noctalia.fileExists(direct) then
        return direct
      end
    else
      local key = id .. ":" .. tostring(size)
      if iconCache[key] == nil then
        local ok, path = pcall(function() return noctalia.appIconPath(id, size) end)
        iconCache[key] = (ok and type(path) == "string" and path ~= "") and path or false
      end
      if iconCache[key] then
        return iconCache[key]
      end
    end
  end
  return nil
end

-- Relative age text for an entry ("just now", "1 minute ago", "2 hours ago"...).
local function formatAge(t)
  if type(t) ~= "number" or t <= 0 then
    return nil
  end
  local age = os.time() - t
  if age < 0 then
    age = 0
  end
  -- The whole first minute reads as "just now": this also avoids the
  -- "0 minutes ago" artifact from flooring before the first full minute.
  if age < 60 then
    return trs("widget.age_now", "just now")
  end
  local minutes = math.floor(age / 60)
  if minutes < 60 then
    if minutes == 1 then
      return trs("widget.age_min_one", "1 minute ago")
    end
    return trf("widget.age_min", minutes, "%d minutes ago")
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    if hours == 1 then
      return trs("widget.age_hour_one", "1 hour ago")
    end
    return trf("widget.age_hour", hours, "%d hours ago")
  end
  local days = math.floor(hours / 24)
  if days == 1 then
    return trs("widget.age_day_one", "1 day ago")
  end
  return trf("widget.age_day", days, "%d days ago")
end

-- ------------------------------------------------------------------
-- App display name: real apps often leave the notification's app_name
-- empty and only send the desktop-entry hint. Resolve the pretty name
-- from the .desktop file (localized per the widget language), falling
-- back to app_name and finally to the cleaned desktop id.
-- ------------------------------------------------------------------
local nameCache = {}

local function desktopFileCandidates(desktop)
  return {
    "/usr/share/applications/" .. desktop .. ".desktop",
    "/usr/local/share/applications/" .. desktop .. ".desktop",
  }
end

local function cleanDesktopId(desktop)
  -- "org.gnome.Nautilus" -> "Nautilus"
  return desktop:match("[^%.]+$") or desktop
end

local function displayName(item, lang)
  local desktop = item.desktop
  if type(desktop) == "string" and desktop ~= "" then
    local cacheKey = desktop .. ":" .. lang
    if nameCache[cacheKey] ~= nil then
      return nameCache[cacheKey]
    end
    local name = nil
    for _, path in ipairs(desktopFileCandidates(desktop)) do
      local ok, raw = pcall(function() return noctalia.readFile(path) end)
      if ok and type(raw) == "string" and raw ~= "" then
        local nameGeneric = nil
        local nameLocalized = nil
        for line in raw:gmatch("([^\r\n]+)") do
          -- Only the main [Desktop Entry] section: stop at the first
          -- section header (Desktop Actions carry their own Name=).
          if line:match("^%[") then
            break
          end
          if not nameGeneric and line:match("^Name=") then
            nameGeneric = line:match("^Name=(.*)$")
          end
          if not nameLocalized and line:match("^Name%[" .. lang .. "%]=") then
            nameLocalized = line:match("^Name%[" .. lang .. "%]=(.*)$")
          end
        end
        name = nameLocalized or nameGeneric
        break
      end
    end
    if name == nil then
      name = cleanDesktopId(desktop)
    end
    nameCache[cacheKey] = name
    return name
  end
  local app = tostring(item.app or "")
  if app ~= "" then
    return app
  end
  return nil
end

local function render()
  refreshScale()
  local items = type(state.items) == "table" and state.items or {}
  if #items == 0 then
    -- Empty state: keep the widget visible (dimmed) so its presence is
    -- clear even with nothing to show.
    desktopWidget.setVisible(true)
    desktopWidget.render(ui.row({ gap = fs(6), align = "center" }, {
      ui.glyph({ name = "bell", size = fs(15), color = "on_surface_variant" }),
      ui.label({ text = trs("widget.empty", "Nessuna notifica"), fontSize = fs(14), color = "on_surface_variant" }),
    }))
    return
  end

  local rawMax = tonumber(cfg("max_items", 6)) or 6
  local maxItems = math.max(1, math.min(20, rawMax))
  local showBody = cfg("show_body", false) == true
  local newestFirst = tostring(cfg("order", "newest")) ~= "oldest"
  local count = #items

  local header
  local listMode = tostring(cfg("list_mode", "unread"))
  if listMode == "all" then
    if count == 1 then
      header = trf("widget.header_all_one", 1, "1 recent notification")
    else
      header = trf("widget.header_all", count, "%d recent notifications")
    end
  elseif count == 1 then
    header = trf("widget.header_one", 1, "1 unread notification")
  else
    header = trf("widget.header", count, "%d unread notifications")
  end

  local children = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "bell", size = fs(15), color = "primary" }),
      ui.label({ text = header, fontSize = fs(14), fontWeight = "semibold", color = "on_surface" }),
    }),
  }

  -- Visible slice: newest first shows the tail of the list in reverse
  -- order, oldest first keeps the arrival order (previous behavior).
  local visible = {}
  if newestFirst then
    for i = count, math.max(1, count - maxItems + 1), -1 do
      table.insert(visible, items[i])
    end
  else
    for i = 1, math.min(count, maxItems) do
      table.insert(visible, items[i])
    end
  end

  for _, item in ipairs(visible) do
    local appName = displayName(item, resolveLang())
    local summary = truncate(item.summary, 64)
    local head
    if appName and appName ~= "" and summary ~= "" then
      head = appName .. " · " .. summary
    elseif summary ~= "" then
      head = summary
    else
      head = truncate(item.body, 64)
    end
    if head == "" then
      head = "?"
    end
    local headRow = ui.label({ text = head, fontSize = fs(12), color = "on_surface" })
    local age = formatAge(item.receivedAt)
    if age then
      headRow = ui.row({ gap = fs(5), align = "center" }, {
        headRow,
        ui.label({ text = age, fontSize = fs(10), color = "on_surface_variant" }),
      })
    end
    local lines = { headRow }
    if showBody and (item.body or "") ~= "" then
      table.insert(lines, ui.label({ text = truncate(item.body, 96), fontSize = fs(11), color = "on_surface_variant" }))
    end
    local lineChildren = {}
    local ok, ipath = pcall(iconPathFor, item, fs(16))
    if ok and ipath then
      table.insert(lineChildren, ui.image({ path = ipath, width = fs(16), height = fs(16), fit = "contain" }))
    else
      -- Unknown sender: generic glyph placeholder instead of no icon.
      table.insert(lineChildren, ui.glyph({ name = "notification", size = fs(16), color = "on_surface_variant" }))
    end
    table.insert(lineChildren, ui.column({ gap = 2 }, lines))
    table.insert(children, ui.row({ gap = fs(6), align = "center" }, lineChildren))
  end

  if count > maxItems then
    table.insert(children, ui.label({
      text = trf("widget.more", count - maxItems, "+ %d more"),
      fontSize = fs(11),
      color = "on_surface_variant",
    }))
  end

  desktopWidget.setVisible(true)
  desktopWidget.render(ui.column({ gap = fs(5) }, children))
end

pcall(function()
  noctalia.state.watch("missed", function(value)
    if type(value) == "table" then
      state = value
    else
      state = { locked = false, items = {}, count = 0 }
    end
    render()
  end)
end)

function update()
  -- Poll fallback in case state.watch is unavailable in this entry type.
  noctalia.setUpdateInterval(5000)
  local v = noctalia.state.get("missed")
  if type(v) == "table" then
    state = v
  end
  render()
end

function onClick()
  state = { locked = state.locked or false, items = {}, count = 0 }
  render()
  pcall(function()
    noctalia.state.set("control", { clear = true, at = os.time() })
  end)
end

render()
