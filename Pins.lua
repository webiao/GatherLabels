local _, ns = ...

-- Draws an icon (or hollow ring for saved spots) and label on the minimap for
-- every live dot or saved spot in range, clustering overlapping spots.

local RING_TEX = "Interface\\AddOns\\GatherLabels\\Media\\Ring"
local COVER_DIST_SQ = 225 -- 15 yards
local RING_COLORS = {
  herb = { 0.35, 0.95, 0.35 },
  ore = { 1.0, 0.78, 0.25 },
  fish = { 0.35, 0.85, 1.0 },
  treasure = { 1.0, 0.85, 0.35 },
}

local pins, used = {}, 0

-- Module-level scratch tables for tooltip and label collection (zero per-frame GC).
local tooltipNames, tooltipSeen = {}, {}
local labelNames, labelSeen = {}, {}
local activeSeen

local function CompareCollectedNames(a, b)
  local ta, tb = activeSeen[a] or 0, activeSeen[b] or 0
  if ta ~= tb then return ta > tb end
  return a < b
end

local function CollectSpotNames(spot, extraNames, out, seen)
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
  if extraNames then
    for name, t in pairs(extraNames) do
      if ns.IsDrawn(name) then
        local prev = seen[name]
        if not prev then
          out[#out + 1] = name
          seen[name] = t or 1
        elseif (t or 1) > prev then
          seen[name] = t or 1
        end
      end
    end
  end
  activeSeen = seen
  table.sort(out, CompareCollectedNames)
  return out
end

local function ColorName(name)
  local _, have, color = ns.SkillInfo(name)
  return have and ("|cff" .. color .. name .. "|r") or name
end

local function FormatLabel(primaryName, spot, extraNames)
  local names = CollectSpotNames(spot, extraNames, labelNames, labelSeen)
  local count = #names
  local first = primaryName
  if count >= 1 then
    if primaryName then
      for i = 2, count do
        if names[i] == primaryName then
          names[i] = names[1]
          names[1] = primaryName
          break
        end
      end
    end
    first = names[1]
  end
  if not first then return "" end
  local label
  if count >= 3 then
    label = ColorName(first) .. " |cffcccccc+" .. (count - 1) .. "|r"
  elseif count == 2 then
    label = ColorName(first) .. " / " .. ColorName(names[2])
  else
    label = ColorName(first)
  end
  if spot and spot.cave then
    label = label .. " |cffc8a070(cave)|r"
  end
  return label
end

local function PinOnEnter(self)
  GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
  local names = CollectSpotNames(self.spot, self.extraNames, tooltipNames, tooltipSeen)
  if #names == 0 and self.name then
    names[1] = self.name
  end
  for i, name in ipairs(names) do
    local icon = ns.Icon(name)
    local text = icon and ("|T" .. icon .. ":0|t " .. name) or name
    if i == 1 then GameTooltip:SetText(text) else GameTooltip:AddLine(text, 1, 1, 1) end
    local skill = ns.SkillText(name)
    if skill then GameTooltip:AddLine("   " .. skill) end
  end
  if self.level then GameTooltip:AddLine(self.level == "above" and "Above you" or "Below you", 1, 0.82, 0) end
  if self.spot and self.spot.cave then GameTooltip:AddLine("In a cave or building", 0.8, 0.6, 0.4) end
  GameTooltip:AddLine("Click: show an arrow to it", 0.5, 0.8, 1)
  if #names > 1 then
    GameTooltip:AddLine("Different nodes can spawn here.", 0.6, 0.6, 0.6, true)
  end
  GameTooltip:Show()
end

local function PinOnMouseUp(self, button)
  if button == "LeftButton" and ns.SetTarget then
    ns.SetTarget(self.wx, self.wy, self.name, self.spot and self.spot.cave)
  end
end

local function PinOnLeave()
  GameTooltip:Hide()
end

local function GetPin(i)
  local pin = pins[i]
  if pin then return pin end
  pin = CreateFrame("Frame", nil, Minimap)
  pin:SetFrameLevel(Minimap:GetFrameLevel() + 2)
  pin.icon = pin:CreateTexture(nil, "ARTWORK")
  pin.icon:SetAllPoints()
  pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  pin.ring = pin:CreateTexture(nil, "ARTWORK")
  pin.ring:SetAllPoints()
  pin.ring:SetTexture(RING_TEX)
  pin.ring:Hide()
  pin._useRing = false
  -- Brown frame: in a cave or building.
  pin.caveBorder = pin:CreateTexture(nil, "BACKGROUND")
  pin.caveBorder:SetPoint("TOPLEFT", -2, 2)
  pin.caveBorder:SetPoint("BOTTOMRIGHT", 2, -2)
  pin.caveBorder:SetColorTexture(0.55, 0.35, 0.15, 1)
  pin.caveBorder:Hide()
  pin._cave = false
  -- Small arrow in the corner: above or below you (the game's own arrows).
  pin.levelArrow = pin:CreateTexture(nil, "OVERLAY")
  pin.levelArrow:SetTexture("Interface\\Minimap\\Minimap-PositionArrows")
  pin.levelArrow:SetSize(12, 12)
  pin.levelArrow:SetPoint("CENTER", pin, "TOPRIGHT", 0, 0)
  pin.levelArrow:Hide()
  pin._level = false
  pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pin.label:SetPoint("LEFT", pin, "RIGHT", 2, 0)
  local font, size = pin.label:GetFont()
  pin.label:SetFont(font, (size or 10) - 1, "OUTLINE")
  pin.label:SetTextColor(1, 1, 1)
  pin.extraNames = {}
  pin:EnableMouse(true)
  pin:SetScript("OnEnter", PinOnEnter)
  pin:SetScript("OnMouseUp", PinOnMouseUp)
  pin:SetScript("OnLeave", PinOnLeave)
  pins[i] = pin
  return pin
end

-- Name to show for a spot: the node seen there last, unless it's switched
-- off, then the most recent one that is switched on.
local function ShownName(spot)
  if spot.last and spot.n[spot.last] and ns.IsDrawn(spot.last) then return spot.last end
  local best, bestTime
  for name, seen in pairs(spot.n) do
    if ns.IsDrawn(name) and (not bestTime or seen > bestTime) then best, bestTime = name, seen end
  end
  return best
end

ns.ShownName = ShownName

-- What Update() is drawing around right now; pooled tables prevent per-frame garbage.
local cur = {}
local candidates, candidatePool, numCandidates = {}, {}, 0
local clusterCells, clusterKeys, clusterKeyCount = {}, {}, 0

local function ToScreenInBounds(x, y)
  local c = cur
  local north, east = x - c.px, c.py - y
  local sx = (east * c.cos + north * c.sin) * c.pixelsPerYard
  local sy = (north * c.cos - east * c.sin) * c.pixelsPerYard
  local edge = c.edge
  if c.square then
    if math.abs(sx) <= edge and math.abs(sy) <= edge then return sx, sy end
  else
    if sx * sx + sy * sy <= edge * edge then return sx, sy end
  end
end

local function AddCandidate(x, y, name, spot, alpha, level, isLive)
  local sx, sy = ToScreenInBounds(x, y)
  if not sx then return end
  numCandidates = numCandidates + 1
  local entry = candidatePool[numCandidates]
  if not entry then
    entry = {}
    candidatePool[numCandidates] = entry
  end
  entry.x, entry.y, entry.sx, entry.sy = x, y, sx, sy
  entry.name, entry.spot, entry.alpha, entry.level, entry.isLive = name, spot, alpha, level, isLive
  candidates[numCandidates] = entry
end

local function IsCoveredBy(x, y, maxIndex)
  for i = 1, maxIndex do
    local c = candidates[i]
    local dx, dy = c.x - x, c.y - y
    if dx * dx + dy * dy < COVER_DIST_SQ then return true end
  end
  return false
end

local function MergeExtraNames(dst, c)
  if c.spot and c.spot.n then
    for n, seen in pairs(c.spot.n) do
      if ns.IsDrawn(n) then
        local prev = dst[n]
        if not prev or (seen or 1) > prev then dst[n] = seen or 1 end
      end
    end
  elseif c.name and ns.IsDrawn(c.name) then
    dst[c.name] = dst[c.name] or 1
  end
end

local function Update(continent, px, py, facing, radius)
  local db = ns.db
  if not db then return end
  used = 0
  numCandidates = 0
  if not (db.enabled and facing) then continent = nil end
  if continent then
    local half = Minimap:GetWidth() / 2
    cur.px, cur.py = px, py
    cur.pixelsPerYard = half / radius
    cur.square = GetMinimapShape and GetMinimapShape() == "SQUARE"
    cur.cos, cur.sin = math.cos(facing), math.sin(facing)
    cur.edge = half - db.iconSize / 2

    -- WoW Forever: the dots the scanner just read (Scan.lua).
    local live = ns.liveContinent == continent and ns.liveDots or nil
    local hasLive = live ~= nil and #live > 0
    if hasLive then
      for i = 1, #live do
        local dot = live[i]
        if ns.IsDrawn(dot.name) then
          AddCandidate(dot.x, dot.y, dot.name, dot.spot, 1, dot.level, true)
        end
      end
    end
    local liveEnd = numCandidates

    -- Saved spots: all of them when the scanner has no live dots; on Forever
    -- with live dots only if asked for, faded, and not where a dot was just read.
    local cells = db.spots[continent]
    if cells and (not hasLive or db.showSaved) then
      local alpha = hasLive and 0.5 or 1
      local cell = ns.CELL
      local minCX, maxCX = math.floor((px - radius) / cell), math.floor((px + radius) / cell)
      local minCY, maxCY = math.floor((py - radius) / cell), math.floor((py + radius) / cell)
      for i = minCX, maxCX do
        for j = minCY, maxCY do
          local list = cells[i .. ":" .. j]
          if list then
            for k = 1, #list do
              local spot = list[k]
              local name = ShownName(spot)
              if name and not IsCoveredBy(spot.x, spot.y, liveEnd) then
                AddCandidate(spot.x, spot.y, name, spot, alpha, nil, false)
              end
            end
          end
        end
      end
    end

    -- Cluster candidates in minimap pixel space to keep overlapping spawns readable.
    for i = 1, clusterKeyCount do
      wipe(clusterCells[clusterKeys[i]])
    end
    clusterKeyCount = 0

    local spacing = math.max(db.iconSize, 16) + 2
    local spacingSq = spacing * spacing
    local ringMode = db.ringMode and true or false
    local labelShown = db.labels and true or false
    local ringWantSize = math.max(db.iconSize + 4, 16)

    for k = 1, numCandidates do
      local c = candidates[k]
      local gx, gy = math.floor(c.sx / spacing), math.floor(c.sy / spacing)
      local hitPin
      for dx = -1, 1 do
        for dy = -1, 1 do
          local key = (gx + dx + 2048) * 4096 + (gy + dy + 2048)
          local bucket = clusterCells[key]
          if bucket then
            for m = 1, #bucket do
              local p = bucket[m]
              local dsx, dsy = c.sx - p._sx, c.sy - p._sy
              if dsx * dsx + dsy * dsy < spacingSq then
                hitPin = p
                break
              end
            end
          end
          if hitPin then break end
        end
        if hitPin then break end
      end

      if hitPin then
        MergeExtraNames(hitPin.extraNames, c)
        hitPin._labelDirty = true
      else
        used = used + 1
        local pin = GetPin(used)
        wipe(pin.extraNames)
        pin._sx, pin._sy = c.sx, c.sy
        pin._labelDirty = true
        pin.spot, pin.wx, pin.wy, pin.name, pin.level = c.spot, c.x, c.y, c.name, c.level

        local key = (gx + 2048) * 4096 + (gy + 2048)
        local bucket = clusterCells[key]
        if not bucket then
          bucket = {}
          clusterCells[key] = bucket
        end
        if #bucket == 0 then
          clusterKeyCount = clusterKeyCount + 1
          clusterKeys[clusterKeyCount] = key
        end
        bucket[#bucket + 1] = pin

        local useRing = (not c.isLive) and ringMode
        local wantSize = useRing and ringWantSize or db.iconSize
        if pin._size ~= wantSize then
          pin._size = wantSize
          pin:SetSize(wantSize, wantSize)
        end
        if pin._posX ~= c.sx or pin._posY ~= c.sy then
          pin._posX, pin._posY = c.sx, c.sy
          pin:ClearAllPoints()
          pin:SetPoint("CENTER", Minimap, "CENTER", c.sx, c.sy)
        end
        if pin._alpha ~= c.alpha then
          pin._alpha = c.alpha
          pin:SetAlpha(c.alpha)
        end
        if pin._useRing ~= useRing then
          pin._useRing = useRing
          pin.ring:SetShown(useRing)
          pin.icon:SetShown(not useRing)
        end
        if useRing then
          local cat = (c.spot and c.spot.c) or ns.Category(c.name) or "herb"
          if pin._ringCat ~= cat then
            pin._ringCat = cat
            local col = RING_COLORS[cat] or RING_COLORS.herb
            pin.ring:SetVertexColor(col[1], col[2], col[3], 1)
          end
        else
          local tex = ns.Icon(c.name)
          if pin._tex ~= tex then
            pin._tex = tex
            pin.icon:SetTexture(tex)
          end
        end
        local isCave = (not useRing) and c.spot and c.spot.cave and true or false
        if pin._cave ~= isCave then
          pin._cave = isCave
          pin.caveBorder:SetShown(isCave)
        end
        local level = c.level or false
        if pin._level ~= level then
          pin._level = level
          if c.level then
            pin.levelArrow:SetTexCoord(0, 1, c.level == "above" and 0 or 0.5, c.level == "above" and 0.5 or 1)
          end
          pin.levelArrow:SetShown(c.level ~= nil)
        end
        if pin._labelShown ~= labelShown then
          pin._labelShown = labelShown
          pin.label:SetShown(labelShown)
        end
        if not pin:IsShown() then pin:Show() end
      end
    end

    for i = 1, used do
      local pin = pins[i]
      if pin._labelDirty then
        pin._labelDirty = false
        local text = FormatLabel(pin.name, pin.spot, pin.extraNames)
        if pin._text ~= text then
          pin._text = text
          pin.label:SetText(text)
        end
      end
    end
  end
  for i = used + 1, #pins do
    local p = pins[i]
    if p:IsShown() then p:Hide() end
  end
end

-- Redraw only when something changed: you moved or turned, the minimap
-- zoomed, a scan finished, or a setting or saved spot changed.
local driver = CreateFrame("Frame")
local wait, dirty = 0, true
local lastContinent, lastX, lastY, lastFacing, lastRadius
driver:SetScript("OnUpdate", function(_, elapsed)
  wait = wait - elapsed
  if wait > 0 then return end
  wait = 0.1
  if not Minimap:IsVisible() then return end
  -- Read once per check and handed to Update(), not asked for again.
  local continent, x, y = ns.PlayerWorldPos()
  local facing, radius = ns.MinimapFacing(), ns.MinimapRadius()
  if not dirty and continent == lastContinent and facing == lastFacing and radius == lastRadius
      and (not x or ((x - lastX) ^ 2 + (y - lastY) ^ 2 < 0.25)) then
    return
  end
  dirty = false
  lastContinent, lastX, lastY, lastFacing, lastRadius = continent, x, y, facing, radius
  Update(continent, x, y, facing, radius)
end)

function ns.RefreshPins()
  wait, dirty = 0, true
end
ns.OnSpotsChanged = function()
  ns.RefreshPins()
  if ns.RefreshMap then ns.RefreshMap() end
  if ns.ShineChanged then ns.ShineChanged() end
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
end
