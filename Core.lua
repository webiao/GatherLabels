local ADDON_NAME, ns = ...

-- The game draws herbs and ore on the minimap as plain dots and doesn't tell
-- addons where those dots are. So Gather Labels remembers each spot where a
-- herb or ore node spawns, and draws that node's icon there (Pins.lua).
-- A spot is learned when you:
--   * hover a dot on the minimap once (the game's tooltip names it), or
--   * gather the node (exact position, and works for any node name).
-- Spots are saved for all your characters, so each one only has to be
-- learned once.

local DEFAULTS = {
  enabled = true,     -- draw icons on the minimap
  labels = true,      -- names next to the icons
  learnHover = true,  -- learn spots from the minimap tooltip
  iconSize = 14,
  minimapAngle = 200,
  minimapHidden = false,
  scan = true,        -- WoW Forever: read the dots off the minimap
  disableScan = false, -- completely disable minimap and hover scanning
  scanDetail = 2,     -- 1 lightest .. 3 most exact
  showSaved = false,  -- WoW Forever: also show saved spots with no dot now
  ringMode = false,   -- draw hollow rings on saved spots so tracking dots stay visible inside
  hideAbove = false,  -- hide nodes your gathering skill is too low for
  hideGrey = false,   -- hide nodes that no longer give skill-ups (grey)
  tracker = true,     -- show the gathering session panel
  worldMark = true,   -- sparkle in the world on the node the arrow points to
  autoShine = false,  -- sparkle the nearest node in range by itself
  shineRange = 50,    -- yards: the sparkle shows only on nodes closer than this (1.8.0)
  shineAnim = true,   -- the sparkle twinkles and ripples
  -- 1.9.0 close-up glow (Glow.lua)
  glow = true,          -- light up the herb, vein, chest or bobber in front of you
  glowStyle = "halo",
  glowAnim = true,      -- the light moves
  glowFlash = true,     -- flash when it comes into reach
  glowSparkles = true,  -- 1.9.3: stars twinkling up the Beacon
  glowFire = true,      -- 1.9.4: Power aura burns as living flames
  glowPowerUp = true,   -- 1.9.5: Power aura powers up with a burst, then crackles
  glowName = true,      -- its name under the light
  glowHideIcon = true,  -- hide the game's small icon on it while it glows
  glowOnlyMine = true,  -- only herbs/ore if you have Herbalism/Mining
  glowCombat = true,    -- no glow in combat
  glowInstance = false, -- no glow in dungeons and raids
  glowSize = 100,       -- percent
  glowHeight = -20,     -- pixels up/down from the game's spot for it
  glowBright = 85,      -- percent
  glowRange = 15,       -- yards: how far away a node starts to glow (dim until in reach)
}

local PREFIX = ns.Skin.Prefix("Gather Labels", "Interface\\Icons\\INV_Misc_Flower_02")
function ns.Print(text)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

-- Fresh install or missing keys from an older version.
local function InitDB()
  GatherLabelsDB = GatherLabelsDB or {}
  local db = GatherLabelsDB
  for key, value in pairs(DEFAULTS) do
    if db[key] == nil then db[key] = value end
  end
  db.spots = db.spots or {}     -- [continent][cell] = list of spots
  db.hidden = db.hidden or {}   -- [node name] = true when unchecked in Settings
  db.learned = db.learned or {} -- [node name] = "herb"/"ore" for names not in Nodes.lua
  db.icons = db.icons or {}     -- [node name] = icon of the loot, for learned names
  db.shine = db.shine or { herb = true, ore = true, fish = false, treasure = false } -- kinds that sparkle by themselves
  db.glowKinds = db.glowKinds or { herb = true, ore = true, treasure = true, fish = true, bobber = true }
  local function Clamp(key, lo, hi)
    if type(db[key]) ~= "number" then db[key] = DEFAULTS[key] end
    db[key] = math.max(lo, math.min(hi, math.floor(db[key] + 0.5)))
  end
  Clamp("glowSize", 50, 200)
  Clamp("glowHeight", -80, 60)
  Clamp("glowBright", 20, 100)
  Clamp("glowRange", 5, 15)
  if type(db.shineRange) ~= "number" then db.shineRange = DEFAULTS.shineRange end
  db.shineRange = math.max(20, math.min(150, math.floor(db.shineRange + 0.5)))
  ns.db = db
end

---------------------------------------------------------------------------
-- Node names and icons
---------------------------------------------------------------------------

local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local iconCache = {}

function ns.Category(name)
  local node = ns.NODES[name]
  if node then return node.category end
  return ns.db.learned[name]
end

-- Retail nodes come in many forms ("Lush Mycobloom", "Rich Bismuth Deposit"),
-- and fishing pools can carry density prefixes ("Sparse Oily Blackmouth School")
-- or "Pool" suffixes ("Waterlogged Wreckage Pool"). Looked up once per name.
local FISH_PREFIXES = { "Lesser ", "Sparse ", "Abundant ", "Teeming " }
local FISH_ALIASES = {
  ["Thousandbite Pirahna Swarm"] = "Thousandbite Piranha Swarm",
}

local function CanonFishPool(name)
  local candidate = FISH_ALIASES[name] or name
  if ns.NODES[candidate] and ns.NODES[candidate].category == "fish" then return candidate end
  for _, prefix in ipairs(FISH_PREFIXES) do
    if candidate:sub(1, #prefix) == prefix then
      candidate = candidate:sub(#prefix + 1)
      break
    end
  end
  candidate = FISH_ALIASES[candidate] or candidate
  if ns.NODES[candidate] and ns.NODES[candidate].category == "fish" then return candidate end
  if candidate:sub(-5) == " Pool" then
    candidate = candidate:sub(1, -6)
    candidate = FISH_ALIASES[candidate] or candidate
    if ns.NODES[candidate] and ns.NODES[candidate].category == "fish" then return candidate end
  end
end

local canon, canonCount = {}, 0
function ns.Canon(name)
  if ns.NODES[name] or ns.db.learned[name] then return name end
  local base = canon[name]
  if base == nil then
    base = CanonFishPool(name) or false
    if not base then
      for _, modern in ipairs(ns.MODERN) do
        if name:find(modern, 1, true) then
          base = modern
          break
        end
      end
    end
    if canonCount > 500 then
      wipe(canon)
      canonCount = 0
    end
    canon[name], canonCount = base, canonCount + 1
  end
  return base or name
end

-- Current Retail (not Classic and not WoW Forever, which report a low
-- interface number).
ns.IS_RETAIL = ((GetBuildInfo and select(4, GetBuildInfo())) or 0) >= 100000

function ns.Icon(name)
  if iconCache[name] then return iconCache[name] end
  local node, icon = ns.NODES[name], nil
  if node and node.item > 0 and GetItemIcon then icon = GetItemIcon(node.item) end
  icon = icon or ns.db.icons[name]
  if not icon then
    local category = ns.Category(name)
    for _, c in ipairs(ns.CATEGORIES) do
      if c.key == category then icon = c.fallbackIcon end
    end
  end
  iconCache[name] = icon
  return icon
end

function ns.IsShownName(name)
  return not ns.db.hidden[name]
end

-- Expansion of the running game, so the settings list only nodes that exist.
function ns.GameExpansion()
  if ns.IS_FOREVER then return 0 end
  local toc = GetBuildInfo and select(4, GetBuildInfo())
  if type(toc) == "number" and toc >= 10000 then
    return math.floor(toc / 10000) - 1
  end
  if GetClientDisplayExpansionLevel then return GetClientDisplayExpansionLevel() end
  if GetExpansionLevel then return GetExpansionLevel() end
  return 0
end

-- Names to list in Settings for one category: known nodes for this game
-- version, then any learned ones.
function ns.NamesFor(category)
  local list, maxExp = {}, ns.GameExpansion()
  for _, name in ipairs(ns.NODE_LIST[category]) do
    local node = ns.NODES[name]
    if node.exp <= maxExp then list[#list + 1] = name end
  end
  local extra = {}
  for name, c in pairs(ns.db.learned) do
    if c == category and not ns.NODES[name] then extra[#extra + 1] = name end
  end
  table.sort(extra)
  for _, name in ipairs(extra) do list[#list + 1] = name end
  return list
end

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------

-- Player position in world yards: x grows to the north, y to the west.
-- Returns nothing inside dungeons and other places the game hides it.
-- Asked by the pins, the arrow, the sparkle and the scanner, often in the
-- same frame; worked out once per frame (GetTime() is the frame's time).
local posTime, posContinent, posX, posY
function ns.PlayerWorldPos()
  local now = GetTime()
  if now == posTime then return posContinent, posX, posY end
  posTime, posContinent, posX, posY = now, nil, nil, nil
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local continent, world = C_Map.GetWorldPosFromMapPos(mapID, pos)
  if not continent or not world then return end
  local x, y = world:GetXY()
  posContinent, posX, posY = continent, x, y
  return continent, x, y
end

-- Width in yards of the minimap at each zoom level.
local OUTDOOR = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

function ns.MinimapRadius()
  if C_Minimap and C_Minimap.GetViewRadius then
    local radius = C_Minimap.GetViewRadius()
    if radius and radius > 0 then return radius end
  end
  local sizes = (IsIndoors and IsIndoors()) and INDOOR or OUTDOOR
  return (sizes[Minimap:GetZoom()] or OUTDOOR[0]) / 2
end

-- How far the minimap is turned. Zero unless "Rotate Minimap" is on; nil if
-- it is on but the game won't say which way you face.
function ns.MinimapFacing()
  if GetCVar("rotateMinimap") ~= "1" then return 0 end
  return GetPlayerFacing and GetPlayerFacing()
end

-- World position under the mouse on the minimap.
local function CursorWorldPos()
  local continent, px, py = ns.PlayerWorldPos()
  if not continent then return end
  local facing = ns.MinimapFacing()
  if not facing then return end
  local scale = Minimap:GetEffectiveScale()
  local cx, cy = GetCursorPosition()
  local mx, my = Minimap:GetCenter()
  local yardsPerPixel = ns.MinimapRadius() / (Minimap:GetWidth() / 2)
  local sx, sy = (cx / scale - mx) * yardsPerPixel, (cy / scale - my) * yardsPerPixel
  local cos, sin = math.cos(facing), math.sin(facing)
  local east, north = sx * cos - sy * sin, sx * sin + sy * cos
  return continent, px + north, py - east
end

---------------------------------------------------------------------------
-- Spot store
---------------------------------------------------------------------------

-- Spots are bucketed in squares of CELL yards so drawing only looks at the
-- few squares around you.
ns.CELL = 500
local MERGE = 15 -- sightings this close (same category) are the same spot

function ns.CellKey(x, y)
  return math.floor(x / ns.CELL) .. ":" .. math.floor(y / ns.CELL)
end

local function FindSpot(cells, x, y, category)
  local cx, cy = math.floor(x / ns.CELL), math.floor(y / ns.CELL)
  local best, bestDist, bestKey, bestIndex
  for i = cx - 1, cx + 1 do
    for j = cy - 1, cy + 1 do
      local key = i .. ":" .. j
      local list = cells[key]
      if list then
        for index, spot in ipairs(list) do
          if spot.c == category then
            local d = (spot.x - x) ^ 2 + (spot.y - y) ^ 2
            if d < MERGE * MERGE and (not bestDist or d < bestDist) then
              best, bestDist, bestKey, bestIndex = spot, d, key, index
            end
          end
        end
      end
    end
  end
  return best, bestKey, bestIndex
end

local function Insert(cells, spot)
  local key = ns.CellKey(spot.x, spot.y)
  cells[key] = cells[key] or {}
  table.insert(cells[key], spot)
end

-- Record that node `name` was seen at x, y. exact = gathered there.
-- cave: true/false when known (indoors: a cave or building), nil if not.
local function AddSighting(continent, x, y, name, category, exact, cave)
  local db = ns.db
  db.spots[continent] = db.spots[continent] or {}
  local cells = db.spots[continent]
  local spot, key, index = FindSpot(cells, x, y, category)
  local now = time()
  if spot then
    local isNew = not spot.n[name]
    spot.n[name] = now
    spot.last = name
    if cave ~= nil then spot.cave = cave or nil end
    -- A gathered position beats one guessed from the minimap.
    if exact and not spot.e then
      table.remove(cells[key], index)
      spot.x, spot.y, spot.e = x, y, true
      Insert(cells, spot)
    end
    if isNew and ns.OnSpotsChanged then ns.OnSpotsChanged() end
    return
  end
  Insert(cells, { x = x, y = y, c = category, n = { [name] = now }, last = name, e = exact or nil, cave = cave or nil })
  if ns.OnSpotsChanged then ns.OnSpotsChanged() end
end
ns.AddSighting = AddSighting

-- How many spots are saved per node name, and in total.
function ns.CountSpots()
  local perName, total, here = {}, 0, 0
  local continent = ns.PlayerWorldPos()
  for c, cells in pairs(ns.db.spots) do
    for _, list in pairs(cells) do
      for _, spot in ipairs(list) do
        total = total + 1
        if c == continent then here = here + 1 end
        for name in pairs(spot.n) do perName[name] = (perName[name] or 0) + 1 end
      end
    end
  end
  return perName, total, here
end

function ns.ForgetAll()
  wipe(ns.db.spots)
  if ns.OnSpotsChanged then ns.OnSpotsChanged() end
  ns.Print("All saved spots forgotten.")
end

---------------------------------------------------------------------------
-- Learning from the minimap tooltip
---------------------------------------------------------------------------

-- Drop color codes and inline icons, trim spaces.
local function Clean(text)
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  text = text:gsub("|T.-|t", ""):gsub("|A.-|a", "")
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end
ns.Clean = Clean

-- Retail can hand back "secret" text addons may not read; treat it as nothing.
local function Readable(text)
  return type(text) == "string" and not (issecretvalue and issecretvalue(text))
end
ns.Readable = Readable

local tooltipNames = {}
local function TooltipNames()
  wipe(tooltipNames)
  for i = 1, GameTooltip:NumLines() do
    local line = _G["GameTooltipTextLeft" .. i]
    local text = line and line:GetText()
    if Readable(text) then
      for part in (text .. "\n"):gmatch("(.-)\n") do
        local name = ns.Canon(Clean(part))
        if ns.Category(name) then tooltipNames[#tooltipNames + 1] = name end
      end
    end
  end
  return tooltipNames
end

local function ReadLeft1Text()
  return GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
end

-- Fishing pools are often seen in the world rather than on the minimap.
-- Hovering one shows its name; you fish from about 15 yards away, so the
-- pool is taken to be that far ahead of you.
local lastWorldText
local function LearnWorldHover()
  if GameTooltip:GetOwner() == Minimap or GameTooltip:GetUnit() then return end
  local ok, text = pcall(ReadLeft1Text)
  if not ok or not Readable(text) or text == lastWorldText then return end
  lastWorldText = text
  local name = ns.Canon(Clean(text))
  if ns.Category(name) ~= "fish" then return end
  local continent, x, y = ns.PlayerWorldPos()
  local facing = GetPlayerFacing and GetPlayerFacing()
  if not continent or not facing then return end
  -- facing: 0 is north, turning towards west; x grows north, y grows west.
  AddSighting(continent, x + 15 * math.cos(facing), y + 15 * math.sin(facing), name, "fish", false)
end

local lastText, lastX, lastY, elapsedTotal = nil, nil, nil, 0
local watcher = CreateFrame("Frame")

local function WatcherOnUpdate(_, elapsed)
  elapsedTotal = elapsedTotal + elapsed
  if elapsedTotal < 0.1 then return end
  elapsedTotal = 0
  if ns.db and ns.db.learnHover and not ns.db.disableScan and GameTooltip:IsShown() then
    pcall(LearnWorldHover)
  else
    lastWorldText = nil
  end
  -- While the scanner (Scan.lua) is actively sweeping, the tooltip can show the points it
  -- asks about rather than what is under the mouse, so wait until the sweep finishes.
  if not ns.db or ns.db.disableScan or not ns.db.learnHover or (ns.ScannerSweeping and ns.ScannerSweeping())
      or not GameTooltip:IsShown()
      or GameTooltip:GetOwner() ~= Minimap then
    lastText, lastX, lastY = nil, nil, nil
    return
  end
  local ok, text = pcall(ReadLeft1Text)
  if not ok or not Readable(text) then return end
  -- Same text: only a new spot if the mouse moved on to another dot.
  local cx, cy = GetCursorPosition()
  local moved = lastX and ((cx - lastX) ^ 2 + (cy - lastY) ^ 2) > 100 * Minimap:GetEffectiveScale() ^ 2
  if text == lastText and not moved then return end
  lastText, lastX, lastY = text, cx, cy
  local okNames, names = pcall(TooltipNames)
  if not okNames or #names == 0 then return end
  local continent, x, y = CursorWorldPos()
  if not continent then return end
  for _, name in ipairs(names) do AddSighting(continent, x, y, name, ns.Category(name), false) end
end

local function SyncWatcher()
  if ns.db and ns.db.learnHover and not ns.db.disableScan then
    watcher:SetScript("OnUpdate", WatcherOnUpdate)
  else
    watcher:SetScript("OnUpdate", nil)
    lastText, lastX, lastY, lastWorldText, elapsedTotal = nil, nil, nil, nil, 0
  end
end

---------------------------------------------------------------------------
-- Learning from gathering
---------------------------------------------------------------------------

local function SpellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  if GetSpellInfo then return (GetSpellInfo(id)) end
end

-- Spell -> category. "Opening" opens chests but also many other things, so
-- it only counts for chests Gather Labels knows (Nodes.lua).
local GATHER_SPELLS = { ["Herb Gathering"] = "herb", ["Mining"] = "ore", ["Opening"] = "treasure" }

local pending, lastGather

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("UNIT_SPELLCAST_SENT")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
events:RegisterEvent("LOOT_OPENED")
events:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... == ADDON_NAME then
      InitDB()
      SyncWatcher()
      if ns.SyncScanner then ns.SyncScanner() end
      -- The game's own names for the gathering spells, for non-English clients.
      local herb, mining, opening = SpellName(2366), SpellName(2575), SpellName(3365)
      if herb then GATHER_SPELLS[herb] = "herb" end
      if mining then GATHER_SPELLS[mining] = "ore" end
      if opening then GATHER_SPELLS[opening] = "treasure" end
    end
  elseif event == "UNIT_SPELLCAST_SENT" then
    local unit, target, castGUID, spellID = ...
    if unit ~= "player" or not ns.db then return end
    pcall(function()
      if not Readable(target) then return end
      target = ns.Canon(target)
      local category = GATHER_SPELLS[SpellName(spellID) or ""]
      if category == "treasure" and ns.Category(target) ~= "treasure" then category = nil end
      if category and type(target) == "string" and target ~= "" then
        pending = { guid = castGUID, name = target, category = category }
      end
    end)
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, castGUID = ...
    if unit ~= "player" or not pending then return end
    local ok, same = pcall(function() return castGUID == pending.guid end)
    if not ok or not same then return end
    local name = pending.name
    local category = ns.NODES[name] and ns.NODES[name].category or pending.category
    pending = nil
    if not ns.NODES[name] and not ns.db.learned[name] then
      ns.db.learned[name] = category
      if ns.OnSettingsChanged then ns.OnSettingsChanged() end
    end
    local continent, x, y = ns.PlayerWorldPos()
    if continent then AddSighting(continent, x, y, name, category, true, (IsIndoors and IsIndoors()) and true or false) end
    lastGather = { name = name, time = GetTime() }
    if ns.OnGathered then ns.OnGathered(name, continent, x, y) end
  elseif event == "LOOT_OPENED" then
    -- For nodes we didn't know, use the icon of what they gave.
    if lastGather and GetTime() - lastGather.time < 5 then
      local name = lastGather.name
      lastGather = nil
      if ns.OnGatherLoot then ns.OnGatherLoot(name) end
      local known = ns.NODES[name] and ns.NODES[name].item > 0
      if not known and not ns.db.icons[name] and GetLootSlotInfo then
        local icon = GetLootSlotInfo(1)
        if icon then
          ns.db.icons[name] = icon
          iconCache[name] = nil
        end
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Settings changes and slash command
---------------------------------------------------------------------------

function ns.Set(key, value)
  ns.db[key] = value
  if (key == "scan" or key == "disableScan") and ns.db.scan and not ns.db.disableScan and ns.ResetScanner then ns.ResetScanner() end
  if (key == "scan" or key == "disableScan" or key == "enabled") and ns.SyncScanner then ns.SyncScanner() end
  if key == "learnHover" or key == "disableScan" then SyncWatcher() end
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
  if ns.RefreshPins then ns.RefreshPins() end
  if key == "tracker" and ns.TrackerSettingsChanged then ns.TrackerSettingsChanged() end
  if key == "worldMark" and ns.WorldMarkChanged then ns.WorldMarkChanged() end
  if (key == "autoShine" or key == "worldMark" or key == "shineRange" or key == "hideAbove" or key == "hideGrey") and ns.ShineChanged then ns.ShineChanged() end
  if (key == "shineRange" or key == "shineAnim") and ns.SparkleChanged then ns.SparkleChanged() end
  if key:find("^glow") and ns.GlowChanged then ns.GlowChanged(key) end
end

function ns.SetNameShown(name, on)
  ns.db.hidden[name] = (not on) or nil
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
  if ns.RefreshPins then ns.RefreshPins() end
  if ns.ShineChanged then ns.ShineChanged() end
end

function ns.SetCategoryShown(category, on)
  for _, name in ipairs(ns.NamesFor(category)) do ns.db.hidden[name] = (not on) or nil end
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
  if ns.RefreshPins then ns.RefreshPins() end
  if ns.ShineChanged then ns.ShineChanged() end
end

SLASH_GATHERLABELS1 = "/glabels"
SLASH_GATHERLABELS2 = "/gatherlabels"
SlashCmdList.GATHERLABELS = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "minimap" then
    ns.SetMinimapShown(ns.db.minimapHidden)
  elseif msg == "on" or msg == "off" then
    ns.Set("enabled", msg == "on")
    ns.Print("Minimap icons " .. (msg == "on" and "on." or "off."))
  elseif msg == "route" then
    ns.StartRoute()
  elseif msg == "stop" then
    ns.StopRoute()
  elseif msg == "zone" then
    if ns.ShowZoneTab then ns.ShowZoneTab() end
  elseif msg == "shine" then
    ns.ToggleShine()
  elseif msg == "glow" then
    ns.Set("glow", not ns.db.glow)
    ns.Print("Close-up glow " .. (ns.db.glow and "on." or "off."))
  elseif msg == "glow debug" or msg == "glowdebug" then
    ns.GlowDebug()
  elseif msg == "glow test" or msg == "glow preview" then
    ns.GlowPreview()
  elseif msg == "session" then
    ns.Set("tracker", not ns.db.tracker)
  elseif msg == "reset" then
    ns.ResetSession()
  elseif msg == "scantest" then
    ns.ScanTest()
  elseif msg == "scanmode direct" or msg == "scanmode move" then
    ns.Set("scanMode", msg:match("(%a+)$"))
    ns.Print("Scan mode: " .. ns.db.scanMode .. ".")
  elseif msg == "help" then
    ns.Print("/glabels opens Settings. /glabels on|off shows or hides the icons. "
      .. "/glabels minimap shows or hides the minimap button. "
      .. "/glabels zone shows herbs, ore and fish in this zone. "
      .. "/glabels route starts a farming route in this zone, /glabels stop ends it. "
      .. "/glabels session shows or hides the session tracker, /glabels reset starts a new session. "
      .. "/glabels shine turns the sparkle on the nearest node on or off. "
      .. "/glabels glow turns the close-up glow on or off, /glabels glow test shows it, /glabels glow debug says what it sees.")
  else
    ns.ToggleSettings()
  end
end
