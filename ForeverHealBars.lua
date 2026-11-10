-- Forever Heal Bars: a minimalist grid of party/raid frames for healers.
-- Click-casting, your HoTs, dispellable debuffs, incoming heals, range and aggro.

local ADDON = ...
local PREFIX = "|cff33ff99Forever Heal Bars|r: "

local W, H, GAP = 72, 46, 3          -- button size and spacing
local MAX_BUTTONS = 40
local OOR_DIM = 0.65                  -- darkness of the overlay on out-of-range players
local HOT_SIZE, MAX_HOTS = 11, 3
local POWER_H = 3                     -- height of the resource bar
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

local DEBUFF_COLOR = DebuffTypeColor or {
    Magic = { r = .2, g = .6, b = 1 }, Curse = { r = .6, g = 0, b = 1 },
    Disease = { r = .6, g = .4, b = 0 }, Poison = { r = 0, g = .6, b = 0 },
}

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

    -- tints the empty part of the frame while a dispellable debuff is up
    local tint = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    tint:SetAllPoints()
    tint:Hide()
    c.tint = tint

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

    -- Incoming heals: a second bar that starts where the health fill ends and
    -- uses the same max, so its fill width equals the incoming amount. The
    -- container clips anything past the frame's edge (overheal).
    c:SetClipsChildren(true)
    local inc = CreateFrame("StatusBar", nil, c)
    inc:SetStatusBarTexture(BAR)
    inc:SetStatusBarColor(0.47, 0.9, 0.55, 0.85)
    inc:SetPoint("TOPLEFT", hp:GetStatusBarTexture(), "TOPRIGHT")
    inc:SetPoint("BOTTOMLEFT", hp:GetStatusBarTexture(), "BOTTOMRIGHT")
    inc:SetWidth(W)
    inc:SetMinMaxValues(0, 1)
    inc:SetValue(0)
    inc:SetFrameLevel(hp:GetFrameLevel())
    c.inc = inc

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

    -- dispellable debuff: the whole frame takes the debuff type's color
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

    c.dispel = {}
    function c.dispel:Set(r, g, b)
        if r then
            btn.dispelled = true
            c.hp:SetStatusBarColor(r, g, b)
            c.dmg:SetStatusBarColor(r, g, b)
            c.tint:SetColorTexture(r, g, b, 0.45)
            c.tint:Show()
        else
            btn.dispelled = false
            local col = btn.classColor
            c.hp:SetStatusBarColor(col[1], col[2], col[3])
            c.dmg:SetStatusBarColor(col[1], col[2], col[3])
            c.tint:Hide()
        end
    end
    c.aggro = Border(text, 2, 2)      -- outside edge: threat
    c.aggro:Set(0.9, 0.15, 0.15)
    c.aggro:SetAlpha(0)
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

local function UpdateHealth(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    local max = UnitHealthMax(u)
    c.hp:SetMinMaxValues(0, max)
    c.hp:SetValue(UnitHealth(u))
    c.inc:SetMinMaxValues(0, max)
    c.inc:SetValue(UnitGetIncomingHeals and UnitGetIncomingHeals(u) or 0)

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
local DAMAGE_FLASH = 1
local function OnHealthChanged(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    local cur = UnitHealth(u)
    c.dmg:SetMinMaxValues(0, UnitHealthMax(u))
    c.dmg:SetValue(btn.lastHealth or cur)
    c.dmg:Show()
    btn.lastHealth = cur
    btn.dmgToken = (btn.dmgToken or 0) + 1
    local token = btn.dmgToken
    C_Timer.After(DAMAGE_FLASH, function()
        if btn.dmgToken == token then c.dmg:Hide() end
    end)
    UpdateHealth(btn)
end

-- Mana, rage, energy (and friends). The type is readable; the amounts can be
-- secret, so they go straight to the bar.
local POWER_COLOR = {
    MANA = { 0.25, 0.5, 1 }, RAGE = { 0.9, 0.15, 0.15 }, ENERGY = { 1, 0.85, 0.2 },
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
    c.power:SetMinMaxValues(0, UnitPowerMax(u))
    c.power:SetValue(UnitPower(u))
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
    if not btn.dispelled then
        local cc = btn.classColor
        c.hp:SetStatusBarColor(cc[1], cc[2], cc[3])
        c.dmg:SetStatusBarColor(cc[1], cc[2], cc[3])
    end
end

-- Color for a debuff the player can dispel. Readable dispel type first; if
-- that's hidden, ask the game to map it to a color for us.
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
            dispelCurve:AddPoint(1, CreateColor(0.2, 0.6, 1, 1))
            dispelCurve:AddPoint(2, CreateColor(0.6, 0, 1, 1))
            dispelCurve:AddPoint(3, CreateColor(0.6, 0.4, 0, 1))
            dispelCurve:AddPoint(4, CreateColor(0, 0.6, 0, 1))
        end
        return C_UnitAuras.GetAuraDispelTypeColor(u, a.auraInstanceID, dispelCurve):GetRGB()
    end
    return 0.8, 0.8, 0.8
end

local function UpdateAurasModern(btn)
    local u, c = btn.unit, btn.c
    -- your HoTs and shields ("RAID" = the buffs worth showing on raid frames)
    local n = 0
    for i = 1, 40 do
        local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HELPFUL|PLAYER|RAID")
        if not a or n >= MAX_HOTS then break end
        n = n + 1
        c.hots[n]:SetTexture(a.icon)
        c.hots[n]:Show()
    end
    for k = n + 1, MAX_HOTS do c.hots[k]:Hide() end

    -- "HARMFUL|RAID" = debuffs you can dispel; the first one colors the border
    local a = C_UnitAuras.GetAuraDataByIndex(u, 1, "HARMFUL|RAID")
    if a then c.dispel:Set(DispelColor(u, a)) else c.dispel:Set(nil) end
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
        if dtype and DEBUFF_COLOR[dtype] then found = DEBUFF_COLOR[dtype]; break end
        i = i + 1
    end
    if found then c.dispel:Set(found.r, found.g, found.b) else c.dispel:Set(nil) end
end

local function UpdateAuras(btn)
    local u = btn.unit
    if not u or not UnitExists(u) then return end
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

local function UpdateAll(btn)
    UpdateIdentity(btn)
    UpdateHealth(btn)
    UpdatePower(btn)
    UpdateAuras(btn)
    UpdateThreat(btn)
    UpdateRange(btn)
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
            b.c.dmg:Hide()
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
    local colW, rowH = 130, 30
    f:SetSize(90 + colW * #CLICKS + 20, 176 + rowH * #MODS)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, f:GetName())   -- Escape closes it

    local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not f.TitleText then title:SetPoint("TOP", 0, -5) end
    title:SetText("Forever Heal Bars settings")

    local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 16, -32)
    help:SetPoint("TOPRIGHT", -16, -32)
    help:SetJustifyH("LEFT")
    help:SetText("Type a spell name as it appears in your spellbook, then press Enter. "
        .. "|cffaaaaaatarget|r and |cffaaaaaamenu|r also work. Blank plain left / right = target / menu.")

    local top = -78
    for c, label in ipairs(CLICK_LABEL) do
        local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", 90 + (c - 1) * colW, top)
        h:SetText(label)
    end

    f.boxes = {}
    for r, mod in ipairs(MODS) do
        local y = top - 20 - (r - 1) * rowH
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        l:SetPoint("TOPLEFT", 18, y - 4)
        l:SetText(MOD_LABEL[mod])
        for c, click in ipairs(CLICKS) do
            local key = mod .. click
            local icon = f:CreateTexture(nil, "ARTWORK")
            icon:SetSize(18, 18)
            icon:SetPoint("TOPLEFT", 90 + (c - 1) * colW, y)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local e = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
            e:SetSize(colW - 34, 20)
            e:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            e:SetAutoFocus(false)
            e.key, e.icon = key, icon

            function e:Refresh()
                local v = Binds()[self.key] or ""
                self:SetText(v)
                self:SetCursorPosition(0)
                local low = v:lower()
                if v == "" or low == "target" or low == "menu" then
                    self.icon:Hide()
                    self:SetTextColor(1, 1, 1)
                else
                    local name, tex = SpellInfo(v)
                    self.icon:SetTexture(tex or 134400)  -- question mark if unknown
                    self.icon:Show()
                    if name then self:SetTextColor(1, 1, 1) else self:SetTextColor(1, 0.3, 0.3) end
                end
            end
            local function Save(self)
                local v = strtrim(self:GetText() or "")
                Binds()[self.key] = (v ~= "") and v or nil
                self:Refresh()
                if not ApplyBindingsAll() then Msg("bindings will update after combat.") end
            end
            e:SetScript("OnEnterPressed", function(self) Save(self); self:ClearFocus() end)
            e:SetScript("OnEditFocusLost", Save)
            e:SetScript("OnEscapePressed", function(self) self:Refresh(); self:ClearFocus() end)
            f.boxes[#f.boxes + 1] = e
        end
    end

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
    note:SetText("Red: not in your spellbook yet. Saved per character.")

    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(150, 22)
    reset:SetPoint("BOTTOMRIGHT", -14, 10)
    reset:SetText("Reset to class defaults")
    reset:SetScript("OnClick", function()
        DB.binds[charKey] = ClassDefaults()
        for _, e in ipairs(f.boxes) do e:Refresh() end
        if not ApplyBindingsAll() then Msg("bindings will update after combat.") end
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
    UNIT_MAXHEALTH = UpdateHealth,
    UNIT_HEAL_PREDICTION = UpdateHealth,
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

ev:SetScript("OnEvent", function(_, event, arg1)
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
        ev:RegisterEvent("GROUP_ROSTER_UPDATE")
        ev:RegisterEvent("PLAYER_ENTERING_WORLD")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
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

-- Range is polled; there is no event for it.
local elapsed = 0
ev:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.2 then return end
    elapsed = 0
    for _, b in ipairs(buttons) do
        if b.unit and b:IsShown() then UpdateRange(b) end
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
