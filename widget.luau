--!nonstrict
-- Missed Notifications widget — [[desktop_widget]] entry.
-- Renders the list published by the watcher service: a bell header with the
-- count, then one line per notification (app · summary, body optional).
-- The empty state stays visible and says "No notifications"; the widget has
-- no click handler.
--
-- Keep the root height dynamic. Noctalia's lockscreen repaints a widget
-- fully only when its size changes: a fixed height (fixed editor box or
-- reserved placeholder slots) makes new notifications repaint just their
-- own region while the screen stays locked, leaving older cards blank
-- until the next unlock. Do not reserve a fixed height here.

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

-- Preview is a positioning aid: it shows whenever the list is empty and
-- the setting is enabled. No auto-dismiss; turn the setting off when done.
local previewOn = cfg("preview_when_empty", false) == true

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
-- translation is missing or cannot be formatted. Singular keys are plain
-- strings without %d: they are returned as-is.
local function trf(key, count, fallback)
  local s = T(key)
  if type(s) == "string" and s ~= "" then
    if not s:find("%%d") then
      return s
    end
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

-- Invented sample entries for positioning the widget in the lockscreen
-- editor. The editor shows an empty widget until real notifications
-- arrive, so this is opt-in (preview_when_empty) and the header is marked
-- as a preview. The count follows max_items so the reserved space matches
-- the configured number of real notifications. Names and messages are
-- deliberately fictional.
local previewTemplates = {
  { app = "Signal", summary = "John Doe", body = "Are we still on for tonight?", desktop = "org.signal.Signal" },
  { app = "Signal", summary = "Jane Roe", body = "Thanks for the update!", desktop = "org.signal.Signal", count = 2 },
  { app = "Thunderbird", summary = "This is a deliberately very long preview title that keeps going far beyond the card width so you can see exactly where the box clips it", body = "3 new messages in your inbox", desktop = "net.thunderbird.Thunderbird" },
  { app = "Steam", summary = "Wishlist sale", body = "A game on your wishlist is 40% off", desktop = "com.valvesoftware.Steam", urgent = true },
  { app = "Signal", summary = "Alex Smith", body = "Sent the photos!", desktop = "org.signal.Signal" },
  { app = "Thunderbird", summary = "Calendar reminder", body = "Stand-up in 15 minutes", desktop = "net.thunderbird.Thunderbird" },
}

local function previewItems(n)
  local now = os.time()
  local result = {}
  for i = 1, n do
    local t = previewTemplates[(i - 1) % #previewTemplates + 1]
    result[i] = {
      app = t.app,
      summary = t.summary,
      body = t.body,
      desktop = t.desktop,
      receivedAt = now - (n - i + 1) * 300,
      count = t.count or 1,
      urgent = t.urgent or false,
    }
  end
  -- The newest sample (displayed first with the default order) explains
  -- itself, so the first card a user sees is the guide.
  result[n] = {
    app = trs("widget.preview_app", "Missed Notifications"),
    summary = trs("widget.preview_title", "Test notification"),
    body = trs("widget.preview_body",
      "Sample cards for positioning. Turn off \"Preview sample notifications\" in the plugin settings."),
    icon = "bell",
    receivedAt = now - 60,
    count = 1,
  }
  return result
end

-- The plugin API cannot read the box size chosen in the editor, so the
-- content renders at fixed metrics; Noctalia owns the widget box and its
-- scale. The card width is whatever the user sets on the box.
local scale = 1.3

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

-- App-provided image (image-path hint): a file path the widget renders
-- as the leading image in place of the app icon. No readFile
-- validation: large files would be read into memory for nothing, and
-- the image renderer handles missing/broken paths gracefully.
local function providedImagePath(item)
  local p = item.image
  if type(p) ~= "string" or p == "" then
    return nil
  end
  return p
end

-- Relative age text for an entry ("just now", "1 minute ago", "2 hours ago"...).
local function formatAgeRelative(t)
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

-- Age text per the age_format setting: relative ("2 hours ago"),
-- absolute ("18:42"), or both joined by a middle dot. os.date may be
-- unavailable in the plugin sandbox: fall back to the relative text
-- rather than breaking the render.
local function formatAge(t)
  if type(t) ~= "number" or t <= 0 then
    return nil
  end
  local mode = tostring(cfg("age_format", "relative"))
  if mode == "relative" then
    return formatAgeRelative(t)
  end
  local ok, abs = pcall(os.date, "%H:%M", t)
  if not ok or type(abs) ~= "string" then
    return formatAgeRelative(t)
  end
  if mode == "absolute" then
    return abs
  end
  return (formatAgeRelative(t) or "") .. " · " .. abs
end

-- ------------------------------------------------------------------
-- App display name: real apps often leave the notification's app_name
-- empty and only send the desktop-entry hint. Resolve the pretty name
-- from the .desktop file (localized per the widget language), falling
-- back to app_name and finally to the cleaned desktop id.
-- ------------------------------------------------------------------
local nameCache = {}

local function desktopFileCandidates(desktop)
  local c = {
    "/usr/share/applications/" .. desktop .. ".desktop",
    "/usr/local/share/applications/" .. desktop .. ".desktop",
    -- Flatpak exports: sandboxed apps install their .desktop files
    -- here, outside the usual application dirs.
    "/var/lib/flatpak/exports/share/applications/" .. desktop .. ".desktop",
  }
  local okHome, home = pcall(function() return os.getenv("HOME") end)
  if okHome and type(home) == "string" and home ~= "" then
    table.insert(c, home .. "/.local/share/flatpak/exports/share/applications/" .. desktop .. ".desktop")
  end
  return c
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
        local inMain = false
        for line in raw:gmatch("([^\r\n]+)") do
          if line:match("^%[") then
            if inMain then
              -- A section after the main one (Desktop Actions carry
              -- their own Name=): the main section is over.
              break
            end
            inMain = line:match("^%[Desktop Entry%]") ~= nil
          elseif inMain then
            if not nameGeneric and line:match("^Name=") then
              nameGeneric = line:match("^Name=(.*)$")
            end
            if not nameLocalized and line:match("^Name%[" .. lang .. "%]=") then
              nameLocalized = line:match("^Name%[" .. lang .. "%]=(.*)$")
            end
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
  local items = type(state.items) == "table" and state.items or {}
  local count = #items
  local rawMax = tonumber(cfg("max_items", 6)) or 6
  local maxItems = math.max(1, math.min(20, rawMax))

  local previewActive = false
  if count == 0 and previewOn then
    items = previewItems(maxItems)
    count = #items
    previewActive = true
  end

  -- Title length also fixes the widget width: a fixed width stops the
  -- center-anchored widget from growing sideways with long titles, while
  -- the height stays dynamic for the lockscreen repaint.
  local lengthMode = tostring(cfg("summary_length", "normal"))
  local summaryLimit = 60
  local widthBase = 340
  if lengthMode == "short" then
    summaryLimit = 40
    widthBase = 280
  elseif lengthMode == "long" then
    summaryLimit = 90
    widthBase = 400
  end
  local cardWidth = fs(widthBase)

  if count == 0 then
    -- Empty state: keep the widget visible (dimmed) so its presence is
    -- clear even with nothing to show.
    desktopWidget.setVisible(true)
    desktopWidget.render(ui.column({ width = cardWidth }, {
      ui.row({ gap = fs(6), align = "center" }, {
        ui.glyph({ name = "bell", size = fs(15), color = "on_surface_variant" }),
        ui.label({ text = trs("widget.empty", "No notifications"), fontSize = fs(14), color = "on_surface_variant" }),
      }),
    }))
    return
  end

  local showBody = cfg("show_body", false) == true
  local newestFirst = tostring(cfg("order", "newest")) ~= "oldest"
  local showIcons = cfg("show_icons", true) == true
  local showAge = cfg("show_age", true) == true
  local cardBg = tostring(cfg("card_background", "subtle"))

  local header
  if count == 1 then
    header = trf("widget.header_one", 1, "1 unread notification")
  else
    header = trf("widget.header", count, "%d unread notifications")
  end

  if previewActive then
    header = trs("widget.preview", "Preview") .. " · " .. header
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
    -- Truncation keeps the head line within the title-length setting.
    local summary = truncate(item.summary, summaryLimit)
    -- Head parts: the app name renders bold, the summary stays regular,
    -- and the separator dot stands on its own label so the row gap
    -- spaces it evenly from both sides.
    local headParts = {}
    if appName and appName ~= "" and summary ~= "" then
      table.insert(headParts, ui.label({
        text = appName,
        fontSize = fs(12),
        fontWeight = "bold",
        color = "on_surface",
        maxLines = 1,
        maxWidth = math.floor(cardWidth * 0.38),
      }))
      table.insert(headParts, ui.label({ text = " · ", fontSize = fs(12), color = "on_surface" }))
      table.insert(headParts, ui.label({ text = summary, fontSize = fs(12), color = "on_surface", maxLines = 1, flexGrow = 1 }))
    elseif summary ~= "" then
      table.insert(headParts, ui.label({ text = summary, fontSize = fs(12), color = "on_surface", maxLines = 1, flexGrow = 1 }))
    elseif (item.body or "") ~= "" then
      table.insert(headParts, ui.label({ text = truncate(item.body, summaryLimit), fontSize = fs(12), color = "on_surface", maxLines = 1, flexGrow = 1 }))
    else
      table.insert(headParts, ui.label({ text = "?", fontSize = fs(12), color = "on_surface", maxLines = 1, flexGrow = 1 }))
    end
    -- Critical notifications (urgency hint == 2) carry a small accent
    -- dot right after the title.
    if item.urgent == true then
      table.insert(headParts, ui.label({ text = "●", fontSize = fs(9), color = "error" }))
    end
    -- One head line holds icon, title, badge and age together (centered
    -- against each other, so the icon stays in line with the title); a
    -- growing spacer pins the age to the card's right edge. The body
    -- hangs below, indented past the icon.
    local headChildren = {}
    if showIcons then
      -- Optical alignment: a centered text label's glyph center sits a
      -- touch lower than its box center, so a box-centered icon rides
      -- slightly high; a hairline spacer on top nudges it down to match.
      local iconElement
      local provided = providedImagePath(item)
      if provided then
        -- The app shipped its own image: show it instead of the app icon.
        iconElement = ui.image({ path = provided, width = fs(16), height = fs(16), fit = "contain" })
      else
        local ok, ipath = pcall(iconPathFor, item, fs(16))
        if ok and ipath then
          iconElement = ui.image({ path = ipath, width = fs(16), height = fs(16), fit = "contain" })
        else
          -- Unknown sender: generic glyph placeholder instead of no icon.
          iconElement = ui.glyph({ name = "notification", size = fs(16), color = "on_surface_variant" })
        end
      end
      table.insert(headChildren, ui.column({ gap = 0 }, {
        ui.spacer({ height = fs(3) }),
        iconElement,
      }))
    end
    for _, part in ipairs(headParts) do
      table.insert(headChildren, part)
    end
    local groupCount = tonumber(item.count) or 1
    if groupCount > 1 then
      table.insert(headChildren, ui.label({
        text = trf("widget.count", groupCount, "(%d)"),
        fontSize = fs(10),
        color = "on_surface_variant",
        maxLines = 1,
      }))
    end
    if showAge then
      local age = formatAge(item.receivedAt)
      if age then
        table.insert(headChildren, ui.label({ text = age, fontSize = fs(10), color = "on_surface_variant", maxLines = 1 }))
      end
    end

    local hasBody = showBody and (item.body or "") ~= ""
    local cardChildren = { ui.row({ gap = fs(5), align = "center" }, headChildren) }
    if hasBody then
      table.insert(cardChildren, ui.column({ paddingH = showIcons and fs(21) or fs(4) }, {
        ui.label({
          text = item.body,
          fontSize = fs(11),
          color = "on_surface_variant",
          maxWidth = math.max(fs(140), cardWidth - fs(60)),
          maxLines = 2,
        }),
      }))
    end

    -- Each notification is a rounded card over the lock backdrop. The
    -- fill tints with the on-surface color (near-white in dark mode,
    -- near-black in light mode) so the card keeps contrast on any
    -- background, black wallpapers included; a hairline outline marks
    -- the edge. Body-less cards breathe more instead of collapsing
    -- into a thin strip: symmetric padding both sides of the head line
    -- acts as a minimum height while keeping the content optically
    -- centered (a raw minHeight would leave the line sitting at the
    -- top of the taller box, since columns align children from there).
    -- A minimum width keeps short titles from shrinking the card below
    -- the body-driven measure, so the stack stays uniform.
    local cardFill = "on_surface/0.08"
    local cardBorder = "outline_variant/0.12"
    local cardBorderWidth = 1
    local cardRadius = fs(8)
    if cardBg == "none" then
      cardFill = "on_surface/0"
      cardBorder = "outline_variant/0"
      cardBorderWidth = 0
    elseif cardBg == "solid" then
      cardFill = "surface_container"
      cardBorder = "outline_variant/0.25"
    elseif cardBg == "glass" then
      -- "Liquid glass": translucent frosted fill, brighter rim and softer
      -- corners. The host has no backdrop blur for plugin trees, so this
      -- is a translucency approximation.
      cardFill = "surface_container/0.45"
      cardBorder = "on_surface/0.22"
      cardRadius = fs(14)
    end
    table.insert(children, ui.column({
      gap = fs(2),
      paddingH = fs(10),
      paddingV = hasBody and fs(7) or fs(13),
      width = cardWidth,
      radius = cardRadius,
      fill = cardFill,
      border = cardBorder,
      borderWidth = cardBorderWidth,
    }, cardChildren))
  end

  if count > maxItems then
    table.insert(children, ui.label({
      text = trf("widget.more", count - maxItems, "+ %d more"),
      fontSize = fs(11),
      color = "on_surface_variant",
    }))
  end

  desktopWidget.setVisible(true)
  desktopWidget.render(ui.column({ gap = fs(8), width = cardWidth }, children))
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

render()
