local _, ns = ...

-- WoW Forever only: the game can name the minimap dots at any point of the
-- minimap (Minimap:UpdateMouseoverAtPoint + C_TooltipInfo.GetMinimapMouseover),
-- so Gather Labels asks about points all over the minimap, a few frames at a
-- time, and puts an icon on every herb and ore dot it finds. No hovering,
-- no learning needed. Other game versions don't have this and use the saved
-- spots only (Core.lua).
--
-- Two ways of asking, picked with /glabels scanmode:
--   direct (default): ask the minimap where it is.
--   move: the game may only answer while the mouse is over the minimap. In
--         this mode the minimap is made invisible and slid under the mouse
--         for one frame per scan, then put back.

local STEPS = { 7, 5, 3 } -- pixels between asked points, by scan detail
local FRAME_BUDGET = 1    -- milliseconds of asking per frame (a sweep takes a few more frames, each one stays smooth)
local REST = 0.5          -- seconds between scans while you move
local REST_STILL = 2      -- seconds between scans while you stand still (nodes don't move)
local MAX_EMPTY_REST = 5  -- cap backoff when no dots are in range

local available = Minimap and Minimap.UpdateMouseoverAtPoint ~= nil
  and C_TooltipInfo ~= nil and C_TooltipInfo.GetMinimapMouseover ~= nil

local secretBlocked = false
local emptySweeps = 0
local sweep, rest = nil, 0

ns.liveDots = nil -- last scan's dots: { name, x, y, spot }, nil when not scanning

function ns.ScannerAvailable()
  return available
end

function ns.ScannerRunning()
  return available and not secretBlocked and ns.db and not ns.db.disableScan and ns.db.scan and ns.db.enabled
end

function ns.ScannerSweeping()
  return sweep ~= nil
end

function ns.HasLiveDots()
  return ns.liveDots ~= nil and #ns.liveDots > 0
end

function ns.ResetScanner()
  secretBlocked = false
  emptySweeps = 0
  rest = 0
  if ns.SyncScanner then ns.SyncScanner() end
end

---------------------------------------------------------------------------
-- Reading what the game names at a point
---------------------------------------------------------------------------

local function IsSecret(value)
  return issecretvalue and issecretvalue(value)
end

-- What a name in the minimap tooltip says besides the name (measured on
-- WoW Forever):
--   * a small arrow texture (Minimap-PositionArrows) before the name: the
--     node is above you (top half of the texture) or below you (bottom half);
--   * a grey name: the node is on the other side of indoors/outdoors from
--     you, so in a cave or building when you're outside.
local function ArrowLevel(part)
  local spec = part:match("|T([^|]*)|t")
  if not spec or not spec:find("PositionArrows", 1, true) then return end
  local f = {}
  for field in (spec .. ":"):gmatch("([^:]*):") do f[#f + 1] = field end
  local height, top, bottom = tonumber(f[7]), tonumber(f[10]), tonumber(f[11])
  if not height or height <= 0 or not top or not bottom then return end
  if bottom / height <= 0.55 then return "above" end
  if top / height >= 0.45 then return "below" end
end

local function IsGrey(hex)
  if not hex then return false end
  local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
  return r == g and g == b and r < 0xe0
end

-- Adds every herb, ore, fishing pool or chest in the minimap's current
-- mouseover to `out`, as { name, level, other }.
-- Returns true if the client returned a secret value (blocked client).
local function ReadNames(out)
  local ok, data = pcall(C_TooltipInfo.GetMinimapMouseover)
  if not ok then return false end
  if IsSecret(data) then
    secretBlocked = true
    return true
  end
  if type(data) ~= "table" or type(data.lines) ~= "table" then return false end
  for _, line in ipairs(data.lines) do
    local text = line.leftText
    if text == nil and type(line.args) == "table" then
      for _, arg in ipairs(line.args) do
        if arg.field == "leftText" then text = arg.stringVal end
      end
    end
    if IsSecret(text) then
      secretBlocked = true
      return true
    end
    if type(text) == "string" then
      local carried -- a colour code runs on into the next part until its |r
      for part in (text .. "\n"):gmatch("(.-)\n") do
        local colour = part:match("^%s*|T[^|]*|t%s*|c%x%x(%x%x%x%x%x%x)")
          or part:match("^%s*|c%x%x(%x%x%x%x%x%x)") or carried
        for kind, hex in part:gmatch("|([cr])(%x*)") do
          carried = kind == "c" and hex:sub(3, 8) or nil
        end
        local name = ns.Canon(ns.Clean(part))
        if ns.Category(name) then
          out[#out + 1] = { name = name, level = ArrowLevel(part), other = IsGrey(colour) }
        end
      end
    end
  end
  return false
end

-- The minimap as it lies this frame: where it is on screen and how its
-- pixels map to the world.
-- (one table, filled again each frame while a sweep runs)
local ctx = {}
local function Context()
  local continent, px, py = ns.PlayerWorldPos()
  local facing = ns.MinimapFacing()
  local cx, cy = Minimap:GetCenter()
  if not continent or not facing or not cx then return end
  ctx.continent, ctx.px, ctx.py, ctx.cx, ctx.cy = continent, px, py, cx, cy
  ctx.scale = Minimap:GetEffectiveScale()
  ctx.yardsPerPixel = ns.MinimapRadius() / (Minimap:GetWidth() / 2)
  ctx.cos, ctx.sin = math.cos(facing), math.sin(facing)
  return ctx
end

local names = {} -- reused for every point, so asking makes no garbage
local function AskAt(ctx, ox, oy, hits)
  wipe(names)
  if pcall(Minimap.UpdateMouseoverAtPoint, Minimap, (ctx.cx + ox) * ctx.scale, (ctx.cy + oy) * ctx.scale) then
    if ReadNames(names) then return -1 end
  end
  if #names == 0 then return 0 end
  local sx, sy = ox * ctx.yardsPerPixel, oy * ctx.yardsPerPixel
  local east, north = sx * ctx.cos - sy * ctx.sin, sx * ctx.sin + sy * ctx.cos
  local x, y = ctx.px + north, ctx.py - east
  for _, found in ipairs(names) do
    local name = found.name
    hits[name] = hits[name] or {}
    table.insert(hits[name], { x = x, y = y, r = ctx.yardsPerPixel, level = found.level, other = found.other })
  end
  return #names
end

-- Points to ask, as pixel offsets from the minimap's centre.
local gridCache = {}
local function Grid(step)
  local half = math.floor(Minimap:GetWidth() / 2)
  local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
  local key = half .. ":" .. step .. ":" .. tostring(square)
  if gridCache[key] then return gridCache[key] end
  local points = {}
  for ox = -half + step / 2, half, step do
    for oy = -half + step / 2, half, step do
      if square or ox * ox + oy * oy <= (half - 1) ^ 2 then
        points[#points + 1] = { ox, oy }
      end
    end
  end
  gridCache[key] = points
  return points
end

-- Hits of one name next to each other are one dot; its place is their middle.
local function Dots(hits, step, indoors)
  local dots = {}
  for name, list in pairs(hits) do
    local groups = {}
    for _, hit in ipairs(list) do
      local reach = hit.r * step * 2.5
      local found
      for _, g in ipairs(groups) do
        if (g.x - hit.x) ^ 2 + (g.y - hit.y) ^ 2 <= reach * reach then found = g break end
      end
      if not found then
        found = { x = hit.x, y = hit.y, n = 0, above = 0, below = 0, other = 0 }
        groups[#groups + 1] = found
      end
      found.n = found.n + 1
      found.x = found.x + (hit.x - found.x) / found.n
      found.y = found.y + (hit.y - found.y) / found.n
      if hit.level then found[hit.level] = found[hit.level] + 1 end
      if hit.other then found.other = found.other + 1 end
    end
    for _, g in ipairs(groups) do
      local level = (g.above * 2 > g.n and "above") or (g.below * 2 > g.n and "below") or nil
      -- Grey means the other side of indoors/outdoors from where you are.
      local cave = (g.other * 2 > g.n) ~= (indoors and true or false)
      dots[#dots + 1] = { name = name, x = g.x, y = g.y, level = level, cave = cave,
        spot = { n = { [name] = 1 }, last = name, cave = cave or nil } }
    end
  end
  return dots
end

---------------------------------------------------------------------------
-- Moving the minimap under the mouse (scan mode "move")
---------------------------------------------------------------------------

local saved

local function SlideUnderMouse()
  saved = { alpha = Minimap:GetAlpha(), points = {} }
  for i = 1, Minimap:GetNumPoints() do saved.points[i] = { Minimap:GetPoint(i) } end
  local x, y = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  Minimap:SetAlpha(0)
  Minimap:ClearAllPoints()
  Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
end

local function PutBack()
  if not saved then return end
  Minimap:ClearAllPoints()
  for _, p in ipairs(saved.points) do Minimap:SetPoint(unpack(p)) end
  Minimap:SetAlpha(saved.alpha)
  saved = nil
end

---------------------------------------------------------------------------
-- The scan loop
---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
local lastSpot -- where the last scan was made, to scan less often when nothing moved
local sweepState = { points = nil, index = 1, hits = {}, step = 2, move = false, needSlide = false }

-- No herb, ore, fish or treasure tracking on: no dots to read, so no scans.
local FIND_SPELLS = { [2383] = true, [2580] = true, [43308] = true, [2481] = true }
local findSpellNames
local tracking = true

local function CheckTrackingInner()
  local found, active = false, false
  for i = 1, C_Minimap.GetNumTrackingTypes() do
    local info = C_Minimap.GetTrackingInfo(i)
    if info and ((info.spellID and FIND_SPELLS[info.spellID]) or findSpellNames[info.name]) then
      found = true
      active = active or info.active
    end
  end
  return found, active
end

local function UpdateTracking()
  tracking = true
  if not (C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo) then return end
  if not findSpellNames then
    findSpellNames = {}
    for id in pairs(FIND_SPELLS) do
      local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
      if name then findSpellNames[name] = true end
    end
  end
  local ok, found, active = pcall(CheckTrackingInner)
  -- Only stop when the game clearly says none of them is on.
  if ok and found and not active then tracking = false end
end
driver:RegisterEvent("MINIMAP_UPDATE_TRACKING")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PLAYER_LOGIN")
driver:SetScript("OnEvent", function()
  UpdateTracking()
  if ns.SyncScanner then ns.SyncScanner() end
end)

local sweep_x, sweep_y
local function Finish(continent)
  local prevCount = ns.liveDots and #ns.liveDots or 0
  local dots = Dots(sweep.hits, sweep.step, IsIndoors and IsIndoors())
  sweep = nil
  if #dots > 0 then
    ns.liveDots = dots
    ns.liveContinent = continent
    ns.liveScans = (ns.liveScans or 0) + 1
    emptySweeps = 0
    for _, dot in ipairs(dots) do
      ns.AddSighting(continent, dot.x, dot.y, dot.name, ns.Category(dot.name), false, dot.cave)
    end
  else
    ns.liveDots = nil
    ns.liveContinent = continent
    if prevCount > 0 then
      ns.liveScans = (ns.liveScans or 0) + 1
    end
    emptySweeps = emptySweeps + 1
  end
  local here = lastSpot
  local radius = ns.MinimapRadius()
  local facing = ns.MinimapFacing()
  local moved = not here or here.continent ~= continent or (here.x - sweep_x) ^ 2 + (here.y - sweep_y) ^ 2 > 4
    or here.radius ~= radius or here.facing ~= facing
  if not lastSpot then lastSpot = {} end
  lastSpot.continent, lastSpot.x, lastSpot.y, lastSpot.radius, lastSpot.facing = continent, sweep_x, sweep_y, radius, facing
  local baseRest = moved and REST or REST_STILL
  if #dots == 0 then
    rest = math.min(MAX_EMPTY_REST, baseRest * math.min(4, emptySweeps))
  else
    rest = baseRest
  end
  if (prevCount > 0 or #dots > 0) and ns.RefreshPins then
    ns.RefreshPins()
  end
end

local function Abort()
  PutBack()
  sweep = nil
  rest = REST
end

-- Asking the minimap about a point moves the game's idea of what the mouse
-- is over, and that closes whatever tooltip you're reading (bag items, loot
-- rolls...). So no asking while the mouse is on a window; scans carry on as
-- soon as it's back over the world or the minimap.
local function MouseOnWindow()
  local f
  if GetMouseFoci then
    local foci = GetMouseFoci()
    f = foci and foci[1]
  elseif GetMouseFocus then
    f = GetMouseFocus()
  end
  if f == nil or f == WorldFrame or (issecretvalue and issecretvalue(f)) then return false end
  local p = f
  for _ = 1, 6 do
    if p == Minimap then return false end
    -- Enemy name plates are locked away from addons: asking them anything is
    -- an error. The mouse is over the world then, not over a window.
    if type(p) ~= "table" or (p.IsForbidden and p:IsForbidden()) then return false end
    local ok, parent = pcall(p.GetParent, p)
    if not ok then return false end
    p = parent
    if not p then break end
  end
  return true
end

local function Step(elapsed)
  if ns.ScannerRunning() and sweep == nil and rest <= elapsed and MouseOnWindow() then
    rest = 0.25
    return
  end
  if sweep and not sweep.move and MouseOnWindow() then
    Abort()
    rest = 0.25
    return
  end
  if not ns.ScannerRunning() then
    if sweep then Abort() end
    if ns.liveDots then ns.liveDots = nil; if ns.RefreshPins then ns.RefreshPins() end end
    return
  end
  if InCombatLockdown() or not Minimap:IsVisible() or not tracking then
    if sweep then Abort() end
    if not tracking and ns.liveDots then
      ns.liveDots = nil
      if ns.RefreshPins then ns.RefreshPins() end
    end
    return
  end
  if not sweep then
    rest = rest - elapsed
    if rest > 0 then return end
    local step = STEPS[ns.db.scanDetail] or STEPS[2]
    for k in pairs(sweepState.hits) do sweepState.hits[k] = nil end
    sweepState.points = Grid(step)
    sweepState.index = 1
    sweepState.step = step
    sweepState.move = ns.db.scanMode == "move"
    sweepState.needSlide = false
    sweep = sweepState
    if sweep.move then
      if IsMouselooking and IsMouselooking() then sweep = nil; rest = REST; return end
      SlideUnderMouse()
      return -- the game notices the minimap under the mouse next frame
    end
  end
  if sweep.needSlide then
    sweep.needSlide = false
    SlideUnderMouse()
    return
  end
  local ctx = Context()
  if not ctx then Abort(); return end
  sweep_x, sweep_y = ctx.px, ctx.py
  local points, started = sweep.points, debugprofilestop()
  -- In move mode the minimap is away while this runs, so ask as much as
  -- fits in a short moment, put it back, and carry on after the next slide.
  local budget = sweep.move and 25 or FRAME_BUDGET
  while sweep.index <= #points do
    local p = points[sweep.index]
    if AskAt(ctx, p[1], p[2], sweep.hits) < 0 then
      PutBack()
      sweep = nil
      ns.liveDots = nil
      if ns.RefreshPins then ns.RefreshPins() end
      if ns.SyncScanner then ns.SyncScanner() end
      return
    end
    sweep.index = sweep.index + 1
    if debugprofilestop() - started > budget then break end
  end
  if sweep.move then PutBack() end
  if sweep.index > #points then
    Finish(ctx.continent)
  elseif sweep.move then
    sweep.needSlide = true
  end
end

local function OnUpdate(_, elapsed)
  Step(elapsed)
end

function ns.SyncScanner()
  if not available then return end
  if ns.ScannerRunning() then
    driver:SetScript("OnUpdate", OnUpdate)
  else
    driver:SetScript("OnUpdate", nil)
    if sweep then Abort() end
    if ns.liveDots then
      ns.liveDots = nil
      if ns.RefreshPins then ns.RefreshPins() end
    end
  end
end

---------------------------------------------------------------------------
-- /glabels scantest: one scan each way, with what it found, for checking
-- which mode this game version needs.
---------------------------------------------------------------------------

function ns.ScanTest()
  if not available then
    ns.Print("This game version can't read the minimap dots, so Gather Labels uses saved spots here.")
    return
  end
  if ns.db and ns.db.disableScan then
    ns.Print('Scanning is disabled in Settings (untick "Disable all scanning" first).')
    return
  end
  ns.ResetScanner()
  local function Run(label)
    local ctx = Context()
    if not ctx then
      ns.Print(label .. ": can't scan here (no position, or rotating minimap with no facing).")
      return
    end
    local hits, asked, named, blocked = {}, 0, 0, false
    local step = STEPS[2]
    for _, p in ipairs(Grid(step)) do
      asked = asked + 1
      local n = AskAt(ctx, p[1], p[2], hits)
      if n < 0 then
        blocked = true
        break
      end
      named = named + n
    end
    if blocked then
      ns.Print(label .. ": client returned secret tooltip values (minimap dot reading is restricted on this client build).")
      return
    end
    local dots = Dots(hits, step, IsIndoors and IsIndoors())
    local dotNames = {}
    for _, dot in ipairs(dots) do
      dotNames[#dotNames + 1] = dot.name .. (dot.level and (" (" .. dot.level .. ")") or "") .. (dot.cave and " (cave)" or "")
    end
    ns.Print(string.format("%s: asked %d points, %d answers, %d dots: %s", label, asked, named,
      #dots, #dotNames > 0 and table.concat(dotNames, ", ") or "none"))
  end
  Run("direct")
  SlideUnderMouse()
  C_Timer.After(0, function()
    Run("move")
    PutBack()
    ns.Print("Current mode: " .. (ns.db.scanMode == "move" and "move" or "direct")
      .. ". Change it with /glabels scanmode direct or /glabels scanmode move.")
  end)
end
