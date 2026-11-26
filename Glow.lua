local _, ns = ...

-- Close-up glow (1.9.0).
--
-- Walk up to a herb, a vein, a chest or your fishing bobber and it lights
-- up in its own colour: green herbs, copper ore, blue chests, teal fishing
-- pools, a red bobber. The light is dim while the node is still out of
-- reach, flashes the moment you can gather it, and turns grey when you
-- can't (skill too low, or the game refuses it for now).
--
-- How: the game can pick the one object near you that you could click
-- ("soft interact") and give it a small name plate that it keeps over the
-- object as you move. Gather Labels switches that on while the glow is on
-- (and puts the game's own settings back when it's off), then draws its
-- light on that name plate. Addons can't light the 3D object itself.
--
-- Light on the game: everything runs on events. While something glows, a
-- small check 6 times a second sees whether it's in reach yet; nothing runs
-- when nothing glows. All motion is the game's own animations.

local SOFT = "softinteract"
-- 1.9.1: our own high-resolution pictures (Media folder), so the light
-- stays smooth and sharp at any size instead of the game's small blurry
-- ones. White light; the colour comes from the node's kind.
local MEDIA = "Interface\\AddOns\\GatherLabels\\Media\\"
local GLOW = MEDIA .. "Glow"   -- soft round light (256 px)
local RING = MEDIA .. "Ring"   -- thin crisp ring with a soft bloom (512 px)
local STAR = MEDIA .. "Star"   -- four sharp points and a hot core (256 px)
local RAYS = MEDIA .. "Rays"   -- many thin rays (512 px)
local BEAM = MEDIA .. "Beam"   -- column of light, bright at the base (128x512)
local SPARK = MEDIA .. "Spark" -- small bright mote (64 px)
-- 1.9.2 "Power aura": flame tongues of light (two shapes that flicker
-- into each other) and thin streaks shooting up.
local AURA_A = MEDIA .. "AuraA"   -- 256x512
local AURA_B = MEDIA .. "AuraB"
local STREAK = MEDIA .. "Streak"  -- 32x128
-- 1.9.4 living flames: 32 frames of rising fire (128x256 each, 8 across,
-- 4 down) played like a flip book.
local FIRE = MEDIA .. "Fire"      -- 1024x1024
local FIRE_FRAMES, FIRE_FPS = 32, 20
-- 1.9.5 power-up: four small crackling arcs of energy (64x128 each, side by side).
local BOLT = MEDIA .. "Bolt"      -- 256x128
local BOBBER = 35591 -- the fishing bobber object

local random = math.random

local function Secret(v) return issecretvalue and issecretvalue(v) end

-- One readable value from a game call, or nil.
local function Read(f, ...)
  if not f then return nil end
  local ok, v = pcall(f, ...)
  if ok and not Secret(v) then return v end
  return nil
end

------------------------------------------------------------------------
-- What glows, and in which colour
------------------------------------------------------------------------

ns.GLOW_KINDS = {
  { key = "herb", label = "Herbs", color = { 0.35, 1, 0.4 } },
  { key = "ore", label = "Ore", color = { 1, 0.55, 0.15 } },
  { key = "treasure", label = "Chests", color = { 0.4, 0.68, 1 } },
  { key = "fish", label = "Fishing pools", color = { 0.25, 0.95, 0.9 } },
  { key = "bobber", label = "My bobber", color = { 1, 0.28, 0.22 } },
}
local COLOR = {}
for _, k in ipairs(ns.GLOW_KINDS) do COLOR[k.key] = k.color end
local GREY = { 0.62, 0.62, 0.62 }

ns.GLOW_STYLES = {
  { key = "halo", label = "Halo", tip = "A soft round light that breathes, with a ring rippling out on the ground." },
  { key = "beacon", label = "Beacon", tip = "A column of light rising from the node, with pulses of light running up it, a ripple at its foot and stars twinkling all the way up." },
  { key = "sparkle", label = "Sparkle", tip = "A star with turning rays and small twinkles around it." },
  { key = "ring", label = "Ground ring", tip = "Two rings of light on the ground around the node, gently pulsing." },
  { key = "embers", label = "Embers", tip = "A low glow with sparks floating up off the node." },
  { key = "aura", label = "Power aura", tip = "Powers up when a node comes into view: the aura bursts up with a shockwave, then burns and surges with crackling energy." },
}
local STYLE_OK = {}
for _, s in ipairs(ns.GLOW_STYLES) do STYLE_OK[s.key] = true end

local function Style()
  local style = ns.db and ns.db.glowStyle
  return STYLE_OK[style] and style or "halo"
end

-- Another addon that draws the same kind of glow: two would fight over the
-- game's settings and light everything twice, so Gather Labels steps aside.
local OTHERS = { "Lueur", "LueurStill", "QuestGlint" }
function ns.GlowBlockedBy()
  local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if not loaded then return nil end
  for _, name in ipairs(OTHERS) do
    local ok, on = pcall(loaded, name)
    if ok and on == true then return name end
  end
  return nil
end

------------------------------------------------------------------------
-- Game settings (CVars): switched on while the glow is on, then put back
------------------------------------------------------------------------

local NAMES = { "SoftTargetInteract", "SoftTargetInteractRange", "SoftTargetInteractArc",
  "SoftTargetInteractOnlyInRange", "SoftTargetInteractRangeIsHard", "SoftTargetNameplateInteract",
  "SoftTargetIconInteract", "SoftTargetIconGameObject", "SoftTargetLowPriorityIcons",
  "nameplateGameObjectMaxDistance" }
local LOWER = {}
for _, n in ipairs(NAMES) do LOWER[n:lower()] = n end

local function GetCV(name)
  local get = (C_CVar and C_CVar.GetCVar) or GetCVar
  local ok, v = pcall(get, name)
  if ok and v ~= nil and not Secret(v) then return tostring(v) end
  return nil
end

local function SetCV(name, value)
  local set = (C_CVar and C_CVar.SetCVar) or SetCVar
  if set then pcall(set, name, value) end
end

-- This game has close-up targeting at all (not the oldest Classic clients).
function ns.GlowAvailable()
  return GetCV("SoftTargetInteract") ~= nil
end

local wanted = {}
local function Wanted()
  wipe(wanted)
  local db = ns.db
  if not db or not db.glow or ns.GlowBlockedBy() then return wanted end
  -- 3 = always active for both Gamepad and Keyboard+Mouse
  wanted.SoftTargetInteract = "3"
  wanted.SoftTargetInteractRange = tostring(db.glowRange)
  wanted.SoftTargetInteractArc = "2"           -- anywhere around you, no need to face it
  wanted.SoftTargetInteractOnlyInRange = "0"   -- also pick it while it's still out of reach (dim light)
  wanted.SoftTargetInteractRangeIsHard = "0"
  wanted.SoftTargetNameplateInteract = "1"     -- give it a name plate to draw on
  wanted.SoftTargetIconInteract = "1"          -- required for interact soft-target icons in KBM mode
  wanted.SoftTargetIconGameObject = "1"        -- objects only get that plate with this on
  wanted.SoftTargetLowPriorityIcons = "1"      -- keep interact objects active in KBM mode
  local far = tonumber(GetCV("nameplateGameObjectMaxDistance") or "")
  if far and far < 60 then wanted.nameplateGameObjectMaxDistance = "60" end
  return wanted
end

local waitingForCombat = false

local function ApplyCVars()
  local db = ns.db
  if not db then return end
  if InCombatLockdown and InCombatLockdown() then
    waitingForCombat = true
    return
  end
  db.glowCVars = type(db.glowCVars) == "table" and db.glowCVars or {}
  local saved, want = db.glowCVars, Wanted()
  for _, name in ipairs(NAMES) do
    local now = GetCV(name)
    if now then -- this game has the setting
      if want[name] then
        if now ~= want[name] then
          if saved[name] == nil then saved[name] = now end
          SetCV(name, want[name])
        end
      elseif saved[name] ~= nil then
        SetCV(name, saved[name])
        saved[name] = nil
      end
    end
  end
end
ns.GlowApplyCVars = ApplyCVars

-- Logging out (or /reload): hand every setting back, so the game is left
-- exactly as you had it even if Gather Labels is removed. Taken again at
-- the next login.
local function ReturnCVars()
  local saved = ns.db and ns.db.glowCVars
  if type(saved) ~= "table" then return end
  for name, value in pairs(saved) do SetCV(name, value) end
  wipe(saved)
end

------------------------------------------------------------------------
-- The light
------------------------------------------------------------------------

local glow = CreateFrame("Frame", "GatherLabelsGlow", UIParent)
glow:SetSize(128, 128)
glow:SetFrameStrata("BACKGROUND")
glow:EnableMouse(false)
glow:Hide()

-- Everything that scales with "Size" lives on art.
local art = CreateFrame("Frame", nil, glow)
art:SetSize(128, 128)
art:SetPoint("CENTER")

local pieces = {} -- every texture tinted by kind and state

local function Tex(layer, file, w, h, x, y, sub)
  local t = art:CreateTexture(nil, layer, nil, sub)
  -- Smooth scaling at every size (no jagged or blocky edges).
  t:SetTexture(file, "CLAMP", "CLAMP", "TRILINEAR")
  t:SetBlendMode("ADD")
  t:SetSize(w, h)
  t:SetPoint("CENTER", art, "CENTER", x or 0, y or 0)
  t:Hide()
  pieces[#pieces + 1] = t
  return t
end

local function Scale(group, from, to, duration)
  local a = group:CreateAnimation("Scale")
  if a.SetScaleFrom then
    a:SetScaleFrom(from, from)
    a:SetScaleTo(to, to)
  else
    a:SetScale(to / from, to / from)
  end
  a:SetDuration(duration)
  return a
end

local function Alpha(group, from, to, duration, delay, order)
  local a = group:CreateAnimation("Alpha")
  a:SetFromAlpha(from)
  a:SetToAlpha(to)
  a:SetDuration(duration)
  if delay then a:SetStartDelay(delay) end
  if order then a:SetOrder(order) end
  return a
end

local FLOOR = -16 -- where the ground is, under the node's middle

-- Soft round light (halo, embers).
art.halo = Tex("BACKGROUND", GLOW, 112, 112, 0, 0, 1)
art.breathe = art.halo:CreateAnimationGroup()
art.breathe:SetLooping("BOUNCE")
Scale(art.breathe, 0.88, 1.1, 1.3):SetSmoothing("IN_OUT")
Alpha(art.breathe, 0.75, 1, 1.3):SetSmoothing("IN_OUT")

-- Flat pool of light on the ground (beacon, ring).
art.pool = Tex("BACKGROUND", GLOW, 120, 34, 0, FLOOR, 0)

-- A ring rippling out across the ground (halo, ring).
art.ripple = Tex("BORDER", RING, 88, 30, 0, FLOOR)
art.rippleAnim = art.ripple:CreateAnimationGroup()
art.rippleAnim:SetLooping("REPEAT")
Scale(art.rippleAnim, 0.5, 1.7, 1.6)
Alpha(art.rippleAnim, 0, 0.8, 0.3)
Alpha(art.rippleAnim, 0.8, 0, 1.3, 0.3)
Alpha(art.rippleAnim, 0, 0, 0.9, 1.6)

-- A still ring lying on the ground, pulsing (ring).
art.band = Tex("BORDER", RING, 145, 50, 0, FLOOR)
art.bandAnim = art.band:CreateAnimationGroup()
art.bandAnim:SetLooping("BOUNCE")
Scale(art.bandAnim, 0.94, 1.06, 1.1):SetSmoothing("IN_OUT")
Alpha(art.bandAnim, 0.65, 1, 1.1):SetSmoothing("IN_OUT")

-- A column of light rising off the node (beacon): a wide soft one and a
-- thin bright core, shimmering out of step.
art.beam = Tex("BACKGROUND", BEAM, 52, 200, 0, 0, 2)
art.beam:ClearAllPoints()
art.beam:SetPoint("BOTTOM", art, "CENTER", 0, FLOOR - 10)
art.core = Tex("BORDER", BEAM, 18, 170, 0, 0)
art.core:ClearAllPoints()
art.core:SetPoint("BOTTOM", art, "CENTER", 0, FLOOR - 4)
art.shimmer = art.beam:CreateAnimationGroup()
art.shimmer:SetLooping("BOUNCE")
Alpha(art.shimmer, 1, 0.6, 0.9):SetSmoothing("IN_OUT")
art.shimmer2 = art.core:CreateAnimationGroup()
art.shimmer2:SetLooping("BOUNCE")
Alpha(art.shimmer2, 0.6, 1, 0.65):SetSmoothing("IN_OUT")

-- 1.9.3: pulses of light running up the column, one after the other.
local function Pulse(delay)
  local t = Tex("ARTWORK", GLOW, 26, 44, 0, FLOOR, 2)
  t:SetAlpha(0)
  local group = t:CreateAnimationGroup()
  group:SetLooping("REPEAT")
  local up = group:CreateAnimation("Translation")
  up:SetOffset(0, 165)
  up:SetDuration(1.6)
  up:SetSmoothing("IN")
  local shrink = Scale(group, 1, 0.45, 1.6)
  local into = Alpha(group, 0, 0.95, 0.25)
  local out = Alpha(group, 0.95, 0, 1.35, 0.25)
  if delay > 0 then
    up:SetStartDelay(delay)
    shrink:SetStartDelay(delay)
    into:SetStartDelay(delay)
    out:SetStartDelay(delay + 0.25)
  end
  group:SetScript("OnStop", function() t:SetAlpha(0) end)
  return t, group
end
art.pulse1, art.pulseA = Pulse(0)
art.pulse2, art.pulseB = Pulse(0.8)

-- 1.9.3: little stars popping up all along the column (Beacon sparkles).
local SPARKLES = 6
art.sparkles = {}
for i = 1, SPARKLES do
  local tex = Tex("OVERLAY", STAR, 16, 16, 0, 0)
  tex:SetAlpha(0)
  local group = tex:CreateAnimationGroup()
  local grow = Scale(group, 0.2, 1, 0.22)
  grow:SetOrder(1)
  grow:SetSmoothing("OUT")
  local into = Alpha(group, 0, 1, 0.22, nil, 1)
  local drift = group:CreateAnimation("Translation")
  drift:SetOrder(1)
  local fade = Scale(group, 1, 0.2, 0.4)
  fade:SetOrder(2)
  local out = Alpha(group, 1, 0, 0.4, nil, 2)
  local sparkle = { tex = tex, group = group }
  function sparkle.again()
    local db = ns.db
    if not glow:IsShown() or not db or not db.glowAnim or db.glowSparkles == false or Style() ~= "beacon" then return end
    local size = random(12, 22)
    tex:SetSize(size, size)
    tex:ClearAllPoints()
    -- Lower down they sit close to the column, higher up a little wider.
    local y = random(FLOOR, FLOOR + 150)
    local spread = 6 + math.floor((y - FLOOR) / 12)
    tex:SetPoint("CENTER", art, "CENTER", random(-spread, spread), y)
    local delay = random() * 0.9
    grow:SetStartDelay(delay)
    into:SetStartDelay(delay)
    drift:SetStartDelay(delay)
    drift:SetOffset(random(-3, 3), random(4, 12))
    drift:SetDuration(0.22)
    group:Play()
  end
  group:SetScript("OnFinished", sparkle.again)
  group:SetScript("OnStop", function() tex:SetAlpha(0) end)
  art.sparkles[i] = sparkle
end

-- Star and turning rays (sparkle).
art.rays = Tex("BACKGROUND", RAYS, 120, 120, 0, 4, 2)
art.spin = art.rays:CreateAnimationGroup()
art.spin:SetLooping("REPEAT")
local turn = art.spin:CreateAnimation("Rotation")
turn:SetDegrees(-360)
turn:SetDuration(10)
art.star = Tex("ARTWORK", STAR, 56, 56, 0, 4)
art.twinkle = art.star:CreateAnimationGroup()
art.twinkle:SetLooping("BOUNCE")
Scale(art.twinkle, 0.8, 1.12, 0.9):SetSmoothing("IN_OUT")

-- Power aura: two flame shapes standing on the ground around the node,
-- flickering into each other, the whole aura surging up a little.
local aura = CreateFrame("Frame", nil, art)
aura:SetSize(128, 128)
aura:SetPoint("CENTER")
art.auraFrame = aura
local function AuraTex(file, sub)
  local t = aura:CreateTexture(nil, "BACKGROUND", nil, sub)
  t:SetTexture(file, "CLAMP", "CLAMP", "TRILINEAR")
  t:SetBlendMode("ADD")
  t:SetSize(96, 192)
  t:SetPoint("BOTTOM", aura, "CENTER", 0, FLOOR - 14)
  t:Hide()
  pieces[#pieces + 1] = t
  return t
end
art.auraA = AuraTex(AURA_A, 3)
art.auraB = AuraTex(AURA_B, 4)
art.flickA = art.auraA:CreateAnimationGroup()
art.flickA:SetLooping("BOUNCE")
Alpha(art.flickA, 1, 0.3, 0.16)
art.flickB = art.auraB:CreateAnimationGroup()
art.flickB:SetLooping("BOUNCE")
Alpha(art.flickB, 0.3, 1, 0.21)
art.surge = aura:CreateAnimationGroup()
art.surge:SetLooping("BOUNCE")
local surge = Scale(art.surge, 0.95, 1.07, 0.45)
pcall(surge.SetOrigin, surge, "BOTTOM", 0, 0)
surge:SetSmoothing("IN_OUT")

-- Living flames: two copies of the flip book fade into each other so the fire
-- flows smoothly between frames, plus a smaller, whiter heart of the fire
-- running a few frames apart from the outer flames.
local function FireTex(w, h, y, sub)
  local t = aura:CreateTexture(nil, "BACKGROUND", nil, sub)
  t:SetTexture(FIRE, "CLAMP", "CLAMP", "TRILINEAR")
  t:SetBlendMode("ADD")
  t:SetSize(w, h)
  t:SetPoint("BOTTOM", aura, "CENTER", 0, y)
  t:SetTexCoord(0, 0.125, 0, 0.25)
  t:Hide()
  return t
end
art.fireA = FireTex(104, 208, FLOOR - 16, 1)
art.fireB = FireTex(104, 208, FLOOR - 16, 2)
art.coreA = FireTex(60, 120, FLOOR - 12, 5)
art.coreB = FireTex(60, 120, FLOOR - 12, 6)
pieces[#pieces + 1] = art.fireA
pieces[#pieces + 1] = art.fireB

local function FireFrame(tex, i)
  local col = i % 8
  local row = (i - col) / 8
  tex:SetTexCoord(col / 8, (col + 1) / 8, row / 4, (row + 1) / 4)
end

local fireTime, fireWait = 0, 0
local FIRE_LOOP = FIRE_FRAMES / FIRE_FPS
local function FireShow(p)
  local i = math.floor(p)
  local k = p - i
  local j = (i + 13) % FIRE_FRAMES
  FireFrame(art.fireA, i)
  FireFrame(art.fireB, (i + 1) % FIRE_FRAMES)
  FireFrame(art.coreA, j)
  FireFrame(art.coreB, (j + 1) % FIRE_FRAMES)
  art.fireA:SetAlpha(1 - k)
  art.fireB:SetAlpha(k)
  art.coreA:SetAlpha(0.6 * (1 - k))
  art.coreB:SetAlpha(0.6 * k)
end
-- About 30 updates a second, only while the Power aura is on screen.
local function FireUpdate(_, elapsed)
  fireTime = (fireTime + elapsed) % FIRE_LOOP
  fireWait = fireWait + elapsed
  if fireWait < 0.033 then return end
  fireWait = 0
  FireShow(fireTime * FIRE_FPS)
end

-- Power-up (1.9.5): when the aura first lights, it bursts up from the
-- ground past its full size and settles, a shockwave rolls out along the
-- ground and a flash goes off at the peak. Then it keeps surging, with
-- energy waves at its foot and arcs crackling through it.
art.powerUp = aura:CreateAnimationGroup()
local burstUp = Scale(art.powerUp, 0.15, 1.3, 0.32)
burstUp:SetOrder(1)
burstUp:SetSmoothing("OUT")
pcall(burstUp.SetOrigin, burstUp, "BOTTOM", 0, 0)
Alpha(art.powerUp, 0, 1, 0.12, nil, 1)
local settle = Scale(art.powerUp, 1, 1 / 1.3, 0.28)
settle:SetOrder(2)
settle:SetSmoothing("IN_OUT")
pcall(settle.SetOrigin, settle, "BOTTOM", 0, 0)
art.powerUp:SetScript("OnFinished", function()
  if glow:IsShown() and ns.db and ns.db.glowAnim and Style() == "aura" then art.surge:Play() end
end)

art.shock = Tex("OVERLAY", RING, 90, 30, 0, FLOOR)
art.shock:SetAlpha(0)
art.shockAnim = art.shock:CreateAnimationGroup()
local shockGrow = Scale(art.shockAnim, 0.3, 3, 0.6)
shockGrow:SetSmoothing("OUT")
shockGrow:SetStartDelay(0.28)
Alpha(art.shockAnim, 0, 1, 0.05, 0.28)
Alpha(art.shockAnim, 1, 0, 0.55, 0.33)
art.shockAnim:SetScript("OnFinished", function() art.shock:SetAlpha(0) end)

art.blast = Tex("OVERLAY", GLOW, 150, 150, 0, FLOOR + 40)
art.blast:SetAlpha(0)
art.blastAnim = art.blast:CreateAnimationGroup()
Scale(art.blastAnim, 0.6, 1.6, 0.5):SetStartDelay(0.28)
Alpha(art.blastAnim, 0, 1, 0.06, 0.28)
Alpha(art.blastAnim, 1, 0, 0.45, 0.34)
art.blastAnim:SetScript("OnFinished", function() art.blast:SetAlpha(0) end)

-- A ring of energy rolling out from the foot every couple of seconds.
art.wave = Tex("BORDER", RING, 80, 28, 0, FLOOR)
art.wave:SetAlpha(0)
art.waveAnim = art.wave:CreateAnimationGroup()
art.waveAnim:SetLooping("REPEAT")
local waveGrow = Scale(art.waveAnim, 0.4, 1.9, 0.75)
waveGrow:SetSmoothing("OUT")
waveGrow:SetStartDelay(1.1)
Alpha(art.waveAnim, 0, 0.75, 0.08, 1.1)
Alpha(art.waveAnim, 0.75, 0, 0.67, 1.18)
art.waveAnim:SetScript("OnStop", function() art.wave:SetAlpha(0) end)

local function PowerOn()
  return Style() == "aura" and not (ns.db and ns.db.glowPowerUp == false)
end

-- Crackling arcs: each flicks on, stutters and is gone, then strikes
-- again somewhere else a moment later.
art.bolts = {}
for i = 1, 6 do
  local tex = aura:CreateTexture(nil, "ARTWORK", nil, 3)
  tex:SetTexture(BOLT, "CLAMP", "CLAMP", "TRILINEAR")
  tex:SetBlendMode("ADD")
  tex:SetAlpha(0)
  tex:Hide()
  local group = tex:CreateAnimationGroup()
  local on = Alpha(group, 0, 1, 0.03, nil, 1)
  Alpha(group, 1, 0.25, 0.05, nil, 2)
  Alpha(group, 0.25, 1, 0.03, nil, 3)
  Alpha(group, 1, 0, 0.14, nil, 4)
  local bolt = { tex = tex, group = group }
  function bolt.again()
    local db = ns.db
    if not glow:IsShown() or not db or not db.glowAnim or not PowerOn() then return end
    local w = random(22, 34)
    tex:SetSize(w, w * 2)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", aura, "CENTER", random(-38, 38), random(FLOOR + 15, FLOOR + 100))
    local f = random(0, 3)
    if random() < 0.5 then
      tex:SetTexCoord(f / 4, (f + 1) / 4, 0, 1)
    else
      tex:SetTexCoord((f + 1) / 4, f / 4, 0, 1)
    end
    tex:SetRotation((random() - 0.5) * 1.2)
    on:SetStartDelay(0.05 + random() * 0.6)
    group:Play()
  end
  group:SetScript("OnFinished", bolt.again)
  group:SetScript("OnStop", function() tex:SetAlpha(0) end)
  art.bolts[i] = bolt
end

-- The flash when it comes into reach: a bright ring bursting out and the
-- light swelling for a moment.
art.flash = Tex("OVERLAY", RING, 76, 76, 0, 0)
art.flash:SetAlpha(0)
art.flashAnim = art.flash:CreateAnimationGroup()
Scale(art.flashAnim, 0.4, 2.2, 0.55):SetSmoothing("OUT")
Alpha(art.flashAnim, 0, 1, 0.08)
Alpha(art.flashAnim, 1, 0, 0.47, 0.08)
art.flashAnim:SetScript("OnFinished", function() art.flash:SetAlpha(0) end)
art.burst = Tex("ARTWORK", GLOW, 90, 90, 0, 0, 7)
art.burst:SetAlpha(0)
art.burstAnim = art.burst:CreateAnimationGroup()
Scale(art.burstAnim, 0.7, 1.5, 0.5):SetSmoothing("OUT")
Alpha(art.burstAnim, 0, 0.9, 0.1)
Alpha(art.burstAnim, 0.9, 0, 0.4, 0.1)
art.burstAnim:SetScript("OnFinished", function() art.burst:SetAlpha(0) end)

-- Small lights that rise and fade, somewhere new each time. Which picture,
-- how many and how high depends on the style.
local MOTES = {
  sparkle = { file = STAR, n = 5, spread = 30, low = -8, high = 22, up = { 6, 14 }, size = { 12, 22 }, wait = 1.4 },
  beacon = { file = SPARK, n = 4, spread = 6, low = FLOOR, high = 10, up = { 50, 90 }, size = { 8, 14 }, wait = 1.2 },
  embers = { file = SPARK, n = 8, spread = 26, low = FLOOR, high = 4, up = { 30, 70 }, size = { 6, 12 }, wait = 1.0 },
  aura = { file = STREAK, n = 8, spread = 30, low = FLOOR, high = 20, up = { 70, 120 }, size = { 5, 8 }, tall = 4, wait = 0.6 },
  -- Embers drifting off the top of the living flames.
  fire = { file = SPARK, n = 7, spread = 22, low = FLOOR + 20, high = FLOOR + 70, up = { 50, 100 }, size = { 4, 8 }, wait = 0.7 },
}
local MAX_MOTES = 8

-- Living flames are on for the Power aura unless switched off.
local function FireOn()
  return Style() == "aura" and not (ns.db and ns.db.glowFire == false)
end
local function MoteSet()
  if FireOn() then return MOTES.fire end
  return MOTES[Style()]
end
art.motes = {}
for i = 1, MAX_MOTES do
  local tex = Tex("OVERLAY", SPARK, 10, 10, 0, 0)
  tex:SetAlpha(0)
  local group = tex:CreateAnimationGroup()
  local fadeIn = Alpha(group, 0, 1, 0.4, nil, 1)
  local rise = group:CreateAnimation("Translation")
  rise:SetOrder(1)
  local fadeOut = Alpha(group, 1, 0, 0.5, nil, 2)
  local mote = { tex = tex, group = group }
  function mote.again()
    if not glow:IsShown() or not ns.db or not ns.db.glowAnim then return end
    local p = MoteSet()
    if not p or i > p.n then return end
    local size = random(p.size[1], p.size[2])
    tex:SetSize(size, size * (p.tall or 1))
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", art, "CENTER", random(-p.spread, p.spread), random(p.low, p.high))
    local time = 0.3 + random() * 0.5
    local delay = random() * p.wait
    fadeIn:SetDuration(time)
    fadeIn:SetStartDelay(delay)
    rise:SetOffset(random(-4, 4), random(p.up[1], p.up[2]))
    rise:SetDuration(time + 0.5)
    rise:SetStartDelay(delay)
    fadeOut:SetDuration(0.4 + random() * 0.4)
    group:Play()
  end
  group:SetScript("OnFinished", mote.again)
  art.motes[i] = mote
end

-- The node's name under the light, in the game's skill colour.
glow.label = glow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
glow.label:SetPoint("TOP", glow, "CENTER", 0, -30)
glow.label:SetShadowOffset(1, -1)
glow.label:SetShadowColor(0, 0, 0, 1)

local LOOPS = { "breathe", "rippleAnim", "bandAnim", "shimmer", "shimmer2", "pulseA", "pulseB", "spin", "twinkle", "flickA", "flickB", "surge" }

local function StopMotion()
  for _, key in ipairs(LOOPS) do art[key]:Stop() end
  art.flashAnim:Stop()
  art.burstAnim:Stop()
  art.flash:SetAlpha(0)
  art.burst:SetAlpha(0)
  art.ripple:SetAlpha(0)
  for _, m in ipairs(art.motes) do
    m.group:Stop()
    m.tex:SetAlpha(0)
  end
  for _, sp in ipairs(art.sparkles) do
    sp.group:Stop()
    sp.tex:SetAlpha(0)
  end
  art.auraFrame:SetScript("OnUpdate", nil)
  art.powerUp:Stop()
  art.shockAnim:Stop()
  art.blastAnim:Stop()
  art.waveAnim:Stop()
  art.shock:SetAlpha(0)
  art.blast:SetAlpha(0)
  for _, b in ipairs(art.bolts) do b.group:Stop() end
end

-- Which pieces each style shows, and the loops it plays.
local SHOW = {
  halo = { halo = true, ripple = true, loops = { "breathe", "rippleAnim" } },
  beacon = { beam = true, core = true, pool = true, ripple = true, pulse1 = true, pulse2 = true,
    loops = { "shimmer", "shimmer2", "pulseA", "pulseB", "rippleAnim" } },
  sparkle = { rays = true, star = true, halo = true, loops = { "spin", "twinkle", "breathe" } },
  ring = { band = true, ripple = true, pool = true, loops = { "bandAnim", "rippleAnim" } },
  embers = { halo = true, loops = { "breathe" } },
  aura = { auraA = true, auraB = true, halo = true, loops = { "flickA", "flickB", "surge", "breathe" } },
}

local PARTS = { "halo", "pool", "ripple", "band", "beam", "core", "rays", "star", "auraA", "auraB", "pulse1", "pulse2" }
local function ApplyStyle()
  local style = Style()
  local show = SHOW[style]
  for _, key in ipairs(PARTS) do
    art[key]:SetShown(show[key] == true)
  end
  -- Embers keep their glow low and small; the sparkle's sits behind the star.
  local low = style == "embers" or style == "aura"
  local haloSize = (low and 80) or (style == "sparkle" and 70) or 112
  art.halo:SetSize(haloSize, low and 60 or haloSize)
  art.halo:ClearAllPoints()
  art.halo:SetPoint("CENTER", art, "CENTER", 0, low and FLOOR + 6 or 0)
  art.auraA:SetAlpha(1)
  art.auraB:SetAlpha(0.3)
  local fire = FireOn()
  if fire then
    art.auraA:Hide()
    art.auraB:Hide()
  end
  art.fireA:SetShown(fire)
  art.fireB:SetShown(fire)
  art.coreA:SetShown(fire)
  art.coreB:SetShown(fire)
  if fire then FireShow(0) end
  local power = PowerOn()
  art.shock:SetShown(power)
  art.blast:SetShown(power)
  art.wave:SetShown(power)
  for _, b in ipairs(art.bolts) do b.tex:SetShown(power) end
  art.halo:SetAlpha(style == "sparkle" and 0.6 or 1)
  art.ripple:SetAlpha(0)
  art.pool:SetAlpha(style == "ring" and 0.45 or 0.6)
  local p = MoteSet()
  for i, m in ipairs(art.motes) do
    m.tex:SetTexture(p and p.file or SPARK, "CLAMP", "CLAMP", "TRILINEAR")
    m.tex:SetShown(p ~= nil and i <= p.n)
  end
  local sparkles = style == "beacon" and not (ns.db and ns.db.glowSparkles == false)
  for _, sp in ipairs(art.sparkles) do sp.tex:SetShown(sparkles) end
  art.pulse1:SetAlpha(0)
  art.pulse2:SetAlpha(0)
  art.flash:Show()
  art.burst:Show()
end

local function StartMotion()
  StopMotion()
  ApplyStyle()
  if not ns.db or not ns.db.glowAnim then return end -- a still light
  local fire = FireOn()
  for _, key in ipairs(SHOW[Style()].loops) do
    -- The living flames move by themselves; the old flicker isn't needed.
    -- With the power-up the surge waits until the burst has settled.
    if not (fire and (key == "flickA" or key == "flickB")) and not (key == "surge" and PowerOn()) then
      art[key]:Play()
    end
  end
  if PowerOn() then
    art.powerUp:Play()
    art.shockAnim:Play()
    art.blastAnim:Play()
    art.waveAnim:Play()
    for _, b in ipairs(art.bolts) do b.again() end
  end
  if fire then
    fireTime, fireWait = 0, 1
    art.auraFrame:SetScript("OnUpdate", FireUpdate)
  end
  for _, m in ipairs(art.motes) do m.again() end
  for _, sp in ipairs(art.sparkles) do sp.again() end
end

local function Flash()
  if not ns.db or not ns.db.glowFlash then return end
  art.flashAnim:Stop()
  art.burstAnim:Stop()
  art.flashAnim:Play()
  art.burstAnim:Play()
end

local tintNow -- the colour table in use, so it's only set when it changes
local function Tint(color)
  if tintNow == color then return end
  tintNow = color
  for _, t in ipairs(pieces) do t:SetVertexColor(color[1], color[2], color[3]) end
  -- The heart of the fire burns whiter than its edges.
  local r, g, b = color[1] + (1 - color[1]) * 0.6, color[2] + (1 - color[2]) * 0.6, color[3] + (1 - color[3]) * 0.6
  art.coreA:SetVertexColor(r, g, b)
  art.coreB:SetVertexColor(r, g, b)
  for _, bolt in ipairs(art.bolts) do bolt.tex:SetVertexColor(r, g, b) end
end

-- How strong the light is in each state (times "Brightness").
local STATE_ALPHA = { far = 0.38, ready = 1, locked = 0.6 }

local function Look()
  local db = ns.db
  local scale = math.max(0.3, (tonumber(db.glowSize) or 100) / 100)
  art:SetScale(scale)
  glow.label:ClearAllPoints()
  glow.label:SetPoint("TOP", glow, "CENTER", 0, -12 - 18 * scale)
  glow.label:SetShown(db.glowName and true or false)
end

glow:SetScript("OnHide", StopMotion)

------------------------------------------------------------------------
-- The game's name plate on the object
------------------------------------------------------------------------

local dimmed -- the game's own icon, made see-through while we light it
local function RestoreIcon()
  if dimmed then pcall(dimmed.SetAlpha, dimmed, 1) end
  dimmed = nil
end

local function ReadGameIcon(plate)
  return plate.UnitFrame.SoftTargetFrame.Icon
end

local function GameIcon(plate)
  local ok, icon = pcall(ReadGameIcon, plate)
  if ok and type(icon) == "table" and icon.SetAlpha then return icon end
end

local activeUnits = {}

local function CheckPlate(plate)
  if type(plate) ~= "table" or Secret(plate) then return end
  if plate.IsForbidden then
    local okF, forbidden = pcall(plate.IsForbidden, plate)
    if not okF or forbidden then return end
  end
  return plate
end

local function SoftPlate()
  if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
  local plate = CheckPlate(Read(C_NamePlate.GetNamePlateForUnit, SOFT))
  if plate then return plate end
  if UnitIsUnit then
    for unit in pairs(activeUnits) do
      if Read(UnitIsUnit, unit, SOFT) == true then
        plate = CheckPlate(Read(C_NamePlate.GetNamePlateForUnit, unit))
        if plate then return plate end
      end
    end
  end
end

------------------------------------------------------------------------
-- What's in front of you
------------------------------------------------------------------------

local probe = glow:CreateTexture(nil, "BACKGROUND")
probe:Hide()

-- The game's cursor for the object names what it is ("...Mine", "...Gather")
-- and turns "Unable..." when you can't use it right now. Depending on the
-- game it's a file path or an atlas name, so look for words in it.
local CURSOR_WORDS = { { "gather", "herb" }, { "herb", "herb" }, { "mine", "ore" }, { "mining", "ore" },
  { "fishing", "bobber" }, { "lootall", "treasure" }, { "picklock", "treasure" } }
local function Words(text, kind, unable)
  if type(text) ~= "string" or Secret(text) then return kind, unable end
  text = text:lower()
  if text:find("unable", 1, true) then unable = true end
  if not kind then
    for _, w in ipairs(CURSOR_WORDS) do
      if text:find(w[1], 1, true) then return w[2], unable end
    end
  end
  return kind, unable
end

local function ReadCursor()
  if not SetUnitCursorTexture then return nil, false end
  local ok, set = pcall(SetUnitCursorTexture, probe, SOFT, nil, true)
  if not ok or set ~= true then return nil, false end
  local kind, unable = Words(Read(probe.GetTexture, probe), nil, false)
  if probe.GetAtlas then kind, unable = Words(Read(probe.GetAtlas, probe), kind, unable) end
  return kind, unable
end

-- Is the player fishing right now?
local FISHING = { [7620] = true, [7731] = true, [7732] = true, [18248] = true, [33095] = true, [51294] = true, [88868] = true, [131474] = true }
local function Fishing()
  if not UnitChannelInfo then return false end
  local ok, name, _, _, _, _, _, _, spellID = pcall(UnitChannelInfo, "player")
  if not ok or Secret(name) then return false end
  if not Secret(spellID) and FISHING[spellID] then return true end
  local fishing = GetSpellInfo and Read(GetSpellInfo, 7620) or (C_Spell and C_Spell.GetSpellName and Read(C_Spell.GetSpellName, 7620))
  return name ~= nil and name == fishing
end

-- Do you have the profession that gathers it? true/false, or nil when the
-- game won't say (then it glows anyway).
local FINDERS = { herb = { 2383, 8387 }, ore = { 2580, 8388 } }
local function Trained(kind)
  local finders = FINDERS[kind]
  if not finders then return true end
  local known = (C_SpellBook and C_SpellBook.IsSpellKnown) or IsPlayerSpell
  local answered = false
  if known then
    for _, id in ipairs(finders) do
      local v = Read(known, id)
      if v == true then return true end
      if v == false then answered = true end
    end
  end
  local rank = ns.SkillRank and ns.SkillRank(kind)
  if type(rank) == "number" then
    if rank > 0 then return true end
    answered = true
  end
  if answered then return false end
  return nil
end

local target = { kind = nil, name = nil, guid = nil, low = false, state = nil, plate = nil }
local preview = false
ns.glowWhy = "nothing in front of you"

-- Work out what the soft-interact object is (once, when it changes).
local function Classify(guid)
  target.kind, target.name, target.low = nil, nil, false
  if Secret(guid) or type(guid) ~= "string" then guid = Read(UnitGUID, SOFT) end
  target.guid = guid
  if not guid and not Read(UnitExists, SOFT) and not Read(UnitIsGameObject, SOFT) then
    ns.glowWhy = "nothing in front of you"
    return
  end
  -- Objects only: people and creatures have their own plates.
  if type(guid) == "string" and not guid:find("^GameObject") then
    ns.glowWhy = "in front of you: not an object"
    return
  end
  local raw = Read(UnitName, SOFT)
  local name = type(raw) == "string" and raw ~= "" and ns.Canon(raw) or nil
  local kind = name and ns.Category(name) or nil
  local id = type(guid) == "string" and tonumber(guid:match("^GameObject%-%d+%-%d+%-%d+%-%d+%-(%d+)")) or nil
  if id == BOBBER then kind = "bobber" end
  if not kind then
    local cursorKind = ReadCursor()
    -- The bobber has no cursor of its own; one picked while you fish is it.
    if cursorKind == "bobber" or (not cursorKind and not id and Fishing()) then
      kind = "bobber"
    else
      kind = cursorKind
    end
  end
  target.name = raw
  if not kind then
    ns.glowWhy = "in front of you: " .. tostring(raw or "?") .. " (not a herb, vein, chest or bobber)"
    return
  end
  local db = ns.db
  if name and ns.Category(name) and not ns.IsShownName(name) then
    ns.glowWhy = tostring(raw) .. " is unticked in the node list"
    return
  end
  if db.glowKinds and db.glowKinds[kind] == false then
    ns.glowWhy = tostring(raw or kind) .. ": that kind is switched off"
    return
  end
  if db.glowOnlyMine and Trained(kind) == false then
    ns.glowWhy = tostring(raw or kind) .. ": you don't have that profession"
    return
  end
  -- Skill too low (WoW Forever and Classic know the numbers): grey.
  if name and ns.SkillInfo then
    local need, have = ns.SkillInfo(name)
    if need and have and have < need then target.low = true end
  end
  target.kind = kind
  ns.glowWhy = "glowing: " .. tostring(raw or kind)
end

local function ReadState()
  if target.low then return "locked" end
  local _, unable = ReadCursor()
  local inRange = UnitIsInInteractRange and Read(UnitIsInInteractRange, SOFT)
  if inRange == false then return "far" end
  if unable then return inRange == true and "locked" or "far" end
  return "ready"
end

local inCombat = false
local function Allowed()
  local db = ns.db
  if not db or not db.glow or ns.GlowBlockedBy() then return false end
  if db.glowCombat and inCombat then return false end
  if db.glowInstance and IsInInstance and Read(IsInInstance) then return false end
  return true
end

local function SetLabel()
  local name = target.name
  if type(name) ~= "string" then
    glow.label:SetText("")
    return
  end
  local canon = ns.Canon(name)
  local need, have, color, skill = nil, nil, nil, nil
  if ns.SkillInfo then need, have, color, skill = ns.SkillInfo(canon) end
  if target.low and need then
    glow.label:SetText(name .. "\n|cffff2020" .. tostring(skill) .. " " .. need .. "|r")
  elseif color then
    glow.label:SetText("|cff" .. color .. name .. "|r")
  else
    glow.label:SetText(name)
  end
end

local function Hide()
  RestoreIcon()
  target.plate, target.state = nil, nil
  glow._alpha = nil
  glow:Hide()
end

-- Put the light on the plate (or move it), in the right colour and strength.
local function Show(plate, state)
  local db = ns.db
  local fresh = not glow:IsShown()
  if target.plate ~= plate or fresh then
    RestoreIcon()
    target.plate = plate
    local icon = GameIcon(plate)
    local iconVis = icon and icon.IsVisible and Read(icon.IsVisible, icon) == true
    glow:ClearAllPoints()
    local ok = pcall(glow.SetPoint, glow, "CENTER", (iconVis and icon) or plate, "CENTER", 0, tonumber(db.glowHeight) or 0)
    if not ok then
      Hide()
      return
    end
    if icon and db.glowHideIcon then
      pcall(icon.SetAlpha, icon, 0)
      dimmed = icon
    end
  end
  Tint(state == "locked" and GREY or COLOR[target.kind] or COLOR.herb)
  local alpha = (STATE_ALPHA[state] or 1) * (tonumber(db.glowBright) or 85) / 100
  if glow._alpha ~= alpha then
    glow:SetAlpha(alpha)
    glow._alpha = alpha
  end
  if fresh then
    Look()
    SetLabel()
    glow:Show()
    StartMotion()
  end
  if state == "ready" and target.state ~= "ready" then Flash() end
  target.state = state
end

local ticker = CreateFrame("Frame")
local acc = 0
local Refresh, ShowPool

local function Tick(_, elapsed)
  acc = acc + elapsed
  if acc < 0.16 then return end
  acc = 0
  Refresh()
end

-- Everything that can change while the same object is in front of you:
-- reach, a name plate appearing, combat.
function Refresh()
  if preview then return end
  if not target.kind or not Allowed() then
    Hide()
    ticker:SetScript("OnUpdate", nil)
    if not target.kind then ShowPool() end
    return
  end
  ticker:SetScript("OnUpdate", Tick)
  local plate = SoftPlate()
  if not plate then
    Hide()
    return
  end
  Show(plate, ReadState())
end

------------------------------------------------------------------------
-- Fishing pools (1.9.2)
------------------------------------------------------------------------

-- You can't click a fishing pool, so the game never picks it and it never
-- gets a name plate. Instead Gather Labels marks the nearest pool with the
-- game's map pin (Mark.lua) and the glow sits on that pin, in teal. The
-- node in front of you (your bobber, a herb) still comes first.
local poolAt = { anchor = nil, name = nil, dim = false }

function ShowPool()
  local db = ns.db
  if preview or target.kind or not poolAt.anchor or not Allowed()
      or (db.glowKinds and db.glowKinds.fish == false) then
    return false
  end
  local fresh = not glow:IsShown() or target.plate ~= poolAt.anchor
  if fresh then
    Hide()
    glow:ClearAllPoints()
    if not pcall(glow.SetPoint, glow, "CENTER", poolAt.anchor, "CENTER", 0, 0) then return false end
    target.plate = poolAt.anchor
    target.name, target.low = poolAt.name, false
  end
  Tint(COLOR.fish)
  glow:SetAlpha((poolAt.dim and STATE_ALPHA.far or 1) * (tonumber(db.glowBright) or 85) / 100)
  if fresh then
    Look()
    SetLabel()
    glow:Show()
    StartMotion()
    Flash()
  end
  return true
end

-- Mark.lua: anchor = the game's marker on the pool (nil: no pool now).
-- Returns true when the glow is on it.
function ns.GlowOnPool(anchor, name, dim)
  if preview then return false end
  poolAt.anchor, poolAt.name, poolAt.dim = anchor, name, dim
  if not anchor then
    if not target.kind and target.plate and glow:IsShown() then Hide() end
    return false
  end
  return ShowPool()
end

local function NewTarget(guid)
  if preview then return end
  Hide()
  Classify(guid)
  Refresh()
end

------------------------------------------------------------------------
-- Settings, preview, debug
------------------------------------------------------------------------

-- Any glow setting changed.
function ns.GlowChanged(key)
  if not ns.db then return end
  if key == "glow" or key == "glowRange" then ApplyCVars() end
  if preview then
    if glow:IsShown() then
      Look()
      StartMotion()
    end
    return
  end
  if key == "glow" or key == "glowKinds" or key == "glowOnlyMine" then
    if ns.ShineChanged then ns.ShineChanged() end -- pools marked or not
    NewTarget(target.guid)
    return
  end
  if glow:IsShown() then
    local plate = target.plate
    target.plate = nil -- re-anchor (height, icon)
    RestoreIcon()
    glow:Hide()
    if plate then Show(plate, ReadState()) end
  end
  Refresh()
end

-- The light in the middle of the screen for a few seconds: out of reach,
-- then in reach (with the flash), then grey.
local previewToken = 0
local SAMPLE = { herb = "Peacebloom", ore = "Copper Vein", treasure = "Battered Chest", fish = "Oily Blackmouth School", bobber = "Fishing Bobber" }
function ns.GlowPreview(kind)
  if not ns.db then return end
  previewToken = previewToken + 1
  local token = previewToken
  Hide()
  preview = true
  kind = COLOR[kind] and kind or "herb"
  target.kind, target.name, target.low = kind, SAMPLE[kind], false
  glow:ClearAllPoints()
  glow:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
  local function Step(state, after)
    if token ~= previewToken then return end
    local db = ns.db
    Tint(state == "locked" and GREY or COLOR[kind])
    glow:SetAlpha((STATE_ALPHA[state] or 1) * (tonumber(db.glowBright) or 85) / 100)
    if not glow:IsShown() then
      Look()
      SetLabel()
      glow:Show()
      StartMotion()
    end
    if state == "ready" then Flash() end
    if after then after() end
  end
  Step("far")
  C_Timer.After(1.2, function() Step("ready") end)
  C_Timer.After(3.6, function() Step("locked") end)
  C_Timer.After(5, function()
    if token ~= previewToken then return end
    preview = false
    Hide()
    NewTarget(nil)
  end)
end

function ns.GlowDebug()
  local cv = {}
  for _, n in ipairs(NAMES) do cv[#cv + 1] = n:gsub("SoftTarget", ""):gsub("nameplate", "") .. "=" .. tostring(GetCV(n)) end
  local plate = SoftPlate()
  local icon = plate and GameIcon(plate)
  local iconVis = icon and icon.IsVisible and Read(icon.IsVisible, icon) == true
  local pInfo = plate and (" plate=yes iconVis=" .. (iconVis and "yes" or "no")) or " plate=no"
  ns.Print("glow: " .. (ns.db.glow and "on" or "off")
    .. (ns.GlowBlockedBy() and (", left to " .. ns.GlowBlockedBy()) or "")
    .. (inCombat and ", in combat" or "") .. ". " .. tostring(ns.glowWhy)
    .. (target.state and (" (" .. target.state .. ")") or "")
    .. pInfo)
  ns.Print("game settings: " .. table.concat(cv, " "))
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local function ReadPlateUnitToken(plate)
  return plate.namePlateUnitToken
end

local events = CreateFrame("Frame")
events:RegisterEvent("VARIABLES_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("CVAR_UPDATE")
events:RegisterEvent("SKILL_LINES_CHANGED")
local reapply = false
events:SetScript("OnEvent", function(_, event, a, b)
  if not ns.db then return end
  if event == "PLAYER_SOFT_INTERACT_CHANGED" then
    NewTarget(b)
  elseif event == "NAME_PLATE_UNIT_ADDED" then
    if type(a) == "string" and not Secret(a) then activeUnits[a] = true end
    if target.kind and not glow:IsShown() then
      Refresh()
    elseif not target.kind and UnitIsUnit and Read(UnitIsUnit, a, SOFT) == true then
      NewTarget(nil)
    end
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    if type(a) == "string" and not Secret(a) then activeUnits[a] = nil end
    -- That plate may be handed to something else now.
    if target.plate and not preview then
      local ok, token = pcall(ReadPlateUnitToken, target.plate)
      if not ok or token == a then
        Hide()
        Refresh()
      end
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    inCombat = true
    Refresh()
  elseif event == "PLAYER_REGEN_ENABLED" then
    inCombat = false
    if waitingForCombat then
      waitingForCombat = false
      ApplyCVars()
    end
    Refresh()
  elseif event == "SKILL_LINES_CHANGED" then
    if target.guid then NewTarget(target.guid) end
  elseif event == "CVAR_UPDATE" then
    -- Something else (Tight Lines after fishing, another addon, the game's
    -- options) changed one of ours while the glow wants it: put it back.
    local name = type(a) == "string" and not Secret(a) and LOWER[a:lower()]
    if name and not reapply then
      local want = Wanted()[name]
      if want and GetCV(name) ~= want then
        reapply = true
        C_Timer.After(2, function()
          reapply = false
          ApplyCVars()
        end)
      end
    end
  elseif event == "VARIABLES_LOADED" then
    ApplyCVars()
  elseif event == "PLAYER_ENTERING_WORLD" then
    inCombat = (UnitAffectingCombat and Read(UnitAffectingCombat, "player")) == true
    ApplyCVars()
    NewTarget(nil)
  elseif event == "PLAYER_LOGOUT" then
    RestoreIcon()
    ReturnCVars()
  end
end)
