local _, ns = ...

-- The arrow and the farming route.
--   Arrow: click an icon on the minimap and an arrow on screen points to it,
--   with its name and distance. It goes away when you get there.
--   Farming route: a loop through every saved spot in your zone (only the
--   nodes ticked in Settings), in a short order. The arrow leads you from
--   one stop to the next and the route is drawn on the minimap. On WoW
--   Forever, a stop whose node is gone (no dot when you get close) is
--   skipped.

local ARRIVE = 10      -- yards: close enough to count as there
local SKIP_SCANS = 2   -- Forever: scans in a row with no dot at a near stop before skipping it
local TWO_OPT_PASSES = 20

local wait = 0 -- seconds until the next arrow/route update
local target -- { continent, x, y, name, cave } the arrow points at
local route  -- { continent, stops = { { x, y, name } }, index, missing }

---------------------------------------------------------------------------
-- Arrow on screen
---------------------------------------------------------------------------

local arrow = CreateFrame("Frame", "GatherLabelsArrow", UIParent)
arrow:SetSize(140, 110)
arrow:SetFrameStrata("HIGH")
arrow:SetMovable(true)
arrow:SetClampedToScreen(true)
arrow:EnableMouse(true)
arrow:RegisterForDrag("LeftButton")
arrow:Hide()

arrow.pointer = arrow:CreateTexture(nil, "ARTWORK")
arrow.pointer:SetTexture("Interface\\Minimap\\MinimapArrow")
arrow.pointer:SetSize(56, 56)
arrow.pointer:SetPoint("TOP", 0, 0)

arrow.icon = arrow:CreateTexture(nil, "ARTWORK")
arrow.icon:SetSize(16, 16)
arrow.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
arrow.name = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
arrow.name:SetPoint("TOP", arrow.pointer, "BOTTOM", 9, -2)
arrow.icon:SetPoint("RIGHT", arrow.name, "LEFT", -4, 0)
arrow.info = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
arrow.info:SetPoint("TOP", arrow.name, "BOTTOM", -9, -2)

local function PlaceArrow()
  arrow:ClearAllPoints()
  local p = ns.db and ns.db.arrowPoint
  if p then
    arrow:SetPoint(p[1], UIParent, p[1], p[2], p[3])
  else
    arrow:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
end

arrow:SetScript("OnDragStart", arrow.StartMoving)
arrow:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, _, x, y = self:GetPoint(1)
  ns.db.arrowPoint = { point, x, y }
end)
arrow:SetScript("OnMouseUp", function(_, button)
  if button == "RightButton" then
    if route then ns.StopRoute() else ns.ClearTarget() end
  end
end)
arrow:SetScript("OnEnter", function(self)
  ns.Skin.ClickTip(self, "Gather Labels", {
    { "Right-click", route and "Stop the farming route" or "Hide the arrow" },
    { "Drag", "Move the arrow" },
  }, "ANCHOR_BOTTOM")
end)
arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)

function ns.SetTarget(x, y, name, cave)
  local continent = ns.PlayerWorldPos()
  if not continent or not x then return end
  target = { continent = continent, x = x, y = y, name = name, cave = cave }
  PlaceArrow()
  arrow.icon:SetTexture(ns.Icon(name))
  arrow.name:SetText(name)
  arrow.info:SetText("")
  arrow.lastText = nil
  wait = 0
  arrow:Show()
  if ns.MarkInWorld then ns.MarkInWorld(continent, x, y, true) end
end

function ns.ClearTarget()
  target = nil
  arrow:Hide()
  if ns.UnmarkInWorld then ns.UnmarkInWorld() end
end

function ns.TargetName()
  return target and target.name
end

function ns.RemarkTarget()
  if target and ns.MarkInWorld then ns.MarkInWorld(target.continent, target.x, target.y, true) end
end

---------------------------------------------------------------------------
-- Farming route
---------------------------------------------------------------------------

local function Dist(a, b)
  return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- The zone you're in (not a cave or building inside it).
local function ZoneMap()
  local mapID = C_Map.GetBestMapForUnit("player")
  local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
  while mapID and C_Map.GetMapInfo do
    local info = C_Map.GetMapInfo(mapID)
    if not info or info.mapType <= zoneType or not info.parentMapID or info.parentMapID == 0 then break end
    mapID = info.parentMapID
  end
  return mapID
end
ns.ZoneMap = ZoneMap

local function InZone(continent, mapID, x, y)
  if not (C_Map.GetMapPosFromWorldPos and CreateVector2D and mapID) then return true end
  local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, CreateVector2D(x, y), mapID)
  if not ok or not pos then return false end
  local mx, my = pos:GetXY()
  return mx >= 0 and mx <= 1 and my >= 0 and my <= 1
end

-- Nearest stop next from where you stand, then 2-opt: undo any two legs
-- that cross, which shortens the loop.
local function Order(stops, start)
  local left, ordered, here = {}, {}, start
  for i, s in ipairs(stops) do left[i] = s end
  while #left > 0 do
    local best, bestDist = 1, math.huge
    for i, s in ipairs(left) do
      local d = Dist(here, s)
      if d < bestDist then best, bestDist = i, d end
    end
    here = table.remove(left, best)
    ordered[#ordered + 1] = here
  end
  local n = #ordered
  if n < 4 then return ordered end
  for _ = 1, TWO_OPT_PASSES do
    local improved = false
    for i = 1, n - 2 do
      for j = i + 2, n do
        local a, b = ordered[i], ordered[i + 1]
        local c, d = ordered[j], ordered[j % n + 1]
        if d ~= a and Dist(a, c) + Dist(b, d) < Dist(a, b) + Dist(c, d) - 0.01 then
          local lo, hi = i + 1, j
          while lo < hi do
            ordered[lo], ordered[hi] = ordered[hi], ordered[lo]
            lo, hi = lo + 1, hi - 1
          end
          improved = true
        end
      end
    end
    if not improved then break end
  end
  return ordered
end

local function RouteLength(stops)
  local total = 0
  for i = 1, #stops do total = total + Dist(stops[i], stops[i % #stops + 1]) end
  return total
end

ns.OrderStops = Order
ns.RouteLength = RouteLength

local function PointArrowAtStop()
  local stop = route.stops[route.index]
  ns.SetTarget(stop.x, stop.y, stop.name, stop.cave)
end

function ns.RouteActive()
  return route ~= nil
end

function ns.CurrentRoute()
  return route
end

function ns.StartRoute()
  local continent, px, py = ns.PlayerWorldPos()
  if not continent then
    ns.Print("Can't make a route here (the game doesn't give your position).")
    return
  end
  local mapID = ZoneMap()
  local stops = {}
  for _, list in pairs(ns.db.spots[continent] or {}) do
    for _, spot in ipairs(list) do
      local name = ns.ShownName(spot)
      if name and InZone(continent, mapID, spot.x, spot.y) then
        stops[#stops + 1] = { x = spot.x, y = spot.y, name = name, cave = spot.cave }
      end
    end
  end
  if #stops < 2 then
    ns.Print("Not enough saved spots in this zone for a route yet (found " .. #stops
      .. "). Gather around for a while, then try again.")
    return
  end
  stops = Order(stops, { x = px, y = py })
  route = { continent = continent, stops = stops, index = 1, missing = 0 }
  PointArrowAtStop()
  ns.Print(string.format("Farming route: %d stops, about %d yards a lap. Follow the arrow; right-click it to stop.",
    #stops, RouteLength(stops)))
  if ns.RefreshMap then ns.RefreshMap() end
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
end

function ns.StopRoute()
  route = nil
  ns.ClearTarget()
  if ns.RefreshMap then ns.RefreshMap() end
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
end

local function NextStop()
  route.index = route.index % #route.stops + 1
  route.missing = 0
  PointArrowAtStop()
  if ns.RefreshMap then ns.RefreshMap() end
end

-- Forever: a near stop with no dot on the minimap has been picked already.
local lastScans
local function CheckSkip(stop, dist)
  if not (ns.ScannerRunning and ns.ScannerRunning()) or ns.liveScans == lastScans then return end
  lastScans = ns.liveScans
  if dist > ns.MinimapRadius() * 0.7 then route.missing = 0 return end
  for _, dot in ipairs(ns.liveDots or {}) do
    if (dot.x - stop.x) ^ 2 + (dot.y - stop.y) ^ 2 < 225 then route.missing = 0 return end
  end
  route.missing = route.missing + 1
  if route.missing >= SKIP_SCANS then NextStop() end
end

---------------------------------------------------------------------------
-- Route on the minimap
---------------------------------------------------------------------------

local overlay = CreateFrame("Frame", nil, Minimap)
overlay:SetAllPoints()
overlay:SetFrameLevel(Minimap:GetFrameLevel() + 1)
local lines, linesUsed = {}, 0

local function GetLine()
  linesUsed = linesUsed + 1
  local line = lines[linesUsed]
  if not line then
    line = overlay:CreateLine(nil, "ARTWORK")
    line:SetThickness(2)
    lines[linesUsed] = line
  end
  return line
end

-- Cut a segment to the minimap's round (or square) edge. Nil when it is
-- all outside.
local function Clip(x1, y1, x2, y2, r, square)
  local dx, dy = x2 - x1, y2 - y1
  local t0, t1 = 0, 1
  if square then
    -- the four edges, one after the other (no tables made per segment)
    for k = 1, 4 do
      local p, q
      if k == 1 then p, q = -dx, x1 + r
      elseif k == 2 then p, q = dx, r - x1
      elseif k == 3 then p, q = -dy, y1 + r
      else p, q = dy, r - y1 end
      if p == 0 then
        if q < 0 then return end
      else
        local t = q / p
        if p < 0 then t0 = math.max(t0, t) else t1 = math.min(t1, t) end
      end
    end
  else
    local a = dx * dx + dy * dy
    if a == 0 then return end
    local b = 2 * (x1 * dx + y1 * dy)
    local c = x1 * x1 + y1 * y1 - r * r
    local disc = b * b - 4 * a * c
    if disc <= 0 then return end
    local s = math.sqrt(disc)
    t0, t1 = math.max(0, (-b - s) / (2 * a)), math.min(1, (-b + s) / (2 * a))
  end
  if t0 >= t1 then return end
  return x1 + dx * t0, y1 + dy * t0, x1 + dx * t1, y1 + dy * t1
end

-- What the route was last drawn for: nothing changed, nothing to redraw.
local drawn = {}

local function DrawRoute(continent, px, py, facing)
  local radius = continent and ns.MinimapRadius()
  local half = Minimap:GetWidth() / 2
  local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
  local enabled = ns.db and ns.db.enabled
  local d = drawn
  if d.route == route and d.index == (route and route.index) and d.n == (route and #route.stops)
      and d.continent == continent and d.px == px and d.py == py and d.facing == facing
      and d.radius == radius and d.half == half and d.square == square and d.enabled == enabled then
    return
  end
  d.route, d.index, d.n = route, route and route.index, route and #route.stops
  d.continent, d.px, d.py, d.facing = continent, px, py, facing
  d.radius, d.half, d.square, d.enabled = radius, half, square, enabled
  linesUsed = 0
  if route and route.continent == continent and enabled then
    local pixelsPerYard = half / radius
    local cos, sin = math.cos(facing), math.sin(facing)
    local n = #route.stops
    for i = 1, n do
      local a, b = route.stops[i], route.stops[i % n + 1]
      local na, ea = a.x - px, py - a.y
      local nb, eb = b.x - px, py - b.y
      local x1, y1 = (ea * cos + na * sin) * pixelsPerYard, (na * cos - ea * sin) * pixelsPerYard
      local x2, y2 = (eb * cos + nb * sin) * pixelsPerYard, (nb * cos - eb * sin) * pixelsPerYard
      local cx1, cy1, cx2, cy2 = Clip(x1, y1, x2, y2, half - 2, square)
      if cx1 then
        local line = GetLine()
        -- The leg you're on now is brighter.
        local current = (i % n + 1) == route.index
        line:SetColorTexture(1, 0.82, 0, current and 0.95 or 0.45)
        line:SetStartPoint("CENTER", Minimap, cx1, cy1)
        line:SetEndPoint("CENTER", Minimap, cx2, cy2)
        line:Show()
      end
    end
  end
  for i = linesUsed + 1, #lines do lines[i]:Hide() end
end

---------------------------------------------------------------------------
-- Update loop
---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, elapsed)
  wait = wait - elapsed
  if wait > 0 then return end
  wait = 0.05
  if not ns.db then return end
  -- Nothing to point at and no route: rest.
  if not target and not route then
    if linesUsed > 0 then DrawRoute(nil) end
    wait = 0.5
    return
  end
  local continent, px, py = ns.PlayerWorldPos()
  local facing = GetPlayerFacing and GetPlayerFacing()
  local mapFacing = ns.MinimapFacing()
  if continent and mapFacing and Minimap:IsVisible() then
    DrawRoute(continent, px, py, mapFacing)
  else
    DrawRoute(nil)
  end

  if not target then return end
  if not continent or continent ~= target.continent or not facing then
    arrow.pointer:SetAlpha(0.3)
    arrow.lastText = nil
    arrow.info:SetText("No direction here")
    return
  end
  local north, west = target.x - px, target.y - py
  local dist = math.sqrt(north * north + west * west)
  if dist <= ARRIVE then
    if route then
      NextStop()
    else
      ns.ClearTarget()
    end
    return
  end
  if route then CheckSkip(route.stops[route.index], dist) end
  arrow.pointer:SetAlpha(1)
  -- Bearing like GetPlayerFacing: 0 is north, turning towards west.
  arrow.pointer:SetRotation(math.atan2(west, north) - facing)
  local text = string.format("%d yards", dist)
  -- Forever: the minimap says whether the node is above or below you.
  local live = ns.liveContinent == continent and ns.liveDots
  if live then
    for _, dot in ipairs(live) do
      if dot.level and (dot.x - target.x) ^ 2 + (dot.y - target.y) ^ 2 < 225 then
        text = text .. (dot.level == "above" and ", above you" or ", below you")
        break
      end
    end
  end
  if target.cave then text = text .. ", in a cave" end
  if route then text = text .. string.format("   stop %d of %d", route.index, #route.stops) end
  if text ~= arrow.lastText then
    arrow.lastText = text
    arrow.info:SetText(text)
  end
end)
