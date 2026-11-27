local _, ns = ...

-- Gathering skill: what each node needs (Nodes.lua) against what you have.
--   * Hovering an icon on the minimap, or a node in the world, shows the
--     skill it needs and yours, coloured like the game does.
--   * "Hide nodes my skill is too low for" leaves those off the minimap and
--     out of the farming route.

local SKILL_LINE = { herb = 182, ore = 186 }           -- Herbalism, Mining
local SKILL_NAME = { herb = "Herbalism", ore = "Mining" }

local cache, cacheTime = {}, 0

-- Retail split gathering into a skill per expansion and dropped most node
-- requirements, so the numbers only make sense on Classic and WoW Forever.
function ns.SkillApplies()
  return not ns.IS_RETAIL
end

-- Your skill (with bonuses from gear) in one gathering profession: a number,
-- 0 if you don't have it, nil if the game won't say.
local function ReadSkill(category)
  local id = SKILL_LINE[category]
  if not id then return end
  if C_SkillInfo and C_SkillInfo.GetNumSkillLines then
    local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, id)
    if ok and type(info) == "table" and info.rank then return info.rank + (info.modifier or 0) end
    local found = false
    ok = pcall(function()
      for i = 1, C_SkillInfo.GetNumSkillLines() do
        local line = C_SkillInfo.GetSkillLineInfo(i)
        if line and line.skillID == id then
          info, found = line, true
          return
        end
      end
    end)
    if ok and found then return info.rank + (info.modifier or 0) end
    if ok and C_SkillInfo.GetNumSkillLines() > 0 then return 0 end
  end
  if GetProfessions and GetProfessionInfo then
    local ok, rank = pcall(function()
      local p1, p2 = GetProfessions()
      for _, index in ipairs({ p1 or 0, p2 or 0 }) do
        if index > 0 then
          local _, _, level, _, _, _, line, modifier = GetProfessionInfo(index)
          if line == id then return level + (modifier or 0) end
        end
      end
      return 0
    end)
    if ok then return rank end
  end
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, temp, modifier = GetSkillLineInfo(i)
      if not isHeader and name == SKILL_NAME[category] then return rank + (temp or 0) + (modifier or 0) end
    end
    return 0
  end
end

function ns.SkillRank(category)
  local now = GetTime()
  if now - cacheTime > 5 then
    wipe(cache)
    cacheTime = now
  end
  if cache[category] == nil then cache[category] = ReadSkill(category) or false end
  return cache[category] or nil
end

-- Skill a node needs, your skill, and the game's colour for it:
-- red too low, orange/yellow/green still gives skill points, grey no longer does.
function ns.SkillInfo(name)
  local node = ns.NODES[name]
  if not node or not node.skill or ns.IS_RETAIL then return end
  local need, have = node.skill, ns.SkillRank(node.category)
  local base = need == 1 and 0 or need
  local color
  if not have then color = "ffffff"
  elseif have < need then color = "ff2020"
  elseif have < base + 25 then color = "ff8040"
  elseif have < base + 50 then color = "ffff00"
  elseif have < base + 100 then color = "40c040"
  else color = "808080" end
  return need, have, color, SKILL_NAME[node.category]
end

-- One tooltip line: "Requires Herbalism 125 (you have 110)".
function ns.SkillText(name)
  local need, have, color, skillName = ns.SkillInfo(name)
  if not need then return end
  local text = "|cff" .. color .. (have and have < need and "Requires " or "") .. skillName .. " " .. need .. "|r"
  if have then text = text .. " |cffaaaaaa(you have " .. have .. ")|r" end
  return text
end

function ns.TooLow(name)
  if not (ns.db and ns.db.hideAbove) then return false end
  local need, have = ns.SkillInfo(name)
  return need ~= nil and have ~= nil and have < need
end

function ns.IsGrey(name)
  if not (ns.db and ns.db.hideGrey) then return false end
  local need, have, color = ns.SkillInfo(name)
  return need ~= nil and have ~= nil and color == "808080"
end

-- Ticked in Settings and not hidden for your skill.
function ns.IsDrawn(name)
  return ns.IsShownName(name) and not ns.TooLow(name) and not ns.IsGrey(name)
end

local events = CreateFrame("Frame")
events:RegisterEvent("SKILL_LINES_CHANGED")
events:SetScript("OnEvent", function()
  cacheTime = 0
  if ns.RefreshPins then ns.RefreshPins() end
  if ns.RefreshMap then ns.RefreshMap() end
  if ns.ShineChanged then ns.ShineChanged() end
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
end)

-- Hovering a node in the world: add the skill line under its name.
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Object then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, function(tooltip)
    if tooltip ~= GameTooltip or not ns.db or ns.IS_RETAIL then return end
    pcall(function()
      local first = GameTooltipTextLeft1:GetText()
      if issecretvalue and issecretvalue(first) then return end
      if type(first) ~= "string" then return end
      local name = ns.Clean(first)
      local text = ns.SkillText(name)
      if not text then return end
      local need = tostring(ns.NODES[name].skill)
      -- Leave it alone if the game already shows the requirement.
      for i = 2, tooltip:NumLines() do
        local line = _G["GameTooltipTextLeft" .. i]:GetText()
        if type(line) == "string" and not (issecretvalue and issecretvalue(line)) and line:find(need, 1, true) then return end
      end
      tooltip:AddLine(text)
      tooltip:Show()
    end)
  end)
end
