local _, ns = ...

-- World Map overlay: optional node pins and gathering route path.
-- Off by default (db.mapEnabled = false, db.mapRoute = false).
-- Nodes shown on the World Map follow the checkboxes in Herbs & Ore and
-- Fishing & Treasure, plus the red/grey skill filters in Settings (ns.IsDrawn).

local RING_TEX = "Interface\\AddOns\\GatherLabels\\Media\\Ring"
local RING_COLORS = {
  herb = { 0.35, 0.95, 0.35 },
  ore = { 1.0, 0.78, 0.25 },
  fish = { 0.35, 0.85, 1.0 },
  treasure = { 1.0, 0.85, 0.35 },
}

local overlay, routeLayer
local hooked = false
local dirty = true
local cacheVersion = 0
local lastMapID, lastW, lastH, lastScale
local wait = 0

local pins, pinsUsed = {}, 0
local lines, linesUsed = {}, 0
local badges, badgesUsed = {}, 0

local zoneSpots = {}
local previewCache = { mapID = nil, version = -1, stops = nil }

local centerVec, scratchVec
local tooltipNames, tooltipSeen = {}, {}
local activeSeen

local function CompareNames(a, b)
  local ta, tb = activeSeen[a] or 0, activeSeen[b] or 0
  if ta ~= tb then return ta > tb end
  return a < b
end

local function CollectSpotNames(spot, out, seen)
  wipe(out)
  wipe(seen)
  if spot and spot.n then
    for name, t in pairs(spot.n) do
      if ns.IsDrawn(name) then
        out[#out + 1] = name
        seen[name] = t or 1
      end
    end
  end
  activeSeen = seen
  table.sort(out, CompareNames)
  return out
end

local function ColorName(name)
  local _, have, color = ns.SkillInfo(name)
  return have and ("|cff" .. color .. name .. "|r") or name
end

local function MapFeatureEnabled()
  local db = ns.db
  return db ~= nil and (db.mapEnabled or db.mapRoute)
end

local function GetCanvas()
  if not WorldMapFrame then return nil end
  if WorldMapFrame.GetCanvas then
    local ok, c = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
    if ok and c then return c end
  end
  if WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child then
    return WorldMapFrame.ScrollContainer.Child
  end
  return WorldMapDetailFrame
end

local function GetCanvasScale()
  if WorldMapFrame then
    if WorldMapFrame.GetCanvasScale then
      local ok, s = pcall(WorldMapFrame.GetCanvasScale, WorldMapFrame)
      if ok and type(s) == "number" and s > 0 then return s end
    end
    if WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.GetCanvasScale then
      local ok, s = pcall(WorldMapFrame.ScrollContainer.GetCanvasScale, WorldMapFrame.ScrollContainer)
      if ok and type(s) == "number" and s > 0 then return s end
    end
  end
  return 1
end

local function IsZoneOrSubzone(mapID)
  if not mapID or not (C_Map and C_Map.GetMapInfo) then return false end
  local ok, info = pcall(C_Map.GetMapInfo, mapID)
  if not ok or not info or not info.mapType then return false end
  local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
  return info.mapType >= zoneType
end

local function MapContinent(mapID)
  if not mapID or not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
  if not centerVec then centerVec = CreateVector2D(0.5, 0.5) end
  local ok, continent = pcall(C_Map.GetWorldPosFromMapPos, mapID, centerVec)
  if ok and continent then return continent end
  return nil
end

local function WorldToMap(continent, x, y, mapID)
  if not (C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
  local vec
  if not scratchVec then scratchVec = CreateVector2D(x, y) end
  if scratchVec.SetXY then
    scratchVec:SetXY(x, y)
    vec = scratchVec
  else
    vec = CreateVector2D(x, y)
  end
  local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, vec, mapID)
  if not ok or not pos or not pos.GetXY then return nil end
  local mx, my = pos:GetXY()
  if mx and my and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then
    return mx, my
  end
end

local function CollectTrackedSpotsForMap(mapID, continent, out)
  wipe(out)
  local db = ns.db
  if not db or not db.spots or not continent or not ns.ShownName then return out end
  local cells = db.spots[continent]
  if not cells then return out end
  for _, list in pairs(cells) do
    for i = 1, #list do
      local spot = list[i]
      local name = ns.ShownName(spot)
      if name then
        local mx, my = WorldToMap(continent, spot.x, spot.y, mapID)
        if mx then
          out[#out + 1] = {
            x = spot.x,
            y = spot.y,
            mx = mx,
            my = my,
            name = name,
            spot = spot,
            cave = spot.cave,
          }
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Pooled pins, route lines and stop number badges
---------------------------------------------------------------------------

local function PinOnEnter(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  local names = CollectSpotNames(self.spot, tooltipNames, tooltipSeen)
  if #names == 0 and self.name then names[1] = self.name end
  for i, name in ipairs(names) do
    local icon = ns.Icon(name)
    local text = icon and ("|T" .. icon .. ":0|t " .. name) or name
    if i == 1 then GameTooltip:SetText(text) else GameTooltip:AddLine(text, 1, 1, 1) end
    local skill = ns.SkillText and ns.SkillText(name)
    if skill then GameTooltip:AddLine("   " .. skill) end
  end
  if self.spot and self.spot.cave then
    GameTooltip:AddLine("In a cave or building", 0.8, 0.6, 0.4)
  end
  local playerContinent = ns.PlayerWorldPos and ns.PlayerWorldPos()
  if playerContinent and playerContinent == self.continent then
    GameTooltip:AddLine("Click: show an arrow to it", 0.5, 0.8, 1)
  end
  if #names > 1 then
    GameTooltip:AddLine("Different nodes can spawn here.", 0.6, 0.6, 0.6, true)
  end
  GameTooltip:Show()
end

local function PinOnLeave()
  if GameTooltip then GameTooltip:Hide() end
end

local function PinOnMouseUp(self, button)
  if button == "LeftButton" and ns.SetTarget then
    local playerContinent = ns.PlayerWorldPos and ns.PlayerWorldPos()
    if playerContinent and playerContinent == self.continent then
      ns.SetTarget(self.wx, self.wy, self.name, self.spot and self.spot.cave)
    end
  elseif button == "RightButton" and WorldMapFrame and WorldMapFrame.NavigateToParentMap then
    pcall(WorldMapFrame.NavigateToParentMap, WorldMapFrame)
  end
end

local function GetPin()
  pinsUsed = pinsUsed + 1
  local pin = pins[pinsUsed]
  if not pin then
    pin = CreateFrame("Frame", nil, overlay)
    pin:SetFrameLevel((overlay:GetFrameLevel() or 1) + 5)
    pin:EnableMouse(true)

    pin.bg = pin:CreateTexture(nil, "BACKGROUND")
    pin.bg:SetPoint("TOPLEFT", -1, 1)
    pin.bg:SetPoint("BOTTOMRIGHT", 1, -1)
    pin.bg:SetColorTexture(0, 0, 0, 0.65)

    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints()
    pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    pin.ring = pin:CreateTexture(nil, "ARTWORK")
    pin.ring:SetAllPoints()
    pin.ring:SetTexture(RING_TEX)
    pin.ring:Hide()

    pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pin.label:SetPoint("LEFT", pin, "RIGHT", 3, 0)
    pin.label:SetShadowOffset(1, -1)
    pin.label:Hide()

    pin:SetScript("OnEnter", PinOnEnter)
    pin:SetScript("OnLeave", PinOnLeave)
    pin:SetScript("OnMouseUp", PinOnMouseUp)
    pins[pinsUsed] = pin
  end
  return pin
end

local function GetLine()
  linesUsed = linesUsed + 1
  local line = lines[linesUsed]
  if not line then
    line = routeLayer:CreateLine(nil, "ARTWORK")
    lines[linesUsed] = line
  end
  return line
end

local function GetBadge()
  badgesUsed = badgesUsed + 1
  local badge = badges[badgesUsed]
  if not badge then
    badge = CreateFrame("Frame", nil, overlay)
    badge:SetSize(18, 14)
    badge:SetFrameLevel((overlay:GetFrameLevel() or 1) + 8)
    badge:EnableMouse(false)

    badge.bg = badge:CreateTexture(nil, "BACKGROUND")
    badge.bg:SetAllPoints()
    badge.bg:SetColorTexture(0.05, 0.04, 0.03, 0.8)

    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badge.text:SetPoint("CENTER", 0, 0)
    badge.text:SetShadowOffset(1, -1)
    badges[badgesUsed] = badge
  end
  return badge
end

local function HideAll()
  for i = 1, #pins do pins[i]:Hide() end
  for i = 1, #lines do lines[i]:Hide() end
  for i = 1, #badges do badges[i]:Hide() end
  pinsUsed, linesUsed, badgesUsed = 0, 0, 0
end

---------------------------------------------------------------------------
-- Drawing pins and route on the World Map
---------------------------------------------------------------------------

local function ResolveRouteStops(mapID, continent, spots)
  local db = ns.db
  if not db or not db.mapRoute then return nil, false, nil end

  -- 1. Active farming route if it belongs to the continent/zone being viewed.
  local active = ns.CurrentRoute and ns.CurrentRoute()
  if active and active.continent == continent and active.stops and #active.stops >= 2 then
    local projected = {}
    local activeIdx = nil
    for i = 1, #active.stops do
      local s = active.stops[i]
      local mx, my = WorldToMap(continent, s.x, s.y, mapID)
      if mx then
        projected[#projected + 1] = { x = s.x, y = s.y, mx = mx, my = my, name = s.name, origIndex = i }
        if i == active.index then activeIdx = #projected end
      end
    end
    if #projected >= 2 then
      return projected, true, activeIdx
    end
  end

  -- 2. Optional preview route for any viewed zone even when stopped.
  if not db.mapRouteAlways or #spots < 2 or not ns.OrderStops then
    return nil, false, nil
  end
  if previewCache.mapID == mapID and previewCache.version == cacheVersion then
    return previewCache.stops, false, nil
  end
  local start = spots[1]
  local pc, px, py = ns.PlayerWorldPos and ns.PlayerWorldPos()
  if pc and pc == continent and px and py then
    start = { x = px, y = py }
  end
  local ordered = ns.OrderStops(spots, start)
  previewCache.mapID = mapID
  previewCache.version = cacheVersion
  previewCache.stops = ordered
  return ordered, false, nil
end

local function Redraw()
  if not overlay or not overlay:IsShown() then return end
  local db = ns.db
  if not db or not MapFeatureEnabled() then
    HideAll()
    overlay:Hide()
    return
  end

  local mapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
  local w, h = overlay:GetWidth() or 0, overlay:GetHeight() or 0
  local scale = GetCanvasScale()
  if not dirty and mapID == lastMapID and w == lastW and h == lastH and scale == lastScale then
    return
  end
  dirty = false
  lastMapID, lastW, lastH, lastScale = mapID, w, h, scale

  pinsUsed, linesUsed, badgesUsed = 0, 0, 0
  if not mapID or w <= 0 or h <= 0 or not IsZoneOrSubzone(mapID) then
    HideAll()
    return
  end

  local continent = MapContinent(mapID)
  if not continent then
    HideAll()
    return
  end

  local spots = CollectTrackedSpotsForMap(mapID, continent, zoneSpots)
  local invScale = 1 / scale

  -- Draw node pins when enabled.
  if db.mapEnabled then
    local size = tonumber(db.mapIconSize) or 14
    local alpha = (tonumber(db.mapAlpha) or 90) / 100
    local useRings = db.mapRings and true or false
    local showLabels = db.mapLabels and true or false

    for i = 1, #spots do
      local s = spots[i]
      local pin = GetPin()
      pin.spot = s.spot
      pin.name = s.name
      pin.wx, pin.wy = s.x, s.y
      pin.continent = continent
      pin:SetScale(invScale)
      pin:SetSize(useRings and math.max(size + 2, 14) or size, useRings and math.max(size + 2, 14) or size)
      pin:SetAlpha(alpha)
      pin:ClearAllPoints()
      pin:SetPoint("CENTER", overlay, "TOPLEFT", (s.mx * w) / invScale, -(s.my * h) / invScale)

      if useRings then
        local cat = ns.Category(s.name) or (s.spot and s.spot.c) or "herb"
        local c = RING_COLORS[cat] or RING_COLORS.herb
        pin.bg:Hide()
        pin.icon:Hide()
        pin.ring:SetVertexColor(c[1], c[2], c[3], 1)
        pin.ring:Show()
      else
        pin.ring:Hide()
        pin.bg:Show()
        pin.icon:SetTexture(ns.Icon(s.name))
        pin.icon:Show()
      end

      if showLabels then
        local lbl = ColorName(s.name)
        if s.cave then lbl = lbl .. " |cffc8a070(cave)|r" end
        pin.label:SetText(lbl)
        pin.label:Show()
      else
        pin.label:Hide()
      end
      pin:Show()
    end
  end

  -- Draw gathering route path when enabled.
  if db.mapRoute then
    local routeStops, isActive, activeIdx = ResolveRouteStops(mapID, continent, spots)
    if routeStops and #routeStops >= 2 then
      local baseWidth = tonumber(db.mapRouteWidth) or 2
      local routeAlpha = (tonumber(db.mapRouteAlpha) or 75) / 100
      local n = #routeStops
      for i = 1, n do
        local a = routeStops[i]
        local b = routeStops[i % n + 1]
        local line = GetLine()
        local isCurrentLeg = isActive and activeIdx and ((i % n + 1) == activeIdx)
        line:SetThickness((isCurrentLeg and (baseWidth * 1.4) or baseWidth) / scale)
        if isActive then
          line:SetColorTexture(1, isCurrentLeg and 0.9 or 0.78, isCurrentLeg and 0.15 or 0.1,
            isCurrentLeg and math.min(1, routeAlpha + 0.2) or (routeAlpha * 0.7))
        else
          line:SetColorTexture(0.35, 0.88, 0.95, routeAlpha * 0.85)
        end
        line:SetStartPoint("TOPLEFT", routeLayer, a.mx * w, -a.my * h)
        line:SetEndPoint("TOPLEFT", routeLayer, b.mx * w, -b.my * h)
        line:Show()
      end

      if db.mapRouteNumbers then
        for i = 1, n do
          local s = routeStops[i]
          local badge = GetBadge()
          badge:SetScale(invScale)
          badge:ClearAllPoints()
          badge:SetPoint("BOTTOMLEFT", overlay, "TOPLEFT", (s.mx * w) / invScale + 4, -(s.my * h) / invScale + 4)
          local isNext = isActive and activeIdx == i
          if isNext then
            badge.text:SetText("|cffffd100" .. i .. "|r")
          else
            badge.text:SetText("|cffffffff" .. i .. "|r")
          end
          badge:SetWidth(math.max(16, (badge.text:GetStringWidth() or 8) + 8))
          badge:Show()
        end
      end
    end
  end

  for i = pinsUsed + 1, #pins do pins[i]:Hide() end
  for i = linesUsed + 1, #lines do lines[i]:Hide() end
  for i = badgesUsed + 1, #badges do badges[i]:Hide() end
end

local function TargetFrameLevel(canvas)
  local base = (canvas:GetFrameLevel() or 1) + 10
  local mgr = WorldMapFrame and WorldMapFrame.pinFrameLevelsManager
  if mgr and mgr.GetValidFrameLevel then
    local best = base
    for _, key in ipairs({ "PIN_FRAME_LEVEL_MAP_EXPLORATION", "PIN_FRAME_LEVEL_MAP_HIGHLIGHT", "PIN_FRAME_LEVEL_AREA_POI" }) do
      local ok, lvl = pcall(mgr.GetValidFrameLevel, mgr, key)
      if ok and type(lvl) == "number" and lvl > best then best = lvl end
    end
    if best > base then
      local want = best + 25
      local okP, playerLvl = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_PLAYER")
      if okP and type(playerLvl) == "number" and playerLvl > best + 10 then
        want = math.min(want, playerLvl - 10)
      end
      return want
    end
  end
  return math.max(base, 2200)
end

local function SyncFrameLevels()
  if not overlay then return end
  local canvas = GetCanvas()
  if not canvas then return end
  local lvl = TargetFrameLevel(canvas)
  overlay:SetFrameLevel(lvl)
  if routeLayer then routeLayer:SetFrameLevel(lvl + 2) end
  for i = 1, #pins do pins[i]:SetFrameLevel(lvl + 5) end
  for i = 1, #badges do badges[i]:SetFrameLevel(lvl + 8) end
end

local function EnsureOverlay()
  if overlay then return true end
  local canvas = GetCanvas()
  if not canvas then return false end
  overlay = CreateFrame("Frame", "GatherLabelsMapOverlay", canvas)
  overlay:SetAllPoints(canvas)
  overlay:EnableMouse(false)
  overlay:Hide()

  routeLayer = CreateFrame("Frame", nil, overlay)
  routeLayer:SetAllPoints(overlay)
  routeLayer:EnableMouse(false)
  SyncFrameLevels()

  overlay:SetScript("OnUpdate", function(_, elapsed)
    wait = wait + elapsed
    if wait < 0.08 then return end
    wait = 0
    Redraw()
  end)
  return true
end

local function SyncVisibility()
  if not WorldMapFrame then return end
  if not MapFeatureEnabled() then
    if overlay then
      HideAll()
      overlay:Hide()
    end
    return
  end
  if not EnsureOverlay() then return end
  SyncFrameLevels()
  if WorldMapFrame:IsShown() then
    overlay:Show()
    dirty = true
    Redraw()
  else
    overlay:Hide()
  end
end

local function EnsureHooks()
  if hooked or not WorldMapFrame then return end
  hooked = true
  WorldMapFrame:HookScript("OnShow", function()
    SyncVisibility()
  end)
  WorldMapFrame:HookScript("OnHide", function()
    if overlay then overlay:Hide() end
  end)
  if WorldMapFrame.OnMapChanged then
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
      dirty = true
      if overlay and overlay:IsShown() then Redraw() end
    end)
  end
  if WorldMapFrame.SetMapID then
    hooksecurefunc(WorldMapFrame, "SetMapID", function()
      dirty = true
      if overlay and overlay:IsShown() then Redraw() end
    end)
  end
end

function ns.RefreshMap()
  cacheVersion = cacheVersion + 1
  dirty = true
  EnsureHooks()
  SyncVisibility()
end

-- Live summary for the Map settings tab.
function ns.MapZoneStats()
  local mapID = ns.ZoneMap and ns.ZoneMap()
  local continent = ns.PlayerWorldPos and ns.PlayerWorldPos()
  if not continent and mapID then continent = MapContinent(mapID) end
  local tracked = 0
  if mapID and continent then
    local temp = CollectTrackedSpotsForMap(mapID, continent, {})
    tracked = #temp
  end
  local active = ns.CurrentRoute and ns.CurrentRoute()
  local routeStops = active and active.stops and #active.stops or 0
  return tracked, routeStops
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:RegisterEvent("ADDON_LOADED")
init:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LOGIN" or arg1 == "Blizzard_WorldMap" then
    EnsureHooks()
    SyncVisibility()
  end
end)
