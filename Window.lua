local _, ns = ...
local S = ns.Skin

-- Settings window: a Settings tab and one tab per pair of node lists.
-- Every change is saved the moment you click it.
local frame

-- Scrollable list of node names, each with a tick, its icon and how many
-- spots are saved for it.
local ROWS, ROW_HEIGHT = 15, 24

local function NodeList(parent, category, width)
  local box = S.Box(parent)
  box:SetSize(width, ROWS * ROW_HEIGHT + 10)
  box.offset = 0
  box.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
    row:SetSize(22, 22)
    row:SetPoint("TOPLEFT", 6, -5 - (i - 1) * ROW_HEIGHT)
    if i % 2 == 0 then
      local stripe = box:CreateTexture(nil, "BACKGROUND", nil, 1)
      stripe:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_HEIGHT)
      stripe:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", -4, -4 - i * ROW_HEIGHT)
      stripe:SetColorTexture(1, 1, 1, 0.03)
    end
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", row, "RIGHT", 2, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.text = S.Label(row, "")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.count = S.Help(row, "")
    row.count:SetPoint("RIGHT", box, "RIGHT", -10, 0)
    row.count:SetPoint("TOP", row, "TOP", 0, -6)
    row:SetHitRectInsets(0, -(width - 40), 0, 0) -- the whole line is clickable
    row:SetScript("OnClick", function(self)
      local on = self:GetChecked() and true or false
      S.Sound(on and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
      ns.SetNameShown(self.name, on)
    end)
    box.rows[i] = row
  end
  box.position = S.Help(box, "")
  box.position:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", -2, -3)

  function box:Refresh(counts)
    local names = ns.NamesFor(category)
    local maxOffset = math.max(0, #names - ROWS)
    self.offset = math.min(math.max(self.offset, 0), maxOffset)
    for i, row in ipairs(self.rows) do
      local name = names[self.offset + i]
      row.name = name
      if name then
        row:SetChecked(ns.IsShownName(name))
        row.icon:SetTexture(ns.Icon(name))
        -- Skill it needs, coloured against yours.
        local need, _, color = ns.SkillInfo(name)
        row.text:SetText(need and (name .. "  |cff" .. color .. need .. "|r") or name)
        row:SetAlpha((ns.TooLow(name) or ns.IsGrey(name)) and 0.5 or 1)
        local n = counts[name] or 0
        row.count:SetText(n == 0 and "" or n == 1 and "1 spot" or (n .. " spots"))
      end
      row:SetShown(name ~= nil)
    end
    if #names > ROWS then
      self.position:SetText(string.format("%d-%d of %d, scroll for more", self.offset + 1,
        math.min(self.offset + ROWS, #names), #names))
    else
      self.position:SetText("")
    end
  end

  box:EnableMouseWheel(true)
  box:SetScript("OnMouseWheel", function(self, delta)
    self.offset = self.offset - delta * (IsShiftKeyDown() and ROWS or 3)
    ns.OnSettingsChanged()
  end)
  return box
end

local forgetConfirm
local function ShowForgetConfirm()
  if not forgetConfirm then
    local ok, box = pcall(CreateFrame, "Frame", "GatherLabelsForgetConfirm", UIParent, "BackdropTemplate")
    if not ok or not box then box = CreateFrame("Frame", "GatherLabelsForgetConfirm", UIParent) end
    box:SetSize(340, 118)
    box:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    box:SetFrameStrata("FULLSCREEN_DIALOG")
    box:SetToplevel(true)
    box:SetClampedToScreen(true)
    box:EnableMouse(true)
    S.Plate(box)
    if not box.SetBackdrop then
      local bg = box:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(0.06, 0.045, 0.03, 0.95)
    end
    local msg = S.Label(box, "Forget every saved herb and ore spot, for all your characters?", "GameFontHighlight")
    msg:SetPoint("TOPLEFT", 16, -16)
    msg:SetPoint("TOPRIGHT", -16, -16)
    msg:SetJustifyH("CENTER")
    msg:SetWordWrap(true)
    local yes = S.Button(box, YES or "Yes", 90)
    yes:SetPoint("BOTTOMRIGHT", box, "BOTTOM", -6, 14)
    yes:SetScript("OnClick", function()
      box:Hide()
      ns.ForgetAll()
    end)
    local no = S.Button(box, NO or "No", 90)
    no:SetPoint("BOTTOMLEFT", box, "BOTTOM", 6, 14)
    no:SetScript("OnClick", function() box:Hide() end)
    if S.CloseOnEscape then S.CloseOnEscape(box) end
    box:Hide()
    forgetConfirm = box
  end
  forgetConfirm:Show()
end

local TABS = {
  { label = "Settings" },
  { label = "Herbs and Ore", "herb", "ore" },
  { label = "Fishing and Treasure", "fish", "treasure" },
  { label = "This Zone", zone = true },
  { label = "Glow", glow = true },
}

local function BuildSettingsPage(page)
  local W = 280
  S.Header(page, "On the minimap", 0, 0, W)
  page.enabledCheck = S.Check(page, "Show herb and ore icons", nil,
    function(on) ns.Set("enabled", on) end, "Puts each node's own icon on the minimap instead of the yellow dot.")
  page.labelsCheck = S.Check(page, "Show names next to the icons", nil,
    function(on) ns.Set("labels", on) end)
  page.hoverCheck = S.Check(page, "Learn a spot when I hover its dot", nil,
    function(on) ns.Set("learnHover", on) end, "Hovering a yellow dot on the minimap saves that spot for good.")
  -- WoW Forever only (Scan.lua).
  page.scanCheck = S.Check(page, "Read the dots by themselves", nil,
    function(on) ns.Set("scan", on) end, "Names every dot straight off the minimap, no hovering needed. WoW Forever only.")
  page.savedCheck = S.Check(page, "Also show saved spots with no dot", nil,
    function(on) ns.Set("showSaved", on) end, "Spots you've found before show faded while nothing has spawned there.")
  page.ringModeCheck = S.Check(page, "Hollow rings for saved spots", nil,
    function(on) ns.Set("ringMode", on) end, "Draws hollow rings instead of filled icons on saved spots so live yellow tracking dots stay visible inside.")
  page.hideAboveCheck = S.Check(page, "Hide red nodes (skill too low)", nil,
    function(on) ns.Set("hideAbove", on) end,
    "Hides herbs and ore on the minimap that require a higher gathering skill than you have.")
  page.hideGreyCheck = S.Check(page, "Hide grey nodes (no skill-ups)", nil,
    function(on) ns.Set("hideGrey", on) end,
    "Hides herbs and ore on the minimap that no longer give gathering skill points.")
  page.minimapCheck = S.Check(page, "Show minimap button", nil,
    function(on) ns.SetMinimapShown(on) end)
  -- Stack the ticks this game uses, with no gaps for the ones it hides:
  -- reading the minimap is WoW Forever only, skill levels aren't on Retail.
  local scanner = ns.ScannerAvailable()
  page.scanCheck:SetShown(scanner)
  page.savedCheck:SetShown(scanner)
  page.hideAboveCheck:SetShown(ns.SkillApplies())
  page.hideGreyCheck:SetShown(ns.SkillApplies())
  local y = S.Stack({ page.enabledCheck, page.labelsCheck, page.hoverCheck, page.scanCheck,
    page.savedCheck, page.ringModeCheck, page.hideAboveCheck, page.hideGreyCheck, page.minimapCheck }, 0, -20)

  y = y - 6
  S.Header(page, "While gathering", 0, y, W)
  page.trackerCheck = S.Check(page, "Show the session tracker", nil,
    function(on) ns.Set("tracker", on) end, "A small panel with time, nodes, loot and what it's worth.")
  page.markCheck = S.Check(page, "Sparkle the node the arrow points to", nil,
    function(on) ns.Set("worldMark", on) end, "Click an icon on the minimap for an arrow; the node sparkles in the world.")
  page.shineCheck = S.Check(page, "Sparkle the nearest node by itself", "Also Shift-click the minimap button",
    function(on) ns.Set("autoShine", on) end)
  y = S.Stack({ page.trackerCheck, page.markCheck, page.shineCheck }, 0, y - 20)
  -- Which kinds sparkle by themselves.
  page.shineKinds = {}
  for i, c in ipairs(ns.CATEGORIES) do
    local key = c.key
    local check = S.Check(page, c.label, nil, function(on)
      ns.db.shine[key] = on
      if ns.ShineChanged then ns.ShineChanged() end
    end)
    check:SetPoint("TOPLEFT", 26 + ((i - 1) % 2) * 120, y - math.floor((i - 1) / 2) * 24)
    check.key = key
    page.shineKinds[i] = check
  end

  S.Divider(page, W + 18, 0, 490)

  -- Right column: look, saved spots.
  local x, RW = W + 36, 250
  S.Header(page, "Look", x, 0, RW)
  page.slider = S.Slider(page, "Icon size", RW - 12, 10, 24, 1,
    function(v) return tostring(v) end,
    function(v) if ns.db.iconSize ~= v then ns.Set("iconSize", v) end end)
  page.slider:SetPoint("TOPLEFT", x + 6, -46)
  local DETAIL_NAMES = { "Lightest", "Normal", "Most exact" }
  page.detail = S.Slider(page, "Scan detail", RW - 12, 1, 3, 1,
    function(v) return DETAIL_NAMES[v] or "" end,
    function(v) if ns.db.scanDetail ~= v then ns.Set("scanDetail", v) end end)
  page.detail:SetPoint("TOPLEFT", x + 6, -104)
  S.Tip(page.detail, "Scan detail", "Lightest is easiest on the game. Most exact catches dots right at the minimap's edge.")

  -- 1.8.0: the sparkle only shows near the node (same as Quest Glint).
  page.range = S.Slider(page, "Sparkle only closer than", RW - 12, 20, 150, 5,
    function(v) return v .. " yd" end,
    function(v) if ns.db.shineRange ~= v then ns.Set("shineRange", v) end end)
  page.range:SetPoint("TOPLEFT", x + 6, -162)
  S.Tip(page.range, "Sparkle only closer than", "The star over a node shows once you're this close. Farther away, the arrow still points the way.")
  page.animCheck = S.Check(page, "Sparkle moves", nil,
    function(on) ns.Set("shineAnim", on) end, "The star twinkles and a faint ring ripples out. Off: a still star.")
  page.animCheck:SetPoint("TOPLEFT", x, -212)

  S.Header(page, "Saved spots", x, -250, RW)
  page.stats = S.Label(page, "", "GameFontHighlight")
  page.stats:SetPoint("TOPLEFT", x, -272)
  page.stats:SetSpacing(3)
  local hint = S.Help(page, ns.ScannerAvailable()
    and "Turn on Find Herbs, Find Minerals, Find Fish or Find Treasure. Click an icon on the minimap for an arrow to it."
    or "Hover each dot on the minimap once, or gather the node, and its icon "
    .. "stays there for good. Click an icon for an arrow to it.", RW)
  hint:SetPoint("TOPLEFT", x, -318)
end

-- 1.9.0: the close-up glow (Glow.lua).
local function BuildGlowPage(page)
  local W = 280
  S.Header(page, "Close-up glow", 0, 0, W)
  page.glowCheck = S.Check(page, "Light up the node in front of me", "Herbs, ore, chests and your bobber",
    function(on) ns.Set("glow", on) end,
    "Dim while it's out of reach, a flash when you can gather it, grey when you can't.")
  page.animCheck = S.Check(page, "Glow moves", nil,
    function(on) ns.Set("glowAnim", on) end, "Off: a still light.")
  page.flashCheck = S.Check(page, "Flash when I can gather it", nil,
    function(on) ns.Set("glowFlash", on) end, "A quick burst of light the moment it comes into reach.")
  page.sparklesCheck = S.Check(page, "Beacon sparkles", nil,
    function(on) ns.Set("glowSparkles", on) end, "Little stars twinkle all the way up the Beacon's column of light.")
  page.fireCheck = S.Check(page, "Living flames", nil,
    function(on) ns.Set("glowFire", on) end, "The Power aura burns like real fire, with embers. Off: the older flickering aura.")
  -- Same row as Living flames (both are Power aura settings).
  page.powerCheck = S.Check(page, "Power-up burst", nil,
    function(on) ns.Set("glowPowerUp", on) end, "The Power aura bursts up with a shockwave and a flash when a node comes into view, then keeps surging with crackling energy.")
  page.powerCheck:SetPoint("TOPLEFT", page.fireCheck, "TOPLEFT", 140, 0)
  page.nameCheck = S.Check(page, "Show its name under the glow", nil,
    function(on) ns.Set("glowName", on) end, "In the game's skill colour. Grey nodes also say the skill they need.")
  page.iconCheck = S.Check(page, "Hide the game's small icon on it", nil,
    function(on) ns.Set("glowHideIcon", on) end, "The game floats a little pickaxe or hand over the node. Off: it shows inside the glow.")
  page.mineCheck = S.Check(page, "Only herbs and ore I can gather", nil,
    function(on) ns.Set("glowOnlyMine", on) end, "Herbs need Herbalism and veins need Mining, or they don't glow at all.")
  page.combatCheck = S.Check(page, "Hide in combat", nil,
    function(on) ns.Set("glowCombat", on) end)
  page.instanceCheck = S.Check(page, "Hide in dungeons and raids", nil,
    function(on) ns.Set("glowInstance", on) end)
  local y = S.Stack({ page.glowCheck, page.animCheck, page.flashCheck, page.sparklesCheck, page.fireCheck, page.nameCheck, page.iconCheck,
    page.mineCheck, page.combatCheck, page.instanceCheck }, 0, -20)

  y = y - 10
  S.Header(page, "What glows", 0, y, W)
  page.kinds = {}
  for i, k in ipairs(ns.GLOW_KINDS) do
    local key, c = k.key, k.color
    local hex = string.format("%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
    local check = S.Check(page, "|cff" .. hex .. k.label .. "|r", nil, function(on)
      ns.db.glowKinds[key] = on
      ns.Set("glowKinds", ns.db.glowKinds)
    end)
    check:SetPoint("TOPLEFT", 6 + ((i - 1) % 2) * 135, y - 20 - math.floor((i - 1) / 2) * 24)
    check.key = key
    page.kinds[i] = check
  end
  page.note = S.Help(page, "", W)
  page.note:SetPoint("TOPLEFT", 0, y - 100)

  S.Divider(page, W + 18, 0, 490)

  local x, RW = W + 36, 250
  S.Header(page, "Style", x, 0, RW)
  page.styles = {}
  for i, st in ipairs(ns.GLOW_STYLES) do
    local key = st.key
    local b = S.Button(page, st.label, 120, st.label, st.tip .. " Click to see it.")
    b:SetPoint("TOPLEFT", x + ((i - 1) % 2) * 126, -24 - math.floor((i - 1) / 2) * 26)
    b:SetScript("OnClick", function()
      ns.Set("glowStyle", key)
      ns.GlowPreview(page.previewKind)
    end)
    b.key = key
    page.styles[i] = b
  end

  page.size = S.Slider(page, "Size", RW - 12, 50, 200, 10,
    function(v) return v .. "%" end,
    function(v) if ns.db.glowSize ~= v then ns.Set("glowSize", v) end end)
  page.size:SetPoint("TOPLEFT", x + 6, -128)
  page.height = S.Slider(page, "Height", RW - 12, -80, 60, 5,
    function(v) return (v > 0 and "+" or "") .. v end,
    function(v) if ns.db.glowHeight ~= v then ns.Set("glowHeight", v) end end)
  page.height:SetPoint("TOPLEFT", x + 6, -184)
  S.Tip(page.height, "Height", "Moves the light down onto the ground (minus) or up (plus) from where the game marks the node.")
  page.bright = S.Slider(page, "Brightness", RW - 12, 20, 100, 5,
    function(v) return v .. "%" end,
    function(v) if ns.db.glowBright ~= v then ns.Set("glowBright", v) end end)
  page.bright:SetPoint("TOPLEFT", x + 6, -240)
  page.reach = S.Slider(page, "Starts to glow from", RW - 12, 5, 15, 1,
    function(v) return v .. " yd" end,
    function(v) if ns.db.glowRange ~= v then ns.Set("glowRange", v) end end)
  page.reach:SetPoint("TOPLEFT", x + 6, -296)
  S.Tip(page.reach, "Starts to glow from", "How far away a node lights up (dimly, until you're close enough to gather it). The game allows up to 15 yards.")

  local KINDS = { "herb", "ore", "treasure", "bobber" }
  page.previewKind = "herb"
  local preview = S.Button(page, "Preview", 120, "Preview",
    "Shows the glow in the middle of your screen: out of reach, in reach, then grey. Each click shows the next colour.")
  preview:SetPoint("TOPLEFT", x, -344)
  preview:SetScript("OnClick", function()
    ns.GlowPreview(page.previewKind)
    for i, k in ipairs(KINDS) do
      if k == page.previewKind then
        page.previewKind = KINDS[i % #KINDS + 1]
        break
      end
    end
  end)
end

local function BuildListPage(page, def)
  local width = 284
  for col = 1, 2 do
    local key = def[col]
    local label
    for _, c in ipairs(ns.CATEGORIES) do if c.key == key then label = c.label end end
    local x = (col - 1) * (width + 18)
    S.Header(page, label, x, -4, width - 132)
    local none = S.Button(page, "None", 60)
    none:SetPoint("TOPLEFT", x + width - 60, 0)
    none:SetScript("OnClick", function() ns.SetCategoryShown(key, false) end)
    local all = S.Button(page, "All", 60)
    all:SetPoint("RIGHT", none, "LEFT", -4, 0)
    all:SetScript("OnClick", function() ns.SetCategoryShown(key, true) end)
    local list = NodeList(page, key, width)
    list:SetPoint("TOPLEFT", x, -28)
    frame.lists[key] = list
  end
end

local selectedZoneMapID
local sortedZoneIDs

local function ZoneDisplayName(mapID)
  if not mapID then return "Unknown zone" end
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return (info and info.name and info.name ~= "" and info.name) or ("Zone " .. mapID)
end

local function GetSortedZoneIDs()
  if sortedZoneIDs then return sortedZoneIDs end
  sortedZoneIDs = {}
  local hasMapInfo = C_Map and C_Map.GetMapInfo
  for mapID in pairs(ns.ZONE_DATA or {}) do
    if not hasMapInfo or C_Map.GetMapInfo(mapID) ~= nil then
      sortedZoneIDs[#sortedZoneIDs + 1] = mapID
    end
  end
  table.sort(sortedZoneIDs, function(a, b)
    local na, nb = ZoneDisplayName(a), ZoneDisplayName(b)
    if na ~= nb then return na < nb end
    return a < b
  end)
  return sortedZoneIDs
end

local function ZoneScrollList(parent, x, y, width, rows)
  local rowH = 24
  local box = S.Box(parent)
  box:SetSize(width, math.max(190, rows * rowH + 10))
  box:SetPoint("TOPLEFT", x, y)
  box.offset = 0
  box.items = {}
  box.pool = {}
  box.rows = {}
  for i = 1, rows do
    local row = CreateFrame("Frame", nil, box)
    row:SetSize(width - 12, 22)
    row:SetPoint("TOPLEFT", 6, -5 - (i - 1) * rowH)
    if i % 2 == 0 then
      local stripe = box:CreateTexture(nil, "BACKGROUND", nil, 1)
      stripe:SetPoint("TOPLEFT", 4, -4 - (i - 1) * rowH)
      stripe:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", -4, -4 - i * rowH)
      stripe:SetColorTexture(1, 1, 1, 0.03)
    end
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.text = S.Label(row, "")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    box.rows[i] = row
  end
  box.empty = S.Help(box, "None recorded for this zone", width - 20)
  box.empty:SetPoint("CENTER")
  box.empty:SetJustifyH("CENTER")
  box.position = S.Help(box, "")
  box.position:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", -2, -3)

  function box:ClearItems()
    self.count = 0
  end

  function box:AddItem(icon, text, alpha)
    self.count = (self.count or 0) + 1
    local entry = self.pool[self.count]
    if not entry then
      entry = {}
      self.pool[self.count] = entry
    end
    entry.icon, entry.text, entry.alpha = icon, text, alpha or 1
    self.items[self.count] = entry
  end

  function box:Render()
    local total = self.count or 0
    local maxOffset = math.max(0, total - rows)
    self.offset = math.min(math.max(self.offset, 0), maxOffset)
    for i, row in ipairs(self.rows) do
      local entry = (self.offset + i <= total) and self.items[self.offset + i] or nil
      if entry then
        row.icon:SetTexture(entry.icon)
        row.text:SetText(entry.text)
        row:SetAlpha(entry.alpha or 1)
      end
      row:SetShown(entry ~= nil)
    end
    self.empty:SetShown(total == 0)
    if total > rows then
      self.position:SetText(string.format("%d-%d of %d, scroll", self.offset + 1,
        math.min(self.offset + rows, total), total))
    else
      self.position:SetText("")
    end
  end

  box:EnableMouseWheel(true)
  box:SetScript("OnMouseWheel", function(self, delta)
    self.offset = self.offset - delta * (IsShiftKeyDown() and rows or 3)
    self:Render()
  end)
  return box
end

local function FillZoneNodes(box, names)
  box:ClearItems()
  if names then
    for i = 1, #names do
      local name = names[i]
      local need, _, color = ns.SkillInfo(name)
      local text = need and (name .. "  |cff" .. color .. need .. "|r") or name
      local dim = ((ns.TooLow and ns.TooLow(name)) or (ns.IsGrey and ns.IsGrey(name))) and 0.5 or 1
      box:AddItem(ns.Icon(name), text, dim)
    end
  end
  box:Render()
end

local function BuildZonePage(page)
  local W = 284
  page.zoneTitle = S.Label(page, "", "GameFontNormalLarge")
  page.zoneTitle:SetPoint("TOPLEFT", 0, 0)
  page.zoneTitle:SetSize(430, 18)
  page.zoneTitle:SetJustifyH("LEFT")
  page.zoneSub = S.Help(page, "Herbs, ore and fish known in this zone (reference only).", 430)
  page.zoneSub:SetPoint("TOPLEFT", 0, -20)

  local function StepZone(dir)
    local ids = GetSortedZoneIDs()
    if #ids == 0 then return end
    local curMap = (ns.ZoneMap and ns.ZoneMap()) or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
    local active = selectedZoneMapID or curMap
    local idx = 1
    for i, id in ipairs(ids) do
      if id == active then idx = i break end
    end
    idx = ((idx - 1 + dir) % #ids) + 1
    selectedZoneMapID = ids[idx]
    page.herbsBox.offset, page.oresBox.offset, page.fishBox.offset = 0, 0, 0
    ns.OnSettingsChanged()
  end

  page.nextBtn = S.Button(page, ">", 28, "Next zone", "Browse next zone")
  page.nextBtn:SetPoint("TOPRIGHT", 0, 0)
  page.nextBtn:SetScript("OnClick", function() StepZone(1) end)

  page.hereBtn = S.Button(page, "Here", 56, "Current zone", "Show your current zone")
  page.hereBtn:SetPoint("RIGHT", page.nextBtn, "LEFT", -4, 0)
  page.hereBtn:SetScript("OnClick", function()
    selectedZoneMapID = nil
    page.herbsBox.offset, page.oresBox.offset, page.fishBox.offset = 0, 0, 0
    ns.OnSettingsChanged()
  end)

  page.prevBtn = S.Button(page, "<", 28, "Previous zone", "Browse previous zone")
  page.prevBtn:SetPoint("RIGHT", page.hereBtn, "LEFT", -4, 0)
  page.prevBtn:SetScript("OnClick", function() StepZone(-1) end)

  S.Header(page, "Herbs", 0, -44, W)
  page.herbsBox = ZoneScrollList(page, 0, -68, W, 7)

  S.Header(page, "Ore", 0, -264, W)
  page.oresBox = ZoneScrollList(page, 0, -288, W, 7)

  local RX = W + 18
  S.Header(page, "Fishing", RX, -44, W)
  page.fishBox = ZoneScrollList(page, RX, -68, W, 16)

  function page:Refresh()
    local curMap = (ns.ZoneMap and ns.ZoneMap()) or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
    local activeMapID = selectedZoneMapID or curMap
    local title = ZoneDisplayName(activeMapID)
    if activeMapID and activeMapID == curMap and not selectedZoneMapID then
      page.zoneTitle:SetText(title .. "  |cffaaaaaa(here)|r")
    else
      page.zoneTitle:SetText(title)
    end
    page.hereBtn:SetAlpha((selectedZoneMapID and selectedZoneMapID ~= curMap) and 1 or 0.5)

    local z = activeMapID and ns.ZONE_DATA and ns.ZONE_DATA[activeMapID]
    FillZoneNodes(page.herbsBox, z and z.herbs)
    FillZoneNodes(page.oresBox, z and z.ores)

    page.fishBox:ClearItems()
    if z and z.pools then
      for i = 1, #z.pools do
        local name = z.pools[i]
        page.fishBox:AddItem(ns.Icon(name), name .. "  |cff70c8e0(pool)|r", 1)
      end
    end
    if z and z.fish then
      for i = 1, #z.fish do
        local f = z.fish[i]
        local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(f[2]))
          or (GetItemIcon and GetItemIcon(f[2]))
          or "Interface\\Icons\\INV_Misc_Fish_02"
        local fname = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(f[2]))
          or (GetItemInfo and GetItemInfo(f[2]))
          or f[1]
        page.fishBox:AddItem(icon, fname, 1)
      end
    end
    page.fishBox:Render()
  end
end

local function SelectTab(i)
  frame.tab = i
  for p, page in ipairs(frame.pages) do page:SetShown(p == i) end
  if i == 1 or TABS[i].glow then
    frame.topHelp:SetText("Every change is saved the moment you click it.")
  elseif TABS[i].zone then
    frame.topHelp:SetText("Herbs, ore and fish recorded for the zone (reference only).")
  else
    frame.topHelp:SetText("Untick a node to keep it off the minimap (and from glowing). The number is how many spots you've found.")
  end
  S.SelectTab(frame, i)
  ns.OnSettingsChanged()
end

local function Build()
  frame = S.Window({ name = "GatherLabelsFrame", title = "Gather Labels",
    icon = "Interface\\Icons\\INV_Misc_Flower_02", width = 640, height = 610 })
  frame:SetScript("OnShow", function() SelectTab(frame.tab or 1) end)
  frame:HookScript("OnHide", function()
    if forgetConfirm then forgetConfirm:Hide() end
  end)
  frame.topHelp = S.Help(frame.attic, "", 540)
  frame.topHelp:SetPoint("LEFT", 6, -2)

  frame.pages, frame.lists = {}, {}
  for i, def in ipairs(TABS) do
    local page = CreateFrame("Frame", nil, frame.Inset)
    page:SetPoint("TOPLEFT", 14, -12)
    page:SetPoint("BOTTOMRIGHT", -14, 8)
    page:Hide()
    frame.pages[i] = page
    if i == 1 then BuildSettingsPage(page)
    elseif def.zone then BuildZonePage(page)
    elseif def.glow then BuildGlowPage(page)
    else BuildListPage(page, def) end
  end
  frame.page = frame.pages[1]
  for i, def in ipairs(TABS) do
    if def.glow then frame.glowPage = frame.pages[i]
    elseif def.zone then frame.zonePage = frame.pages[i]; frame.zoneTabIndex = i end
  end

  local forget = S.Button(frame, "Forget all spots", 130, "Forget all spots",
    "Wipes every saved spot, for all your characters. Asks first.")
  forget:SetPoint("BOTTOMRIGHT", -8, 4)
  forget:SetScript("OnClick", ShowForgetConfirm)
  frame.routeButton = S.Button(frame, "Start farming route", 150, "Farming route",
    "A loop through the saved spots in this zone, drawn on the minimap. The arrow leads you round it.")
  frame.routeButton:SetPoint("RIGHT", forget, "LEFT", -6, 0)
  frame.routeButton:SetScript("OnClick", function()
    if ns.RouteActive() then ns.StopRoute() else ns.StartRoute() end
  end)

  local labels = {}
  for i, def in ipairs(TABS) do labels[i] = def.label end
  S.Tabs(frame, labels, SelectTab)
end

function ns.OnSettingsChanged()
  if not frame or not frame:IsShown() then return end
  local db, page = ns.db, frame.page
  page.enabledCheck:SetChecked(db.enabled)
  page.labelsCheck:SetChecked(db.labels)
  page.hoverCheck:SetChecked(db.learnHover)
  page.minimapCheck:SetChecked(not db.minimapHidden)
  page.detail:SetShown(ns.ScannerAvailable())
  page.scanCheck:SetChecked(db.scan)
  page.savedCheck:SetChecked(db.showSaved)
  page.ringModeCheck:SetChecked(db.ringMode)
  page.hideAboveCheck:SetChecked(db.hideAbove)
  page.hideGreyCheck:SetChecked(db.hideGrey)
  page.markCheck:SetChecked(db.worldMark)
  page.trackerCheck:SetChecked(db.tracker)
  page.shineCheck:SetChecked(db.autoShine)
  for _, check in ipairs(page.shineKinds) do
    check:SetChecked(db.shine[check.key])
    check:SetAlpha(db.autoShine and 1 or 0.5)
  end
  page.slider:Sync(db.iconSize)
  page.detail:Sync(db.scanDetail)
  page.range:Sync(db.shineRange)
  page.animCheck:SetChecked(db.shineAnim)
  local counts, total, here = ns.CountSpots()
  page.stats:SetText(string.format("All spots: |cffffffff%d|r\nOn this continent: |cffffffff%d|r", total, here))
  if frame.tab and frame.tab > 1 then
    for _, list in pairs(frame.lists) do
      if list:IsVisible() then list:Refresh(counts) end
    end
    if frame.zonePage and frame.zonePage:IsVisible() then frame.zonePage:Refresh() end
  end
  frame.routeButton:SetText(ns.RouteActive() and "Stop farming route" or "Start farming route")
  local g = frame.glowPage
  if g then
    g.glowCheck:SetChecked(db.glow)
    g.animCheck:SetChecked(db.glowAnim)
    g.flashCheck:SetChecked(db.glowFlash)
    g.sparklesCheck:SetChecked(db.glowSparkles ~= false)
    g.fireCheck:SetChecked(db.glowFire ~= false)
    g.powerCheck:SetChecked(db.glowPowerUp ~= false)
    g.nameCheck:SetChecked(db.glowName)
    g.iconCheck:SetChecked(db.glowHideIcon)
    g.mineCheck:SetChecked(db.glowOnlyMine)
    g.combatCheck:SetChecked(db.glowCombat)
    g.instanceCheck:SetChecked(db.glowInstance)
    for _, check in ipairs(g.kinds) do
      check:SetChecked(db.glowKinds[check.key] ~= false)
      check:SetAlpha(db.glow and 1 or 0.5)
    end
    for _, b in ipairs(g.styles) do
      local on = b.key == db.glowStyle
      if on then b:LockHighlight() else b:UnlockHighlight() end
      local text = b.GetFontString and b:GetFontString()
      if text then
        if on then text:SetTextColor(1, 0.82, 0) else text:SetTextColor(0.85, 0.85, 0.85) end
      end
    end
    g.size:Sync(db.glowSize)
    g.height:Sync(db.glowHeight)
    g.bright:Sync(db.glowBright)
    g.reach:Sync(db.glowRange)
    local blocked = ns.GlowBlockedBy()
    if not ns.GlowAvailable() then
      g.note:SetText("This version of the game can't pick the object in front of you, so there's no close-up glow here.")
    elseif blocked then
      g.note:SetText("|cffff8040" .. blocked .. " is on, so Gather Labels leaves the glow to it.|r")
    else
      g.note:SetText("While the glow is on, the game's own settings for clicking objects near you are switched on. They're put back when it's off, and when you log out.")
    end
  end
end

function ns.ToggleSettings()
  if not frame then Build() end
  frame:SetShown(not frame:IsShown())
end

function ns.ShowZoneTab()
  if not frame then Build() end
  selectedZoneMapID = nil
  frame:Show()
  if frame.zoneTabIndex then SelectTab(frame.zoneTabIndex) end
end

local zoneEvents = CreateFrame("Frame")
zoneEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")
zoneEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneEvents:SetScript("OnEvent", function()
  selectedZoneMapID = nil
  if frame and frame:IsShown() then ns.OnSettingsChanged() end
end)
