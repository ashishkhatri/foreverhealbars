-- Forever Heal Bars: a minimalist grid of party/raid frames for healers.
-- Click-casting, your HoTs, dispellable debuffs, incoming heals, range and aggro.

local ADDON = ...
local PREFIX = "|cff33ff99Forever Heal Bars|r: "

local W, H, GAP = 72, 46, 3          -- button size and spacing
local MAX_BUTTONS = 40
local OOR_DIM = 0.65                  -- darkness of the overlay on out-of-range players
local HOT_SIZE, MAX_HOTS = 11, 3
local INC_EASE = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut
local POWER_H = 3                     -- height of the resource bar
local SHIELD_H = 6                    -- height of the shield (absorb) bar
local BAR = "Interface\\Buttons\\WHITE8X8"

local DB, charKey
local header, anchor, mover
local buttons = {}                    -- every unit button the header made
local byUnit = {}                     -- unit token -> { button, ... }
local pending = {}                    -- functions waiting for combat to end
local OnMenuClick                     -- defined with the unit buttons

local MODS = { "", "shift-", "ctrl-", "alt-" }
local MOD_LABEL = { [""] = "Click", ["shift-"] = "Shift", ["ctrl-"] = "Ctrl", ["alt-"] = "Alt" }
local CLICKS = { 1, 2, 3, 4, 5 }
local CLICK_LABEL = { "Left", "Right", "Middle", "Mouse 4", "Mouse 5" }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Msg(fmt, ...) print(PREFIX .. string.format(fmt, ...)) end

-- false for nil and for values the game hides from addons ("secret")
local function Readable(v)
    return v ~= nil and not (issecretvalue and issecretvalue(v))
end

-- Run now, or as soon as combat ends (secure frames can't change in combat).
local function OutOfCombat(fn)
    if InCombatLockdown() then
        pending[#pending + 1] = fn
        return false
    end
    fn()
    return true
end

local function AuraAt(unit, i, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local a = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
        if a then return a.name, a.icon, a.dispelName, a.duration end
        return nil
    end
    local name, icon, _, dtype, duration = UnitAura(unit, i, filter)
    return name, icon, dtype, duration
end

local SpellInfo = (C_Spell and C_Spell.GetSpellInfo) and function(s)
    local info = C_Spell.GetSpellInfo(s)
    return info and info.name, info and info.iconID
end or function(s)
    local name, _, icon = GetSpellInfo(s)
    return name, icon
end

-- Indicator colours, chosen to stay clearly apart from each other (and from
-- class colours as far as possible).
local DEBUFF_COLOR = {
    Magic = { r = 0.16, g = 0.27, b = 1 },      -- deep royal blue
    Curse = { r = 0.88, g = 0.12, b = 0.82 },   -- magenta
    Disease = { r = 0.92, g = 0.12, b = 0.12 }, -- red
    Poison = { r = 0, g = 0.78, b = 0.59 },     -- teal green
}
local AGGRO_COLOR = { 1, 0.59, 0 }               -- amber
local INC_COLOR = { 0.67, 1, 0.47 }              -- bright lime

-- Default click-casting per class. Keys: modifier prefix + mouse button
-- (1 left, 2 right, 3 middle). Healers get their main heals on plain clicks,
-- with target / menu moved to Alt. Spells a character hasn't learned yet
-- simply do nothing (they show red in /fhb).
local HEALER_EXTRAS = { ["alt-1"] = "target", ["alt-2"] = "menu" }
-- Dispels are on Ctrl + left / right.
local CLASS_DEFAULTS = {
    PRIEST = {
        ["1"] = "Flash Heal", ["2"] = "Renew",
        ["shift-1"] = "Greater Heal", ["shift-2"] = "Power Word: Shield",
        ["ctrl-1"] = "Dispel Magic", ["ctrl-2"] = "Cure Disease",
    },
    DRUID = {
        ["1"] = "Healing Touch", ["2"] = "Rejuvenation",
        ["shift-1"] = "Regrowth",
        ["ctrl-1"] = "Remove Curse", ["ctrl-2"] = "Cure Poison",
    },
    PALADIN = {
        ["1"] = "Flash of Light", ["2"] = "Holy Light",
        ["shift-2"] = "Blessing of Protection",
        ["ctrl-1"] = "Cleanse",
    },
    SHAMAN = {
        ["1"] = "Healing Wave", ["2"] = "Lesser Healing Wave",
        ["shift-1"] = "Chain Heal",
        ["ctrl-1"] = "Cure Poison", ["ctrl-2"] = "Cure Disease",
    },
    MAGE = { ["ctrl-1"] = "Remove Lesser Curse" },
}
for _, t in pairs(CLASS_DEFAULTS) do
    if t["1"] then for k, v in pairs(HEALER_EXTRAS) do t[k] = v end end
end

-- Earlier default sets, so characters that never changed them get upgraded.
local V021 = {
    PRIEST = { ["1"] = "Flash Heal", ["2"] = "Renew", ["shift-1"] = "Greater Heal",
        ["shift-2"] = "Power Word: Shield", ["3"] = "Dispel Magic", ["shift-3"] = "Cure Disease" },
    DRUID = { ["1"] = "Healing Touch", ["2"] = "Rejuvenation", ["shift-1"] = "Regrowth",
        ["3"] = "Remove Curse", ["shift-3"] = "Cure Poison" },
    PALADIN = { ["1"] = "Flash of Light", ["2"] = "Holy Light",
        ["shift-2"] = "Blessing of Protection", ["3"] = "Cleanse" },
    SHAMAN = { ["1"] = "Healing Wave", ["2"] = "Lesser Healing Wave", ["shift-1"] = "Chain Heal",
        ["3"] = "Cure Poison", ["shift-3"] = "Cure Disease" },
    MAGE = { ["3"] = "Remove Lesser Curse" },
}
for _, t in pairs(V021) do
    if t["1"] then for k, v in pairs(HEALER_EXTRAS) do t[k] = v end end
end
local V020 = {
    PRIEST = { ["shift-1"] = "Flash Heal", ["ctrl-1"] = "Greater Heal", ["alt-1"] = "Renew",
        ["shift-2"] = "Power Word: Shield", ["3"] = "Dispel Magic", ["shift-3"] = "Cure Disease" },
    DRUID = { ["shift-1"] = "Healing Touch", ["ctrl-1"] = "Regrowth", ["alt-1"] = "Rejuvenation",
        ["3"] = "Remove Curse", ["shift-3"] = "Cure Poison" },
    PALADIN = { ["shift-1"] = "Flash of Light", ["ctrl-1"] = "Holy Light",
        ["shift-2"] = "Blessing of Protection", ["3"] = "Cleanse" },
    SHAMAN = { ["shift-1"] = "Lesser Healing Wave", ["ctrl-1"] = "Healing Wave", ["alt-1"] = "Chain Heal",
        ["3"] = "Cure Poison", ["shift-3"] = "Cure Disease" },
}

local OLD_DEFAULTS = { V020, V021 }

local function SameBinds(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

local function ClassDefaults()
    local _, class = UnitClass("player")
    local t = {}
    for k, v in pairs(CLASS_DEFAULTS[class] or {}) do t[k] = v end
    return t
end

local function Binds()
    if not DB.binds[charKey] then
        DB.binds[charKey] = ClassDefaults()
    end
    return DB.binds[charKey]
end

---------------------------------------------------------------------------
-- Visuals on each unit button
---------------------------------------------------------------------------
local function Border(parent, inset, size, layer)
    local b = {}
    for i = 1, 4 do b[i] = parent:CreateTexture(nil, layer or "OVERLAY") end
    b[1]:SetPoint("TOPLEFT", -inset, inset);      b[1]:SetPoint("TOPRIGHT", inset, inset);       b[1]:SetHeight(size)
    b[2]:SetPoint("BOTTOMLEFT", -inset, -inset);  b[2]:SetPoint("BOTTOMRIGHT", inset, -inset);   b[2]:SetHeight(size)
    b[3]:SetPoint("TOPLEFT", -inset, inset);      b[3]:SetPoint("BOTTOMLEFT", -inset, -inset);   b[3]:SetWidth(size)
    b[4]:SetPoint("TOPRIGHT", inset, inset);      b[4]:SetPoint("BOTTOMRIGHT", inset, -inset);   b[4]:SetWidth(size)
    function b:Set(r, g, bl)
        for i = 1, 4 do
            if r then self[i]:SetColorTexture(r, g, bl, 1); self[i]:Show() else self[i]:Hide() end
        end
    end
    function b:SetAlpha(a)
        for i = 1, 4 do self[i]:SetAlpha(a) end
    end
    b:Set(nil)
    return b
end

local BuildDispelFx                   -- defined with the dispel effect below

local function Build(btn)
    -- everything visual lives on a plain child frame, so fading it for range
    -- never touches the secure button
    local c = CreateFrame("Frame", nil, btn)
    c:SetAllPoints()
    btn.c = c
    btn.classColor = { 0.3, 0.8, 0.3 }

    local bg = c:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.13, 0.17, 0.9)


    -- resource bar: a thin strip along the bottom
    local pw = CreateFrame("StatusBar", nil, c)
    pw:SetPoint("BOTTOMLEFT")
    pw:SetPoint("BOTTOMRIGHT")
    pw:SetHeight(POWER_H)
    pw:SetStatusBarTexture(BAR)
    pw:SetMinMaxValues(0, 1)
    local pwbg = pw:CreateTexture(nil, "BACKGROUND")
    pwbg:SetAllPoints()
    pwbg:SetColorTexture(0, 0, 0, 0.6)
    c.power = pw

    -- mana an in-progress cast will spend: a lighter section at the end of the
    -- power fill, growing back from the current amount
    local cost = CreateFrame("StatusBar", nil, pw)
    cost:SetStatusBarTexture(BAR)
    cost:SetReverseFill(true)
    cost:SetPoint("TOPRIGHT", pw:GetStatusBarTexture(), "TOPRIGHT")
    cost:SetPoint("BOTTOMRIGHT", pw:GetStatusBarTexture(), "BOTTOMRIGHT")
    cost:SetWidth(W)
    cost:SetMinMaxValues(0, 1)
    cost:SetValue(0)
    cost:Hide()
    c.powerCost = cost

    local hp = CreateFrame("StatusBar", nil, c)
    hp:SetPoint("TOPLEFT")
    hp:SetPoint("BOTTOMRIGHT", 0, POWER_H)
    hp:SetStatusBarTexture(BAR)
    hp:SetMinMaxValues(0, 1)
    c.hp = hp

    -- Damage flash: a bar just under the health bar that briefly keeps the
    -- previous health. The chunk just lost shows past the health fill as a
    -- light, striped segment, then snaps away.
    local dmg = CreateFrame("StatusBar", nil, c)
    dmg:SetAllPoints(hp)
    dmg:SetStatusBarTexture(BAR)
    dmg:SetMinMaxValues(0, 1)
    dmg:SetValue(0)
    dmg:Hide()
    local stripes = dmg:CreateTexture(nil, "ARTWORK", nil, 1)
    stripes:SetTexture(string.format("Interface\\AddOns\\%s\\media\\stripes", ADDON), "REPEAT", "REPEAT")
    stripes:SetHorizTile(true)
    stripes:SetVertTile(true)
    stripes:SetVertexColor(0, 0, 0, 0.35)
    stripes:SetAllPoints(dmg:GetStatusBarTexture())
    hp:SetFrameLevel(dmg:GetFrameLevel() + 1)
    c.dmg = dmg

    -- fade-out used when the damage segment drains away
    local fade = dmg:CreateAnimationGroup()
    local a = fade:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    a:SetDuration(0.6)
    a:SetSmoothing("OUT")
    fade:SetScript("OnFinished", function() dmg:Hide() end)
    c.dmgFade = fade

    -- Incoming heals: a second bar that starts where the health fill ends and
    -- uses the same max, so its fill width equals the incoming amount. The
    -- container clips anything past the frame's edge (overheal).
    c:SetClipsChildren(true)
    local inc = CreateFrame("StatusBar", nil, c)
    inc:SetStatusBarTexture(BAR)
    inc:SetStatusBarColor(INC_COLOR[1], INC_COLOR[2], INC_COLOR[3], 0.85)
    inc:SetPoint("TOPLEFT", hp:GetStatusBarTexture(), "TOPRIGHT")
    inc:SetPoint("BOTTOMLEFT", hp:GetStatusBarTexture(), "BOTTOMRIGHT")
    inc:SetWidth(W)
    inc:SetMinMaxValues(0, 1)
    inc:SetValue(0)
    inc:SetFrameLevel(hp:GetFrameLevel())
    c.inc = inc

    -- HoT prediction: starts where the incoming-heal fill ends, paler green.
    local hot = CreateFrame("StatusBar", nil, c)
    hot:SetStatusBarTexture(BAR)
    -- same look as the cast-heal segment, softer and steady (no pulse)
    hot:SetStatusBarColor(INC_COLOR[1], INC_COLOR[2], INC_COLOR[3], 0.4)
    -- starts at the end of the health fill; moved after the cast-heal fill
    -- while a heal is being cast (see PlaceHot)
    hot:SetPoint("TOPLEFT", hp:GetStatusBarTexture(), "TOPRIGHT")
    hot:SetPoint("BOTTOMLEFT", hp:GetStatusBarTexture(), "BOTTOMRIGHT")
    hot:SetWidth(W)
    hot:SetMinMaxValues(0, 1)
    hot:SetValue(0)
    hot:SetFrameLevel(inc:GetFrameLevel())
    hot:Hide()                                -- only shown while a HoT is ticking
    c.hot = hot

    -- Shields: a thin white bar along the top of the frame, its width the
    -- absorb remaining (the game hands that over as a finished number, so it
    -- works in combat). Along the top so it shows even at full health.
    local shield = CreateFrame("StatusBar", nil, c)
    shield:SetPoint("TOPLEFT")
    shield:SetPoint("TOPRIGHT")
    shield:SetHeight(SHIELD_H)
    -- white with a dark underline built into the texture, so it stands out on
    -- light class colours too
    shield:SetStatusBarTexture(string.format("Interface\\AddOns\\%s\\media\\shield", ADDON))
    shield:SetMinMaxValues(0, 1)
    shield:SetValue(0)
    shield:SetFrameLevel(hp:GetFrameLevel() + 1)
    -- dashed: a fixed dash pattern across the whole strip masks the fill, so
    -- the dashes stay put while the shield shrinks
    if shield.CreateMaskTexture then
        local mask = shield:CreateMaskTexture()
        mask:SetTexture(string.format("Interface\\AddOns\\%s\\media\\shield_mask", ADDON),
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(shield)
        shield:GetStatusBarTexture():AddMaskTexture(mask)
    end
    c.shield = shield

    -- Glow: once a heal is on the way the segment softly pulses until it lands.
    local pulse = inc:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local glow = pulse:CreateAnimation("Alpha")
    glow:SetFromAlpha(1)
    glow:SetToAlpha(0.5)
    glow:SetDuration(0.8)
    glow:SetSmoothing("IN_OUT")
    c.incPulse = pulse

    local text = CreateFrame("Frame", nil, c)
    text:SetAllPoints()
    text:SetFrameLevel(hp:GetFrameLevel() + 2)

    local name = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("CENTER", 0, 6)
    name:SetWidth(W - 6)
    name:SetWordWrap(false)
    c.name = name

    local status = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("CENTER", 0, -8)
    status:SetTextColor(0.85, 0.85, 0.85)
    c.status = status

    c.hots = {}
    for i = 1, MAX_HOTS do
        local t = text:CreateTexture(nil, "OVERLAY")
        t:SetSize(HOT_SIZE, HOT_SIZE)
        t:SetPoint("TOPRIGHT", -2 - (i - 1) * (HOT_SIZE + 1), -2)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t:Hide()
        c.hots[i] = t
    end

    -- out-of-range dimming: a dark layer on top, so nothing underneath shows
    -- through the way it would if the whole frame went translucent
    local dimF = CreateFrame("Frame", nil, c)
    dimF:SetAllPoints()
    dimF:SetFrameLevel(text:GetFrameLevel() + 5)
    local dim = dimF:CreateTexture(nil, "OVERLAY")
    dim:SetAllPoints()
    dim:SetColorTexture(0.06, 0.07, 0.1, 1)
    dim:SetAlpha(0)
    c.dim = dim

    -- current target: a white outline, above the dimming so it always shows
    local selF = CreateFrame("Frame", nil, c)
    selF:SetAllPoints()
    selF:SetFrameLevel(dimF:GetFrameLevel() + 1)
    c.selected = Border(selF, 0, 2)
    c.selected:Set(1, 1, 1)
    c.selected:SetAlpha(0)

    BuildDispelFx(btn)
    c.aggro = Border(text, 2, 2)      -- outside edge: threat
    c.aggro:Set(AGGRO_COLOR[1], AGGRO_COLOR[2], AGGRO_COLOR[3])
    c.aggro:SetAlpha(0)
end

---------------------------------------------------------------------------
-- Dispellable debuff effect: the whole frame pulses in the debuff type's
-- colour (a wash slowly breathing between strong and medium), with a thin
-- outline in the same colour so it still reads at the faint end.
---------------------------------------------------------------------------
BuildDispelFx = function(btn)
    local c = btn.c
    local fx = CreateFrame("Frame", nil, c)
    fx:SetAllPoints()
    fx:SetFrameLevel(c.hp:GetFrameLevel() + 1)    -- over the bars, under the name
    fx:Hide()

    local wash = fx:CreateTexture(nil, "ARTWORK")
    wash:SetAllPoints()
    wash:SetTexture(BAR)
    local pulse = wash:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local a = pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(0.6)
    a:SetToAlpha(0.3)            -- never fades out, so it reads as a steady glow
    a:SetDuration(1.25)          -- slow breathing, ~2.5s per cycle
    a:SetSmoothing("IN_OUT")

    local outline = Border(fx, 0, 1)

    c.dispel = {}
    function c.dispel:Set(r, g, b)
        if not r then
            pulse:Stop()
            fx:Hide()
            return
        end
        wash:SetVertexColor(r, g, b)
        outline:Set(r, g, b)
        fx:Show()
        if not pulse:IsPlaying() then pulse:Play() end
    end
end

-- WoW Forever hands addons health, range and threat as "secret" values:
-- they can be shown (bars, text, alpha) but not compared or used in maths.
-- Everything below passes them straight to widgets or to game helpers.
local Missing = UnitHealthMissing or function(u) return UnitHealthMax(u) - UnitHealth(u) end

local function FromBool(b, yes, no)
    if C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean then
        return C_CurveUtil.EvaluateColorValueFromBoolean(b, yes, no)
    end
    return b and yes or no
end

-- An empty status bar keeps its fill texture full width (just hidden), so the
-- HoT segment may only follow the cast-heal fill while a heal is incoming;
-- otherwise it would start past the frame's edge and be clipped away.
local function PlaceHot(btn, afterIncoming)
    local c = btn.c
    local edge = (afterIncoming and c.inc or c.hp):GetStatusBarTexture()
    c.hot:ClearAllPoints()
    c.hot:SetPoint("TOPLEFT", edge, "TOPRIGHT")
    c.hot:SetPoint("BOTTOMLEFT", edge, "BOTTOMRIGHT")
end

local function UpdateHealth(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    local max = UnitHealthMax(u)
    c.hp:SetMinMaxValues(0, max)
    c.hp:SetValue(UnitHealth(u))
    c.inc:SetMinMaxValues(0, max)
    c.hot:SetMinMaxValues(0, max)
    c.hot:SetValue(btn.hotAmount or 0)
    c.hot:SetShown((btn.hotAmount or 0) > 0)
    local incoming = UnitGetIncomingHeals and UnitGetIncomingHeals(u)
    -- the game returns nothing when no heals are coming
    if incoming then
        if not btn.incActive then
            -- a heal just started: grow out from the health edge
            btn.incActive = true
            c.inc:SetValue(0)
            c.inc:Show()
            c.incPulse:Play()
            PlaceHot(btn, true)
        end
        if INC_EASE then c.inc:SetValue(incoming, INC_EASE) else c.inc:SetValue(incoming) end
    else
        if btn.incActive ~= false then
            btn.incActive = false
            PlaceHot(btn, false)
        end
        c.incPulse:Stop()
        c.inc:SetValue(0)
        c.inc:Hide()
    end

    local status = (not UnitIsConnected(u) and "Offline") or (UnitIsGhost(u) and "Ghost")
        or (UnitIsDead(u) and "Dead") or nil
    c.status:SetText(status or "")
    -- centre the name unless there's a status line under it
    local has = status ~= nil
    if has ~= btn.hasStatus then
        btn.hasStatus = has
        c.name:ClearAllPoints()
        c.name:SetPoint("CENTER", 0, (btn.roomy and has) and 6 or 0)
    end
end

-- On each health change, hold the previous value on the damage bar for 1s.
-- Healing leaves it hidden under the health fill; the next change replaces it.
-- Values may be secret, so they're only stored and handed to the bars.
-- Damage flash timing: hold the lost chunk briefly, then drain it down to the
-- current health while fading out (about a second in all).
local DAMAGE_HOLD = 0.35
local EASE = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut

local function OnHealthChanged(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    local cur = UnitHealth(u)
    c.dmgFade:Stop()
    c.dmg:SetAlpha(1)
    c.dmg:SetMinMaxValues(0, UnitHealthMax(u))
    c.dmg:SetValue(btn.lastHealth or cur)      -- snap to the health before this change
    c.dmg:Show()
    btn.lastHealth = cur
    btn.dmgToken = (btn.dmgToken or 0) + 1
    local token = btn.dmgToken
    C_Timer.After(DAMAGE_HOLD, function()
        if btn.dmgToken ~= token then return end
        -- the bar eases itself toward the new value, so no maths on health
        if EASE then c.dmg:SetValue(cur, EASE) end
        c.dmgFade:Play()
    end)
    UpdateHealth(btn)
end

-- Mana, rage, energy (and friends). The type is readable; the amounts can be
-- secret, so they go straight to the bar.
local POWER_COLOR = {
    MANA = { 0.43, 0.59, 1 }, RAGE = { 0.59, 0.08, 0.08 }, ENERGY = { 0.9, 0.78, 0.16 },
    FOCUS = { 1, 0.5, 0.25 }, RUNIC_POWER = { 0, 0.82, 1 },
}
local function ApplyPowerShown(btn)
    local on = DB.showPower
    btn.c.power:SetShown(on)
    btn.c.hp:SetPoint("BOTTOMRIGHT", 0, on and POWER_H or 0)
end

local function UpdatePower(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) or not DB.showPower then return end
    local _, token = UnitPowerType(u)
    local col = token and POWER_COLOR[token]
    if not col and token and PowerBarColor and PowerBarColor[token] then
        local pc = PowerBarColor[token]
        col = { pc.r, pc.g, pc.b }
    end
    col = col or POWER_COLOR.MANA
    c.power:SetStatusBarColor(col[1], col[2], col[3])
    -- lighter shade of the same colour for the pending cast cost
    c.powerCost:SetStatusBarColor(col[1] + (1 - col[1]) * 0.55, col[2] + (1 - col[2]) * 0.55,
        col[3] + (1 - col[3]) * 0.55)
    local max = UnitPowerMax(u)
    c.power:SetMinMaxValues(0, max)
    c.power:SetValue(UnitPower(u))
    c.powerCost:SetMinMaxValues(0, max)
end

-- Power cost of a spell for this unit's power type (nil if unknown/hidden).
local function CastCost(u, spellID)
    if not Readable(spellID) then return nil end
    local getCost = (C_Spell and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
    if not getCost then return nil end
    local costs = getCost(spellID)
    local ptype = UnitPowerType(u)
    for _, pc in ipairs(costs or {}) do
        if pc.type == ptype and type(pc.cost) == "number" and pc.cost > 0 then return pc.cost end
    end
end

local function ShowCastCost(btn, spellID)
    local c = btn.c
    local ok, amount = pcall(CastCost, btn.unit, spellID)
    if ok and amount and DB.showPower then
        c.powerCost:SetValue(amount)
        c.powerCost:Show()
    else
        c.powerCost:Hide()
    end
end

local function HideCastCost(btn)
    btn.c.powerCost:Hide()
end

local function UpdateIdentity(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    c.name:SetText(UnitName(u) or "")
    local ok, col = pcall(function()
        local _, class = UnitClass(u)
        return class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    end)
    if ok and col then
        btn.classColor = { col.r * 0.8, col.g * 0.8, col.b * 0.8 }
    else
        btn.classColor = { 0.3, 0.8, 0.3 }
    end
    local cc = btn.classColor
    c.hp:SetStatusBarColor(cc[1], cc[2], cc[3])
    c.dmg:SetStatusBarColor(cc[1], cc[2], cc[3])
end

-- Color for a debuff the player can dispel. Readable dispel type first; if
-- that's hidden, ask the game to map it to a color for us.
-- Debuff types this character can remove, from the cure spells they know.
local CURES = {
    SHAMAN = { ["Cure Poison"] = { "Poison" }, ["Cure Disease"] = { "Disease" } },
    PRIEST = { ["Dispel Magic"] = { "Magic" }, ["Cure Disease"] = { "Disease" }, ["Abolish Disease"] = { "Disease" } },
    DRUID = { ["Remove Curse"] = { "Curse" }, ["Cure Poison"] = { "Poison" }, ["Abolish Poison"] = { "Poison" } },
    PALADIN = { ["Purify"] = { "Poison", "Disease" }, ["Cleanse"] = { "Magic", "Poison", "Disease" } },
    MAGE = { ["Remove Lesser Curse"] = { "Curse" } },
}
local canDispel = {}
local function RefreshCures()
    wipe(canDispel)
    local _, class = UnitClass("player")
    for spell, types in pairs(CURES[class] or {}) do
        if SpellInfo(spell) then
            for _, t in ipairs(types) do canDispel[t] = true end
        end
    end
end


local dispelCurve
local function DispelColor(u, a)
    local dtype = a.dispelName
    if type(dtype) == "string" and not (issecretvalue and issecretvalue(dtype)) and DEBUFF_COLOR[dtype] then
        local col = DEBUFF_COLOR[dtype]
        return col.r, col.g, col.b
    end
    if C_UnitAuras.GetAuraDispelTypeColor and C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor then
        if not dispelCurve then
            dispelCurve = C_CurveUtil.CreateColorCurve()
            dispelCurve:SetType(Enum.LuaCurveType.Step)
            -- dispel type IDs: 1 Magic, 2 Curse, 3 Disease, 4 Poison
            dispelCurve:AddPoint(0, CreateColor(0.8, 0.8, 0.8, 1))
            for id, t in ipairs({ "Magic", "Curse", "Disease", "Poison" }) do
                local col = DEBUFF_COLOR[t]
                dispelCurve:AddPoint(id, CreateColor(col.r, col.g, col.b, 1))
            end
        end
        return C_UnitAuras.GetAuraDispelTypeColor(u, a.auraInstanceID, dispelCurve):GetRGB()
    end
    return 0.8, 0.8, 0.8
end

-- Buffs worth an icon: known HoTs and shields by name, or, if the game hides
-- names, any of your buffs lasting 30 seconds or less.
local HOT_ICONS = { ["Renew"] = true, ["Rejuvenation"] = true, ["Regrowth"] = true,
    ["Power Word: Shield"] = true, ["First Aid"] = true }
local function IsHotAura(a)
    local name = a.name
    if Readable(name) then return HOT_ICONS[name] == true end
    local dur = a.duration
    return Readable(dur) and dur > 0 and dur <= 30
end

local function UpdateHotIcons(btn)
    local u, c = btn.unit, btn.c
    local n = 0
    local namesHidden = false
    for i = 1, 40 do
        if n >= MAX_HOTS then break end
        local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HELPFUL|PLAYER")
        if not a then break end
        if not Readable(a.name) then namesHidden = true; break end
        local ok, hot = pcall(IsHotAura, a)
        if ok and hot then
            n = n + 1
            c.hots[n]:SetTexture(a.icon)
            c.hots[n]:Show()
        end
    end
    -- In combat the game hides buff names from addons, so let it pick the
    -- buffs worth showing; the icon itself can still be displayed.
    if namesHidden then
        n = 0
        for _, filter in ipairs({ "HELPFUL|PLAYER|RAID_IN_COMBAT", "HELPFUL|PLAYER|RAID" }) do
            for i = 1, MAX_HOTS do
                local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, u, i, filter)
                if not ok or not a then break end
                n = n + 1
                c.hots[n]:SetTexture(a.icon)
                c.hots[n]:Show()
            end
            if n > 0 then break end
        end
    end
    for k = n + 1, MAX_HOTS do c.hots[k]:Hide() end
end

-- Route 1: read each debuff's type and check it against the cures you know.
-- Returns r, g, b, type for the first debuff you can cure, or, when the
-- game hides debuff types (in combat), nil plus `true` for "hidden".
local function FindDispelByType(u)
    local hidden = false
    for i = 1, 40 do
        local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HARMFUL")
        if not a then break end
        local t = a.dispelName
        if t ~= nil and not Readable(t) then
            hidden = true
        elseif Readable(t) and canDispel[t] and DEBUFF_COLOR[t] then
            local col = DEBUFF_COLOR[t]
            return col.r, col.g, col.b, t
        end
    end
    return nil, nil, nil, nil, hidden
end

-- Route 2: let the game pick debuffs you can dispel ("HARMFUL|RAID").
local NEUTRAL_DISPEL = { 0.85, 0.85, 0.85 }    -- type unknown (hidden in combat)
local function FindDispelByFilter(u)
    for _, filter in ipairs({ "HARMFUL|RAID_PLAYER_DISPELLABLE", "HARMFUL|RAID" }) do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, u, 1, filter)
        if ok and a then
            local okc, r, g, b = pcall(DispelColor, u, a)
            if okc and r then return r, g, b end
            return NEUTRAL_DISPEL[1], NEUTRAL_DISPEL[2], NEUTRAL_DISPEL[3]
        end
    end
end

local function UpdateDispel(btn)
    local u = btn.unit
    local ok, r, g, b, kind, hidden = pcall(FindDispelByType, u)
    -- only ask the game's own filter when debuff details are hidden (combat):
    -- otherwise the exact type check above is authoritative
    if not (ok and r) and (not ok or hidden) then
        local ok2, r2, g2, b2 = pcall(FindDispelByFilter, u)
        if ok2 then r, g, b, kind = r2, g2, b2, nil else r = nil end
    end
    btn.c.dispel:Set(r, g, b, kind)
end

local function UpdateAurasModern(btn)
    if not pcall(UpdateHotIcons, btn) then
        for k = 1, MAX_HOTS do btn.c.hots[k]:Hide() end
    end
    UpdateDispel(btn)
end

local function UpdateAurasLegacy(btn)
    local u, c = btn.unit, btn.c
    local n, i = 0, 1
    while n < MAX_HOTS do
        local name, icon, _, duration = AuraAt(u, i, "HELPFUL|PLAYER")
        if not name then break end
        if duration and duration > 0 then
            n = n + 1
            c.hots[n]:SetTexture(icon)
            c.hots[n]:Show()
        end
        i = i + 1
    end
    for k = n + 1, MAX_HOTS do c.hots[k]:Hide() end
    local found
    i = 1
    while true do
        local name, _, dtype = AuraAt(u, i, "HARMFUL|RAID")
        if not name then break end
        if dtype and DEBUFF_COLOR[dtype] then found = dtype; break end
        i = i + 1
    end
    if found then
        local col = DEBUFF_COLOR[found]
        c.dispel:Set(col.r, col.g, col.b, found)
    else
        c.dispel:Set(nil)
    end
end

-- HoTs the game's incoming-heal number leaves out. Each active Renew,
-- Rejuvenation or Regrowth (from anyone) adds what it has left to heal: the
-- per-tick amount the aura reports, or, when the game doesn't report it
-- (common for other players' HoTs), the spell rank's base healing.
-- name -> { ticks, seconds between ticks }
local HOT_NAMES = {
    ["Renew"] = { 5, 3 }, ["Rejuvenation"] = { 4, 3 }, ["Regrowth"] = { 7, 3 },
    ["First Aid"] = { 8, 1 },                             -- bandages
}
-- spell ID -> { total base healing, ticks, interval } (Classic ranks)
local HOT_RANKS = {}
for _, spell in ipairs({
    { 5, 3, { 139, 45 }, { 6074, 100 }, { 6075, 175 }, { 6076, 245 }, { 6077, 315 },       -- Renew
            { 6078, 400 }, { 10927, 510 }, { 10928, 650 }, { 10929, 810 }, { 25315, 970 } },
    { 4, 3, { 774, 32 }, { 1058, 56 }, { 1430, 116 }, { 2090, 180 }, { 2091, 244 },         -- Rejuvenation
            { 3627, 304 }, { 8910, 388 }, { 9839, 488 }, { 9840, 608 }, { 9841, 756 }, { 25299, 888 } },
    { 7, 3, { 8936, 98 }, { 8938, 175 }, { 8939, 259 }, { 8940, 343 }, { 8941, 427 },       -- Regrowth (HoT part)
            { 9750, 546 }, { 9856, 686 }, { 9857, 861 }, { 9858, 1064 } },
    { 8, 1, { 746, 66 }, { 1159, 114 }, { 3267, 161 }, { 3268, 301 }, { 7926, 400 },        -- bandages
            { 7927, 640 }, { 10838, 800 }, { 10839, 1104 }, { 18608, 1360 }, { 18610, 2000 } },
}) do
    for k = 3, #spell do
        HOT_RANKS[spell[k][1]] = { total = spell[k][2], ticks = spell[1], every = spell[2] }
    end
end

local function HotFromAura(a, now)
    local id, name = a.spellId, a.name
    local rank = Readable(id) and HOT_RANKS[id] or nil
    local byName = Readable(name) and HOT_NAMES[name] or nil
    local ticks = rank and rank.ticks or (byName and byName[1]) or nil
    local every = rank and rank.every or (byName and byName[2]) or 3
    if not ticks then return nil end

    local okp, pv = pcall(function() return a.points and a.points[1] end)
    local perTick
    if okp and Readable(pv) and type(pv) == "number" and pv > 0 then
        perTick = pv
    elseif rank then
        perTick = rank.total / rank.ticks
    else
        return nil
    end

    local left = ticks
    local exp = a.expirationTime
    if Readable(exp) and type(exp) == "number" and exp > 0 then
        left = math.max(0, math.min(ticks, math.ceil((exp - now) / every - 0.01)))
    end
    return left * perTick
end

local function HotAmount(u)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return 0 end
    local sum, now = 0, GetTime()
    for i = 1, 40 do
        local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HELPFUL")
        if not a then break end
        local ok, amount = pcall(HotFromAura, a, now)   -- one unreadable aura doesn't stop the rest
        if ok and amount then sum = sum + amount end
    end
    return sum
end

local function UpdateHots(btn)
    local ok, amount = pcall(HotAmount, btn.unit)
    -- if the game hides aura details, show no HoT segment rather than erroring
    btn.hotAmount = ok and amount or 0
    btn.c.hot:SetValue(btn.hotAmount)
    btn.c.hot:SetShown(btn.hotAmount > 0)
end

local function UpdateAuras(btn)
    local u = btn.unit
    if not u or not UnitExists(u) then return end
    UpdateHots(btn)
    local fn = (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) and UpdateAurasModern or UpdateAurasLegacy
    -- if the game hides aura details right now, show nothing rather than erroring
    if not pcall(fn, btn) then
        for k = 1, MAX_HOTS do btn.c.hots[k]:Hide() end
        btn.c.dispel:Set(nil)
    end
end

-- Threat: 0 none, 1 high threat, 2-3 has aggro. Used directly as the outline's
-- alpha (anything above 1 is fully visible), so it works when it's secret.
local function UpdateThreat(btn)
    local u = btn.unit
    if not u or not UnitExists(u) or not UnitThreatSituation then return end
    local s = UnitThreatSituation(u)
    pcall(btn.c.aggro.SetAlpha, btn.c.aggro, s or 0)
end

local function UpdateRange(btn)
    local u = btn.unit
    if not u or not UnitExists(u) then return end
    local dim = btn.c.dim
    if not UnitIsConnected(u) then
        dim:SetAlpha(OOR_DIM)
    elseif u == "player" then
        dim:SetAlpha(0)
    else
        local inRange = UnitInRange(u)
        dim:SetAlpha(FromBool(inRange, 0, OOR_DIM))
    end
end

-- "Is this my target" can be a hidden yes/no, so it goes straight to alpha.
local function UpdateSelected(btn)
    local u = btn.unit
    if not u or not UnitExists(u) or not UnitExists("target") then
        btn.c.selected:SetAlpha(0)
        return
    end
    pcall(function() btn.c.selected:SetAlpha(FromBool(UnitIsUnit(u, "target"), 1, 0)) end)
end

local function UpdateShield(btn)
    local u = btn.unit
    if not u or not UnitExists(u) or not UnitGetTotalAbsorbs then return end
    btn.c.shield:SetMinMaxValues(0, UnitHealthMax(u))
    btn.c.shield:SetValue(UnitGetTotalAbsorbs(u) or 0)
end

local function UpdateAll(btn)
    UpdateIdentity(btn)
    UpdateHealth(btn)
    UpdatePower(btn)
    UpdateShield(btn)
    UpdateAuras(btn)
    UpdateThreat(btn)
    UpdateRange(btn)
    UpdateSelected(btn)
end

local function Remap()
    wipe(byUnit)
    for _, b in ipairs(buttons) do
        if b.unit and b:IsShown() then
            byUnit[b.unit] = byUnit[b.unit] or {}
            table.insert(byUnit[b.unit], b)
        end
    end
end

---------------------------------------------------------------------------
-- Click-casting
---------------------------------------------------------------------------
-- WoW only lets "target" and "menu" through on clicks that Blizzard's Click
-- Casting has an interaction for (by default plain left / plain right). Other
-- clicks target through a secure macro filled in at click time, and open the
-- menu directly (menus aren't protected).
local menuClicks = {}                -- "alt-2" = true etc., opened by OnMenuClick

local function ApplyBindings(btn)
    local binds = Binds()
    wipe(menuClicks)
    for _, mod in ipairs(MODS) do
        for _, click in ipairs(CLICKS) do
            local val = binds[mod .. click]
            local typ, spell
            if val and val ~= "" then
                local low = val:lower()
                if low == "target" then
                    typ = "target"
                elseif low == "menu" then
                    typ = "togglemenu"
                else
                    typ, spell = "spell", val
                end
            elseif mod == "" and click == 1 then
                typ = "target"
            elseif mod == "" and click == 2 then
                typ = "togglemenu"
            end
            if typ == "target" and not (mod == "" and click == 1) then
                typ = "macro"                       -- "*macrotext*" set on click
            elseif typ == "togglemenu" and not (mod == "" and click == 2) then
                typ = nil
                menuClicks[mod .. click] = true
            end
            btn:SetAttribute(mod .. "type" .. click, typ)
            btn:SetAttribute(mod .. "spell" .. click, spell)
        end
    end
end

local function ApplyBindingsAll()
    return OutOfCombat(function()
        for _, b in ipairs(buttons) do ApplyBindings(b) end
    end)
end

---------------------------------------------------------------------------
-- The group header
---------------------------------------------------------------------------
local secureHandler = CreateFrame("Frame", nil, UIParent, "SecureHandlerBaseTemplate")

local CLICK_NUM = { LeftButton = 1, RightButton = 2, MiddleButton = 3, Button4 = 4, Button5 = 5 }
local function OpenMenu(unit)
    if not unit or not UnitExists(unit) or not UnitPopup_OpenMenu then return end
    local which
    if unit == "player" then
        which = "SELF"
    elseif unit:match("^party%d") then
        which = "PARTY"
    elseif unit:match("^raid%d") then
        which = "RAID_PLAYER"
    else
        which = "PLAYER"
    end
    UnitPopup_OpenMenu(which, { unit = unit })
end

OnMenuClick = function(btn, button)
    local n = CLICK_NUM[button]
    if not n then return end
    local mod = IsAltKeyDown() and "alt-" or IsControlKeyDown() and "ctrl-" or IsShiftKeyDown() and "shift-" or ""
    if menuClicks[mod .. n] then OpenMenu(btn.unit) end
end

-- Called by the header (through CallMethod) for each button it creates.
local function InitButton(self, name)
    local btn = _G[name]
    if not btn or btn.fhb then return end
    btn.fhb = true
    buttons[#buttons + 1] = btn
    Build(btn)
    ApplyPowerShown(btn)
    btn:RegisterForClicks("AnyUp")
    -- secure pre-click snippet: point the target macro at this frame's unit
    SecureHandlerWrapScript(btn, "OnClick", secureHandler, [[
        local u = self:GetAttribute("unit")
        if u then self:SetAttribute("*macrotext*", "/target " .. u) end
    ]])
    btn:HookScript("OnClick", OnMenuClick)
    ApplyBindings(btn)
    btn:HookScript("OnAttributeChanged", function(b, key, value)
        if key == "unit" then
            b.lastHealth = nil
            b.dmgToken = (b.dmgToken or 0) + 1
            b.c.dmgFade:Stop()
            b.c.dmg:Hide()
            b.incActive = nil            -- next update re-places the HoT segment
            b.c.incPulse:Stop()
            b.c.powerCost:Hide()
            b.unit = value
            Remap()
            if value then UpdateAll(b) end
        end
    end)
    btn:HookScript("OnShow", function(b) Remap(); UpdateAll(b) end)
    btn:HookScript("OnHide", Remap)
    btn:HookScript("OnEnter", function(b)
        if b.unit and UnitExists(b.unit) then
            GameTooltip_SetDefaultAnchor(GameTooltip, b)
            GameTooltip:SetUnit(b.unit)
            GameTooltip:Show()
        end
    end)
    btn:HookScript("OnLeave", GameTooltip_Hide)
end

local function SavePosition()
    local point, _, rel, x, y = anchor:GetPoint()
    DB.pos = { point, rel, x, y }
end

local function PlaceAnchor()
    anchor:ClearAllPoints()
    local p = DB.pos
    if p then
        anchor:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 260, -240)
    end
end

local function CreateHeader()
    anchor = CreateFrame("Frame", "ForeverHealBarsAnchor", UIParent)
    anchor:SetSize(W, H)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    PlaceAnchor()

    header = CreateFrame("Frame", "ForeverHealBarsHeader", UIParent, "SecureGroupHeaderTemplate")
    header.initButton = InitButton
    header:SetPoint("TOPLEFT", anchor, "TOPLEFT")
    header:SetScale(DB.scale or 1)

    header:SetAttribute("template", "SecureUnitButtonTemplate")
    header:SetAttribute("templateType", "Button")
    header:SetAttribute("initialConfigFunction", string.format([[
        self:SetWidth(%d)
        self:SetHeight(%d)
        self:GetParent():CallMethod("initButton", self:GetName())
    ]], W, H))

    header:SetAttribute("showPlayer", true)
    header:SetAttribute("showSolo", true)
    header:SetAttribute("showParty", true)
    header:SetAttribute("showRaid", true)
    header:SetAttribute("point", "TOP")
    header:SetAttribute("yOffset", -GAP)
    header:SetAttribute("groupBy", "GROUP")
    header:SetAttribute("groupingOrder", "1,2,3,4,5,6,7,8")
    header:SetAttribute("groupFilter", "1,2,3,4,5,6,7,8")
    header:SetAttribute("unitsPerColumn", 5)
    header:SetAttribute("maxColumns", 8)
    header:SetAttribute("columnSpacing", GAP)
    header:SetAttribute("columnAnchorPoint", "LEFT")

    -- Create all 40 buttons now, out of combat, so people who join mid-fight
    -- get a fully set-up button instead of one created in combat lockdown.
    header:SetAttribute("startingIndex", -MAX_BUTTONS + 1)
    header:Show()
    header:SetAttribute("startingIndex", 1)
end

---------------------------------------------------------------------------
-- Moving the frames
---------------------------------------------------------------------------
local lockBtn, gearBtn
local ToggleConfig                    -- defined with the settings window below
local function LockIcon(locked)
    return string.format("Interface\\AddOns\\%s\\media\\%s", ADDON, locked and "locked" or "unlocked")
end

local ACCENT = { 0.2, 1, 0.6 }
local MIN_SCALE, MAX_SCALE = 0.5, 2

-- Size of the whole grid on screen, never smaller than one frame.
local function GridSize()
    local sc = header:GetScale()
    return math.max(header:GetWidth() or 0, W) * sc, math.max(header:GetHeight() or 0, H) * sc
end

local function UpdateMover()
    if not mover or not mover:IsShown() then return end
    local w, h = GridSize()
    mover:SetSize(w + 8, h + 8)
end

local function SetHint(text)
    if not mover then return end
    mover.hint:SetText(text)
    mover.pill:SetWidth(mover.hint:GetStringWidth() + 16)
end
local DEFAULT_HINT = "Drag to move  |cff666a75·|r  drag the corner to resize"

local function ApplyScale(sc)
    sc = math.floor(sc * 20 + 0.5) / 20        -- 5% steps
    sc = math.max(MIN_SCALE, math.min(MAX_SCALE, sc))
    DB.scale = sc
    header:SetScale(sc)
    UpdateMover()
    return sc
end

-- Frame (cell) size: width and height independently.
local MIN_W, MAX_W, MIN_H, MAX_H = 40, 200, 22, 120

local function ConfigSnippet(w, h)
    return string.format([[
        self:SetWidth(%d)
        self:SetHeight(%d)
        self:GetParent():CallMethod("initButton", self:GetName())
    ]], w, h)
end

local layoutTick = 0
local function ApplySize(w, h)
    w = math.max(MIN_W, math.min(MAX_W, math.floor(w + 0.5)))
    h = math.max(MIN_H, math.min(MAX_H, math.floor(h + 0.5)))
    DB.w, DB.h = w, h
    for _, b in ipairs(buttons) do
        b:SetSize(w, h)
        b.c.name:SetWidth(w - 6)
        b.c.inc:SetWidth(w)
        b.c.hot:SetWidth(w)
        b.c.powerCost:SetWidth(w)
        -- short frames: name only, centred; tall enough: name above missing health
        b.roomy = h >= 34
        b.c.status:SetShown(b.roomy)
        b.c.name:ClearAllPoints()
        b.c.name:SetPoint("CENTER", 0, (b.roomy and b.hasStatus) and 6 or 0)
    end
    anchor:SetSize(w, h)
    header:SetAttribute("initialConfigFunction", ConfigSnippet(w, h))
    -- any attribute change makes the header lay its buttons out again
    layoutTick = layoutTick + 1
    header:SetAttribute("fhbLayout", layoutTick)
    C_Timer.After(0, UpdateMover)
    return w, h
end

-- How many columns and rows of frames are showing right now.
local function GridShape()
    local n = 0
    for _, b in ipairs(buttons) do if b:IsShown() then n = n + 1 end end
    n = math.max(n, 1)
    return math.ceil(n / 5), math.min(n, 5)
end

local function CreateMover()
    -- same layer as the frames, just above them, so bags and windows still
    -- open on top of it
    mover = CreateFrame("Frame", nil, UIParent)
    mover:SetFrameStrata(header:GetFrameStrata())
    mover:SetFrameLevel(header:GetFrameLevel() + 40)
    mover:SetPoint("TOPLEFT", anchor, "TOPLEFT", -4, 4)
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")

    -- dim fill and a 1px accent outline hugging the grid
    local fill = mover:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetColorTexture(0.04, 0.05, 0.08, 0.55)
    local edge = Border(mover, 0, 1, "BORDER")
    edge:Set(ACCENT[1], ACCENT[2], ACCENT[3])
    edge:SetAlpha(0.9)

    -- hint pill to the right of the padlock
    local pill = CreateFrame("Frame", nil, mover)
    pill:SetHeight(16)
    pill:SetPoint("BOTTOMLEFT", mover, "TOPLEFT", 40, 3)
    local pbg = pill:CreateTexture(nil, "BACKGROUND")
    pbg:SetAllPoints()
    pbg:SetColorTexture(0.04, 0.05, 0.08, 0.85)
    local pedge = Border(pill, 0, 1, "BORDER")
    pedge:Set(ACCENT[1], ACCENT[2], ACCENT[3])
    pedge:SetAlpha(0.5)
    local hint = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("CENTER")
    mover.pill, mover.hint = pill, hint

    mover:SetScript("OnDragStart", function()
        if not InCombatLockdown() then anchor:StartMoving() end
    end)
    mover:SetScript("OnDragStop", function()
        anchor:StopMovingOrSizing()
        SavePosition()
    end)

    -- resize grip in the bottom-right corner: drag to scale the whole grid
    local grip = CreateFrame("Button", nil, mover)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(self)
        if InCombatLockdown() then return end
        local ui = UIParent:GetEffectiveScale()
        local x, y = GetCursorPosition()
        self.startX, self.startY = x / ui, y / ui
        self.startW, self.startH = DB.w or W, DB.h or H
        self.cols, self.rows = GridShape()
        self:SetScript("OnUpdate", function(g)
            if InCombatLockdown() then g:SetScript("OnUpdate", nil) return end
            local cx, cy = GetCursorPosition()
            local sc = header:GetScale()
            -- spread the cursor movement across the columns / rows
            local w = g.startW + (cx / ui - g.startX) / sc / g.cols
            local h = g.startH + (g.startY - cy / ui) / sc / g.rows
            if math.floor(w + 0.5) ~= DB.w or math.floor(h + 0.5) ~= DB.h then
                w, h = ApplySize(w, h)
            end
            SetHint(string.format("Size  |cff33ff99%d × %d|r", DB.w, DB.h))
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
        SetHint(DEFAULT_HINT)
    end)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Drag to resize", 1, 1, 1)
        GameTooltip:AddLine(string.format("Each frame is %d × %d. Drag right for wider, down for taller.",
            DB.w or W, DB.h or H), nil, nil, nil, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)

    SetHint(DEFAULT_HINT)
end

local function SetLocked(locked)
    if InCombatLockdown() then
        pending[#pending + 1] = function() SetLocked(locked) end
        Msg("will %s after combat.", locked and "lock" or "unlock")
        return
    end
    DB.locked = locked
    if not mover then CreateMover() end
    mover:SetShown(not locked)
    UpdateMover()
    if lockBtn then
        lockBtn.icon:SetTexture(LockIcon(locked))
        lockBtn.icon:SetVertexColor(locked and 0.75 or ACCENT[1], locked and 0.75 or ACCENT[2], locked and 0.75 or ACCENT[3])
    end
end

-- Small padlock just above the top-left corner of the frames.
local function CreateLockButton()
    lockBtn = CreateFrame("Button", nil, UIParent)
    lockBtn:SetSize(14, 14)
    lockBtn:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 3)
    lockBtn:SetFrameStrata(header:GetFrameStrata())
    lockBtn:SetFrameLevel(header:GetFrameLevel() + 50)
    lockBtn.icon = lockBtn:CreateTexture(nil, "ARTWORK")
    lockBtn.icon:SetAllPoints()
    lockBtn:SetScript("OnClick", function() SetLocked(not DB.locked) end)
    lockBtn:SetScript("OnEnter", function(self)
        self:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(DB.locked and "Frames locked" or "Frames unlocked", 1, 1, 1)
        GameTooltip:AddLine(DB.locked and "Click to unlock and drag them." or "Click to lock them in place.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    lockBtn:SetScript("OnLeave", function(self)
        self:SetAlpha(0.6)
        GameTooltip:Hide()
    end)
    lockBtn:SetAlpha(0.6)
    lockBtn.icon:SetTexture(LockIcon(DB.locked))
    lockBtn.icon:SetVertexColor(0.75, 0.75, 0.75)

    -- settings gear, just right of the padlock
    gearBtn = CreateFrame("Button", nil, UIParent)
    gearBtn:SetSize(14, 14)
    gearBtn:SetPoint("LEFT", lockBtn, "RIGHT", 4, 0)
    gearBtn:SetFrameStrata(lockBtn:GetFrameStrata())
    gearBtn:SetFrameLevel(lockBtn:GetFrameLevel())
    local gi = gearBtn:CreateTexture(nil, "ARTWORK")
    gi:SetAllPoints()
    gi:SetTexture(string.format("Interface\\AddOns\\%s\\media\\settings", ADDON))
    gi:SetVertexColor(0.75, 0.75, 0.75)
    gearBtn:SetAlpha(0.6)
    gearBtn:SetScript("OnClick", function() ToggleConfig() end)
    gearBtn:SetScript("OnEnter", function(self)
        self:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Settings", 1, 1, 1)
        GameTooltip:AddLine("Click-casting and options (/fhb).", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    gearBtn:SetScript("OnLeave", function(self)
        self:SetAlpha(0.6)
        GameTooltip:Hide()
    end)
end

---------------------------------------------------------------------------
-- Hiding Blizzard's party and raid frames
---------------------------------------------------------------------------
-- The frames are moved under a hidden parent and stop listening for events.
-- The raid tools tab on the left edge of the screen is left alone. Bringing
-- them back needs a /reload, since the game rebuilds them on load.
local hider = CreateFrame("Frame")
hider:Hide()
local blizzHidden = false

local function BlizzardFrames()
    local list = { CompactRaidFrameContainer, CompactPartyFrame, PartyFrame, PartyMemberBackground }
    for i = 1, 4 do list[#list + 1] = _G["PartyMemberFrame" .. i] end
    return list
end

local function HideBlizzard()
    if blizzHidden or not DB.hideBlizzard then return end
    OutOfCombat(function()
        if blizzHidden then return end
        blizzHidden = true
        for _, f in ipairs(BlizzardFrames()) do
            if f then
                pcall(f.UnregisterAllEvents, f)
                pcall(f.Hide, f)
                pcall(f.SetParent, f, hider)
            end
        end
    end)
end

local function SetHideBlizzard(on)
    DB.hideBlizzard = on
    if on then
        HideBlizzard()
        Msg("Blizzard party and raid frames hidden.")
    elseif blizzHidden then
        Msg("Blizzard party and raid frames will come back after a /reload.")
    end
end

---------------------------------------------------------------------------
-- Click-casting setup window
---------------------------------------------------------------------------
local config

local function CreateConfig()
    local f = CreateFrame("Frame", "ForeverHealBarsConfig", UIParent, "BasicFrameTemplateWithInset")
    local colW, rowH, SLOT = 84, 46, 36
    f:SetSize(math.max(560, 90 + colW * #CLICKS + 20), 178 + rowH * #MODS)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, f:GetName())   -- Escape closes it
    -- the template's close button goes through HideUIPanel, which the game
    -- blocks in combat; just hide the window instead
    local close = f.CloseButton or _G[f:GetName() .. "CloseButton"]
    if close then close:SetScript("OnClick", function() f:Hide() end) end

    local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not f.TitleText then title:SetPoint("TOP", 0, -5) end
    local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = GetMeta and GetMeta(ADDON, "Version")
    title:SetText("Forever Heal Bars settings" .. (version and ("  |cff808080v" .. version .. "|r") or ""))

    local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 16, -32)
    help:SetPoint("TOPRIGHT", -16, -32)
    help:SetJustifyH("LEFT")
    help:SetText("Drag a spell from your spellbook onto a square. Right-click a square to clear it; "
        .. "right-click an empty one to set Target or Menu.")

    local top, x0 = -64, 90
    for c, label in ipairs(CLICK_LABEL) do
        local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOP", f, "TOPLEFT", x0 + (c - 1) * colW + colW / 2, top)
        h:SetText(label)
    end

    local ACCENT_DROP = { 0.2, 1, 0.6 }
    f.boxes = {}
    for r, mod in ipairs(MODS) do
        local y = top - 20 - (r - 1) * rowH
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        l:SetPoint("LEFT", f, "TOPLEFT", 18, y - SLOT / 2)
        l:SetText(MOD_LABEL[mod])
        for c, click in ipairs(CLICKS) do
            local key = mod .. click
            -- a square slot the size of a spell icon
            local sq = CreateFrame("Button", nil, f)
            sq:SetSize(SLOT, SLOT)
            sq:SetPoint("TOPLEFT", x0 + (c - 1) * colW + (colW - SLOT) / 2, y)
            sq:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            sq.key = key
            local bg = sq:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.06, 0.07, 0.1, 0.95)
            sq.edge = Border(sq, 0, 1, "BORDER")
            sq.icon = sq:CreateTexture(nil, "ARTWORK")
            sq.icon:SetPoint("TOPLEFT", 2, -2)
            sq.icon:SetPoint("BOTTOMRIGHT", -2, 2)
            sq.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            sq.label = sq:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sq.label:SetPoint("CENTER")
            sq.drop = Border(sq, 2, 2)                      -- outline while dragging a spell
            sq.drop:Set(ACCENT_DROP[1], ACCENT_DROP[2], ACCENT_DROP[3])
            sq.drop:SetAlpha(0)
            sq.hl = sq:CreateTexture(nil, "OVERLAY")        -- the square you'd drop on
            sq.hl:SetAllPoints()
            sq.hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            sq.hl:SetBlendMode("ADD")
            sq.hl:Hide()

            function sq:Refresh()
                local v = Binds()[self.key]
                local low = v and v:lower()
                self.icon:Hide()
                self.label:SetText("")
                self.edge:Set(0.35, 0.36, 0.42)
                if not v then
                    -- defaults for plain left / right
                    if mod == "" and click == 1 then self.label:SetText("|cff707070Target|r")
                    elseif mod == "" and click == 2 then self.label:SetText("|cff707070Menu|r") end
                elseif low == "target" then
                    self.label:SetText("Target")
                elseif low == "menu" then
                    self.label:SetText("Menu")
                else
                    local name, tex = SpellInfo(v)
                    self.icon:SetTexture(tex or 134400)     -- question mark if unknown
                    self.icon:Show()
                    if not name then self.edge:Set(1, 0.25, 0.25) end
                end
            end

            local function Assign(self, v)
                Binds()[self.key] = v
                self:Refresh()
                if not ApplyBindingsAll() then Msg("bindings will update after combat.") end
                if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
            end

            -- a spell dragged from the spellbook and dropped (or clicked) here
            local function TakeCursorSpell(self)
                local kind, a1, a2, a3 = GetCursorInfo()
                if kind ~= "spell" then return false end
                local name
                if a3 then name = SpellInfo(a3) end                       -- spell ID
                if not name and a1 and GetSpellBookItemName then
                    name = GetSpellBookItemName(a1, a2)                   -- book slot
                end
                if not name and C_SpellBook and C_SpellBook.GetSpellBookItemName and a1 then
                    name = C_SpellBook.GetSpellBookItemName(a1, a2)
                end
                ClearCursor()
                if name then Assign(self, name) end
                return true
            end

            sq:SetScript("OnReceiveDrag", TakeCursorSpell)
            sq:SetScript("OnClick", function(self, button)
                if TakeCursorSpell(self) then return end
                if button == "RightButton" then
                    local v = Binds()[self.key]
                    local low = v and v:lower()
                    if v and low ~= "target" and low ~= "menu" then Assign(self, nil)   -- clear a spell
                    elseif not v then Assign(self, "target")
                    elseif low == "target" then Assign(self, "menu")
                    else Assign(self, nil) end
                end
            end)
            sq:SetScript("OnEnter", function(self)
                if GetCursorInfo() == "spell" then self.hl:Show() end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local v = Binds()[self.key]
                local low = v and v:lower()
                local where = (MOD_LABEL[mod] == "Click" and "" or (MOD_LABEL[mod] .. " + ")) .. CLICK_LABEL[c]
                GameTooltip:SetText(where, 1, 1, 1)
                if not v then
                    local def = (mod == "" and click == 1 and "Target (default)") or
                        (mod == "" and click == 2 and "Menu (default)") or "Empty"
                    GameTooltip:AddLine(def, 0.7, 0.7, 0.7)
                    GameTooltip:AddLine("Drag a spell here. Right-click for Target / Menu.", 0.5, 0.5, 0.5, true)
                elseif low == "target" or low == "menu" then
                    GameTooltip:AddLine(low == "target" and "Target" or "Menu", 1, 0.82, 0)
                    GameTooltip:AddLine("Right-click to change.", 0.5, 0.5, 0.5)
                else
                    local name = SpellInfo(v)
                    GameTooltip:AddLine(v, 1, 0.82, 0)
                    if not name then GameTooltip:AddLine("Not in your spellbook yet.", 1, 0.3, 0.3) end
                    GameTooltip:AddLine("Right-click to clear.", 0.5, 0.5, 0.5)
                end
                GameTooltip:Show()
            end)
            sq:SetScript("OnLeave", function(self)
                self.hl:Hide()
                GameTooltip_Hide()
            end)
            f.boxes[#f.boxes + 1] = sq
        end
    end

    -- while a spell is on the cursor, outline every square and light up the
    -- one under the mouse
    f.dragging = false
    f:SetScript("OnUpdate", function(self)
        local dragging = GetCursorInfo() == "spell"
        if dragging ~= self.dragging then
            self.dragging = dragging
            for _, sq in ipairs(self.boxes) do sq.drop:SetAlpha(dragging and 0.8 or 0) end
        end
        if dragging then
            for _, sq in ipairs(self.boxes) do sq.hl:SetShown(sq:IsMouseOver()) end
        end
    end)

    local hide = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    hide:SetSize(22, 22)
    hide:SetPoint("BOTTOMLEFT", 12, 36)
    local hideLabel = hide.Text or hide.text or hide:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hideLabel:ClearAllPoints()
    hideLabel:SetPoint("LEFT", hide, "RIGHT", 2, 0)
    hideLabel:SetFontObject("GameFontHighlightSmall")
    hideLabel:SetText("Hide Blizzard party and raid frames")
    hide:SetScript("OnClick", function(self) SetHideBlizzard(self:GetChecked() and true or false) end)
    f.hideBlizz = hide

    local pwr = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    pwr:SetSize(22, 22)
    pwr:SetPoint("BOTTOMLEFT", hide, "TOPLEFT", 0, 0)
    local pwrLabel = pwr.Text or pwr.text or pwr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pwrLabel:ClearAllPoints()
    pwrLabel:SetPoint("LEFT", pwr, "RIGHT", 2, 0)
    pwrLabel:SetFontObject("GameFontHighlightSmall")
    pwrLabel:SetText("Show mana / rage / energy bar")
    pwr:SetScript("OnClick", function(self)
        DB.showPower = self:GetChecked() and true or false
        for _, b in ipairs(buttons) do
            ApplyPowerShown(b)
            if b.unit and b:IsShown() then UpdatePower(b) end
        end
    end)
    f.showPower = pwr

    local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 16, 14)
    note:SetText("Red border: not in your spellbook yet. Saved per character.")

    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(150, 22)
    reset:SetPoint("BOTTOMRIGHT", -14, 10)
    reset:SetText("Reset to class defaults")
    reset:SetScript("OnClick", function()
        DB.binds[charKey] = ClassDefaults()
        for _, e in ipairs(f.boxes) do e:Refresh() end
        if not ApplyBindingsAll() then Msg("bindings will update after combat.") end
    end)

    local book = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    book:SetSize(110, 22)
    book:SetPoint("RIGHT", reset, "LEFT", -8, 0)
    book:SetText("|TInterface\\Icons\\INV_Misc_Book_09:14:14:0:0:64:64:5:59:5:59|t  Spellbook")
    book:SetScript("OnClick", function()
        if InCombatLockdown() then Msg("the spellbook can't be opened during combat.") return end
        if ToggleSpellBook then
            ToggleSpellBook(BOOKTYPE_SPELL or "spell")
        elseif PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then
            PlayerSpellsUtil.ToggleSpellBookFrame()
        elseif SpellBookFrame then
            ToggleFrame(SpellBookFrame)
        end
    end)

    f:SetScript("OnShow", function(self)
        for _, e in ipairs(self.boxes) do e:Refresh() end
        self.hideBlizz:SetChecked(DB.hideBlizzard)
        self.showPower:SetChecked(DB.showPower)
    end)
    f:Hide()
    return f
end

ToggleConfig = function()
    config = config or CreateConfig()
    config:SetShown(not config:IsShown())
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local function ForUnit(unit, fn)
    local list = byUnit[unit]
    if list then for _, b in ipairs(list) do fn(b) end end
end

local UNIT_EVENTS = {
    UNIT_HEALTH = OnHealthChanged,
    UNIT_HEALTH_FREQUENT = UpdateHealth,
    UNIT_MAXHEALTH = function(b) UpdateHealth(b); UpdateShield(b) end,
    UNIT_HEAL_PREDICTION = UpdateHealth,
    UNIT_ABSORB_AMOUNT_CHANGED = UpdateShield,
    UNIT_CONNECTION = UpdateAll,
    UNIT_FLAGS = UpdateHealth,
    UNIT_AURA = UpdateAuras,
    UNIT_POWER_UPDATE = UpdatePower,
    UNIT_POWER_FREQUENT = UpdatePower,
    UNIT_MAXPOWER = UpdatePower,
    UNIT_DISPLAYPOWER = UpdatePower,
    UNIT_THREAT_SITUATION_UPDATE = UpdateThreat,
    UNIT_NAME_UPDATE = UpdateIdentity,
}

local CAST_END = { UNIT_SPELLCAST_STOP = true, UNIT_SPELLCAST_FAILED = true,
    UNIT_SPELLCAST_INTERRUPTED = true, UNIT_SPELLCAST_SUCCEEDED = true }

ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "UNIT_SPELLCAST_START" then
        local list = byUnit[arg1]
        if list then for _, b in ipairs(list) do ShowCastCost(b, arg3) end end
        return
    elseif CAST_END[event] then
        local list = byUnit[arg1]
        if list then for _, b in ipairs(list) do HideCastCost(b) end end
        return
    end
    local fn = UNIT_EVENTS[event]
    if fn then ForUnit(arg1, fn) return end

    if event == "ADDON_LOADED" and arg1 == ADDON then
        ForeverHealBarsDB = ForeverHealBarsDB or {}
        DB = ForeverHealBarsDB
        DB.binds = DB.binds or {}
        DB.defaulted = DB.defaulted or {}
        if DB.locked == nil then DB.locked = true end
        if DB.hideBlizzard == nil then DB.hideBlizzard = true end
        if DB.showPower == nil then DB.showPower = false end
    elseif event == "PLAYER_LOGIN" then
        charKey = UnitName("player") .. "-" .. GetRealmName()
        -- give defaults to characters with no bindings, and upgrade ones still
        -- on the previous defaults; anything customised is left alone
        if DB.defaulted[charKey] ~= 3 then
            local b = DB.binds[charKey]
            local _, class = UnitClass("player")
            local stock = not b or not next(b)
            for _, set in ipairs(OLD_DEFAULTS) do
                if b and set[class] and SameBinds(b, set[class]) then stock = true end
            end
            if stock then DB.binds[charKey] = ClassDefaults() end
            DB.defaulted[charKey] = 3
        end
        OutOfCombat(function()
            CreateHeader()
            ApplySize(DB.w or W, DB.h or H)
            CreateLockButton()
            HideBlizzard()
            SetLocked(DB.locked)
        end)
        for e in pairs(UNIT_EVENTS) do pcall(ev.RegisterEvent, ev, e) end
        pcall(ev.RegisterEvent, ev, "UNIT_SPELLCAST_START")
        for e in pairs(CAST_END) do pcall(ev.RegisterEvent, ev, e) end
        ev:RegisterEvent("GROUP_ROSTER_UPDATE")
        ev:RegisterEvent("PLAYER_TARGET_CHANGED")
        ev:RegisterEvent("PLAYER_ENTERING_WORLD")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        pcall(ev.RegisterEvent, ev, "SPELLS_CHANGED")
        RefreshCures()
    elseif event == "PLAYER_TARGET_CHANGED" then
        for _, b in ipairs(buttons) do if b.unit and b:IsShown() then UpdateSelected(b) end end
    elseif event == "SPELLS_CHANGED" then
        RefreshCures()
        for _, b in ipairs(buttons) do if b.unit and b:IsShown() then UpdateAuras(b) end end
    elseif event == "PLAYER_REGEN_ENABLED" then
        local list = pending
        pending = {}
        for _, f in ipairs(list) do f() end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        Remap()
        C_Timer.After(0.1, UpdateMover)
        HideBlizzard()
        for _, b in ipairs(buttons) do if b:IsShown() then UpdateAll(b) end end
    end
end)
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")

-- Range is polled (there is no event for it). Buffs and debuffs are also
-- re-checked every half second as a safety net, in case the game's aura
-- events arrive late; that also keeps HoT segments ticking down.
local elapsed, auraTick = 0, 0
ev:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.2 then return end
    elapsed = 0
    auraTick = auraTick + 1
    local auras = auraTick % 2 == 0                    -- ~every 0.4s
    for _, b in ipairs(buttons) do
        if b.unit and b:IsShown() then
            UpdateRange(b)
            if auras then UpdateAuras(b) end
        end
    end
end)

---------------------------------------------------------------------------
-- /fhb
---------------------------------------------------------------------------
SLASH_FOREVERHEALBARS1 = "/fhb"
SLASH_FOREVERHEALBARS2 = "/healbars"
SlashCmdList.FOREVERHEALBARS = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "bind" or cmd == "config" then
        ToggleConfig()
    elseif cmd == "unlock" or cmd == "move" then
        SetLocked(false)
    elseif cmd == "lock" then
        SetLocked(true)
    elseif cmd == "scale" then
        local s = tonumber(arg)
        if not s or s < 0.5 or s > 2 then Msg("scale must be between 0.5 and 2.") return end
        DB.scale = s
        if not OutOfCombat(function() ApplyScale(s) end) then Msg("will rescale after combat.") end
    elseif cmd == "debug" then
        local u = (arg ~= "" and arg) or (UnitExists("target") and "target") or "player"
        local function show(v)
            if v == nil then return "nil" end
            if issecretvalue and issecretvalue(v) then return "<hidden>" end
            return tostring(v)
        end
        local cures = {}
        for t in pairs(canDispel) do cures[#cures + 1] = t end
        Msg("debuffs on %s  |  you can cure: %s", u, #cures > 0 and table.concat(cures, ", ") or "nothing")
        local okAll, err = pcall(function()
            for i = 1, 40 do
                local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HARMFUL")
                if not a then
                    if i == 1 then Msg("  no debuffs found") end
                    break
                end
                Msg("  %d. %s  type=%s", i, show(a.name), show(a.dispelName))
            end
            local r = C_UnitAuras.GetAuraDataByIndex(u, 1, "HARMFUL|RAID")
            Msg("  game's dispellable filter: %s", r and ("found " .. show(r.name)) or "nothing")
            -- what each frame showing this player computed for its HoT segment
            for _, b in ipairs(buttons) do
                if b.unit and b:IsShown() then
                    local same = (b.unit == u) or select(2, pcall(UnitIsUnit, b.unit, u)) == true
                    if same then
                        local hot = b.c.hot
                        local okv, v = pcall(hot.GetValue, hot)
                        local okw, w = pcall(function() return hot:GetStatusBarTexture():GetWidth() end)
                        Msg("  HoT segment on %s: amount=%s  shown=%s  bar value=%s  fill width=%s  frame width=%s",
                            b.unit, show(b.hotAmount), tostring(hot:IsShown()), okv and show(v) or "?",
                            okw and show(w) or "?", show(hot:GetWidth()))
                    end
                end
            end
            Msg("buffs on %s:", u)
            for i = 1, 40 do
                local b = C_UnitAuras.GetAuraDataByIndex(u, i, "HELPFUL")
                if not b then
                    if i == 1 then Msg("  no buffs found") end
                    break
                end
                local okp, p1 = pcall(function() return b.points and b.points[1] end)
                if not okp then p1 = "<hidden>" end
                Msg("  %d. %s  from=%s  duration=%s  tick=%s", i, show(b.name), show(b.sourceUnit),
                    show(b.duration), show(p1))
            end
        end)
        if not okAll then Msg("  couldn't read debuffs: %s", tostring(err)) end
    elseif cmd == "blizzard" then
        SetHideBlizzard(not DB.hideBlizzard)
    elseif cmd == "reset" then
        DB.pos, DB.scale, DB.w, DB.h = nil, 1, nil, nil
        if not OutOfCombat(function() PlaceAnchor(); ApplyScale(1); ApplySize(W, H) end) then
            Msg("will reset after combat.")
        end
    else
        Msg("/fhb  (click-casting)  |  /fhb unlock  |  /fhb lock  |  /fhb scale 0.5-2  |  /fhb blizzard  |  /fhb reset")
    end
end
