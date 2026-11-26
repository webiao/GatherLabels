local _, ns = ...

-- Session tracker: a small panel counting the nodes you gather and what they
-- gave you, how long you've been at it, nodes per hour and what the loot is
-- worth. The session carries on across logins until you press Reset.

local MAX_ITEMS = 8
local SAME_NODE = 8 * 8 -- yards squared: mining the same vein again isn't a new node

local session -- ns.db.session
local lastNode
local runningSince -- GetTime() when the clock last started; the clock needs no timer
local lootVersion, valueVersion, valueTime, valueTotal, valueAuction = 0, -1, 0, 0, false
local sorted, sortedVersion = {}, -1

-- Seconds gathered: what was saved plus the time since the clock started.
local function Elapsed()
  return session.elapsed + (runningSince and GetTime() - runningSince or 0)
end

local function NewSession()
  return { elapsed = 0, nodes = 0, catches = 0, loot = {}, order = {} }
end

local function Started()
  return session.nodes > 0 or session.catches > 0
end

---------------------------------------------------------------------------
-- Prices
---------------------------------------------------------------------------

-- Auction price from Auctionator or TradeSkillMaster when installed,
-- otherwise what a vendor pays.
-- A usable price: a plain positive number (price addons can hand back
-- anything, Retail even unreadable values).
local function Good(price)
  return type(price) == "number" and not (issecretvalue and issecretvalue(price)) and price > 0
end

local function Price(itemID)
  if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID then
    local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "Gather Labels", itemID)
    if ok and Good(price) then return price, true end
  end
  if TSM_API and TSM_API.GetCustomPriceValue then
    local ok, price = pcall(TSM_API.GetCustomPriceValue, "DBMarket", "i:" .. itemID)
    if ok and Good(price) then return price, true end
  end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if getInfo then
    local price = select(11, getInfo(itemID))
    if Good(price) then return price, false end
  end
  return 0, false
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

local function Money(copper)
  copper = math.max(0, math.floor(copper or 0))
  local g = math.floor(copper / 10000)
  local s = math.floor(copper / 100) % 100
  local c = copper % 100
  if g > 0 then
    return string.format("|cffffffff%d|r%s |cffffffff%d|r%s |cffffffff%d|r%s", g, GOLD_ICON, s, SILVER_ICON, c, COPPER_ICON)
  elseif s > 0 then
    return string.format("|cffffffff%d|r%s |cffffffff%d|r%s", s, SILVER_ICON, c, COPPER_ICON)
  end
  return string.format("|cffffffff%d|r%s", c, COPPER_ICON)
end

local function Duration(seconds)
  seconds = math.floor(seconds)
  return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local panel = CreateFrame("Frame", "GatherLabelsTracker", UIParent, "BackdropTemplate")
panel:SetSize(240, 100)
panel:SetFrameStrata("MEDIUM")
panel:SetMovable(true)
panel:SetClampedToScreen(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:Hide()
ns.Skin.Plate(panel)

panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.title:SetPoint("TOPLEFT", 12, -11)
panel.title:SetText("|TInterface\\Icons\\INV_Misc_Flower_02:14:14:0:0:64:64:5:59:5:59|t  Gathering session")

-- gold rule under the title
panel.rule = panel:CreateTexture(nil, "ARTWORK")
panel.rule:SetHeight(1)
panel.rule:SetPoint("TOPLEFT", 10, -28)
panel.rule:SetPoint("TOPRIGHT", -10, -28)
panel.rule:SetColorTexture(1, 1, 1, 1)
if CreateColor and panel.rule.SetGradient then
  panel.rule:SetGradient("HORIZONTAL", CreateColor(1, 0.82, 0, 0.6), CreateColor(1, 0.82, 0, 0.05))
else
  panel.rule:SetVertexColor(1, 0.82, 0, 0.3)
end

panel.close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
panel.close:SetSize(22, 22)
panel.close:SetPoint("TOPRIGHT", -3, -3)
panel.close:SetScript("OnClick", function() ns.Set("tracker", false) end)

panel.reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
panel.reset:SetSize(54, 18)
panel.reset:SetPoint("RIGHT", panel.close, "LEFT", 0, 0)
panel.reset:SetText("Reset")
panel.reset:SetScript("OnClick", function() ns.ResetSession() end)

local function Line(anchor, offset)
  local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offset or -4)
  fs:SetTextColor(0.72, 0.67, 0.56) -- labels warm grey, numbers white
  return fs
end
panel.time = Line(panel.title, -10)
panel.nodes = Line(panel.time)
panel.value = Line(panel.nodes)

panel.rows = {}
for i = 1, MAX_ITEMS do
  local row = CreateFrame("Frame", nil, panel)
  row:SetSize(210, 16)
  row:SetPoint("TOPLEFT", panel.value, "BOTTOMLEFT", 0, -6 - (i - 1) * 17)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(15, 15)
  row.icon:SetPoint("LEFT")
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
  row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  panel.rows[i] = row
end
panel.more = Line(panel.value)

panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, _, x, y = self:GetPoint(1)
  ns.db.trackerPoint = { point, x, y }
end)

local QUALITY = { [0] = "9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000" }

local function Refresh()
  if not panel:IsShown() or not session then return end
  local elapsed = Elapsed()
  local hours = elapsed / 3600
  panel.time:SetText("Time: |cffffffff" .. Duration(elapsed) .. "|r"
    .. (Started() and "" or "  |cff888888(starts at your first node)|r"))
  local nodes
  if session.nodes == 0 and session.catches > 0 then
    nodes = "Fish caught: |cffffffff" .. session.catches .. "|r"
    if elapsed >= 60 then
      nodes = nodes .. string.format("  |cffaaaaaa(%d an hour)|r", session.catches / hours)
    end
  else
    nodes = "Nodes: |cffffffff" .. session.nodes .. "|r"
    if elapsed >= 60 and session.nodes > 0 then
      nodes = nodes .. string.format("  |cffaaaaaa(%d an hour)|r", session.nodes / hours)
    end
    if session.catches > 0 then
      nodes = nodes .. "\nFish caught: |cffffffff" .. session.catches .. "|r"
      if elapsed >= 60 then
        nodes = nodes .. string.format("  |cffaaaaaa(%d an hour)|r", session.catches / hours)
      end
    end
  end
  panel.nodes:SetText(nodes)

  -- Prices are looked up only when the loot changes, or once a minute.
  if valueVersion ~= lootVersion or GetTime() - valueTime > 60 then
    valueTotal, valueAuction = 0, false
    for id, item in pairs(session.loot) do
      local price, fromAuction = Price(id)
      valueTotal = valueTotal + price * item.count
      valueAuction = valueAuction or fromAuction
    end
    valueVersion, valueTime = lootVersion, GetTime()
  end
  local total, auction = valueTotal, valueAuction
  local value = "Value: " .. Money(total) .. (auction and " |cffaaaaaa(auction)|r" or " |cffaaaaaa(vendor)|r")
  if elapsed >= 60 and total > 0 then value = value .. "\n" .. Money(total / hours) .. " |cffaaaaaaan hour|r" end
  panel.value:SetText(value)

  if sortedVersion ~= lootVersion then
    wipe(sorted)
    for id, item in pairs(session.loot) do sorted[#sorted + 1] = { id = id, item = item } end
    table.sort(sorted, function(a, b) return a.item.count > b.item.count end)
    sortedVersion = lootVersion
  end
  local items = sorted
  for i, row in ipairs(panel.rows) do
    local entry = items[i]
    if entry then
      row.icon:SetTexture(entry.item.icon)
      row.text:SetText("|cff" .. (QUALITY[entry.item.quality or 1] or "ffffff") .. (entry.item.name or "?")
        .. "|r x" .. entry.item.count)
    end
    row:SetShown(entry ~= nil)
  end
  local shown = math.min(#items, MAX_ITEMS)
  panel.more:ClearAllPoints()
  panel.more:SetPoint("TOPLEFT", panel.value, "BOTTOMLEFT", 0, -6 - shown * 17)
  panel.more:SetText(#items > MAX_ITEMS and ("and " .. (#items - MAX_ITEMS) .. " more") or "")
  local nodesExtra = math.max(0, (panel.nodes:GetStringHeight() or 12) - 12)
  panel:SetHeight(92 + nodesExtra + panel.value:GetStringHeight() + shown * 17 + (#items > MAX_ITEMS and 14 or 0))
end

local function PlacePanel()
  panel:ClearAllPoints()
  local p = ns.db.trackerPoint
  if p then
    panel:SetPoint(p[1], UIParent, p[1], p[2], p[3])
  else
    panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 120)
  end
end

local function UpdateShown()
  local show = ns.db and ns.db.tracker
  if show and not panel:IsShown() then
    PlacePanel()
    panel:Show()
  elseif not show then
    panel:Hide()
  end
  Refresh()
end

---------------------------------------------------------------------------
-- Counting
---------------------------------------------------------------------------

-- Core.lua: a gathering spell finished on a node.
function ns.OnGathered(name, continent, x, y)
  if not session then return end
  local now = GetTime()
  if lastNode and lastNode.name == name and lastNode.continent == continent and x
      and (lastNode.x - x) ^ 2 + (lastNode.y - y) ^ 2 < SAME_NODE and now - lastNode.time < 120 then
    lastNode.time = now
    return
  end
  lastNode = { name = name, continent = continent, x = x or 0, y = y or 0, time = now }
  session.nodes = session.nodes + 1
  runningSince = runningSince or GetTime()
  Refresh()
end

local function CountLootInner()
  local count = (GetNumLootItems and GetNumLootItems()) or 0
  for slot = 1, count do
    local link = GetLootSlotLink(slot)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    if id then
      local icon, name, quantity, _, quality = GetLootSlotInfo(slot)
      local item = session.loot[id]
      if not item then
        item = { count = 0 }
        session.loot[id] = item
      end
      item.count = item.count + (tonumber(quantity) or 1)
      item.icon, item.name = icon or item.icon, name or item.name
      item.quality = tonumber(quality) or item.quality
    end
  end
end

local function CountLoot()
  pcall(CountLootInner)
  lootVersion = lootVersion + 1
  Refresh()
end

-- Core.lua: the loot window of a node you just gathered opened.
function ns.OnGatherLoot()
  if session then CountLoot() end
end

function ns.ResetSession()
  ns.db.session = NewSession()
  session = ns.db.session
  lastNode, runningSince = nil, nil
  lootVersion = lootVersion + 1
  Refresh()
  ns.Print("New gathering session started.")
end

local function ReadIsFishingLoot()
  return IsFishingLoot and IsFishingLoot()
end

local fishingLootDone = false

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("LOOT_READY")
events:RegisterEvent("LOOT_OPENED")
events:RegisterEvent("LOOT_CLOSED")
events:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LOGIN" then
    ns.db.session = ns.db.session or NewSession()
    session = ns.db.session
    session.elapsed = session.elapsed or 0
    session.nodes = session.nodes or 0
    session.catches = session.catches or 0
    session.loot = session.loot or {}
    session.order = session.order or {}
    if Started() then runningSince = GetTime() end
    UpdateShown()
  elseif event == "PLAYER_LOGOUT" and session then
    -- Save the clock (also on /reload).
    session.elapsed = Elapsed()
    runningSince = nil
  elseif event == "LOOT_CLOSED" then
    fishingLootDone = false
  elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
    if arg1 == "player" then fishingLootDone = false end
  elseif (event == "LOOT_READY" or event == "LOOT_OPENED") and session and not fishingLootDone then
    -- Fish count too (LOOT_READY handles auto-loot when LOOT_OPENED never fires).
    local ok, fishing = pcall(ReadIsFishingLoot)
    if ok and fishing then
      local numItems = (GetNumLootItems and GetNumLootItems()) or 0
      if numItems > 0 then
        fishingLootDone = true
        session.catches = session.catches + 1
        runningSince = runningSince or GetTime()
        CountLoot()
      end
    end
  end
end)

-- Only while the panel shows: update the time once a second.
local tick = 0
panel:SetScript("OnUpdate", function(_, elapsed)
  tick = tick + elapsed
  if tick < 1 then return end
  tick = 0
  if runningSince then Refresh() end
end)

ns.TrackerSettingsChanged = UpdateShown
