-- Forever Heal Bars: a minimalist grid of party/raid frames for healers.
-- Click-casting, your HoTs, dispellable debuffs, incoming heals, range and aggro.

local ADDON = ...
local PREFIX = "|cff33ff99Forever Heal Bars|r: "

local W, H, GAP = 72, 46, 3          -- button size and spacing
-- Text grows and shrinks with the frames: 10 pt at the default size, never
-- below 9 pt (smaller gets hard to read) or above 18 pt.
local FONT_BASE, FONT_MIN, FONT_MAX = 10, 9, 18
local fontSize, nameLift = FONT_BASE, 6   -- current name size; how far the name sits above centre
local MAX_BUTTONS = 40
local OOR_DIM = 0.65                  -- darkness of the overlay on out-of-range players
local HOT_SIZE, MAX_HOTS = 11, 3
local DISPEL_EDGE = 3                  -- thick, steady border in the debuff colour (the wash breathes)
local ROLE_SIZE = 11
local NEED_SIZE = 12
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
local CLICKS = { 1, 2, 3, 4, 5, 6, 7 }
local CLICK_LABEL = { "Left", "Right", "Middle", "Mouse 4", "Mouse 5", "Wheel up", "Wheel down" }
-- The mouse wheel isn't a click: while the pointer is over a frame, the wheel
-- is bound to "click" it with these made-up button names instead.
local WHEEL = { [6] = { key = "MOUSEWHEELUP", button = "wheelup" },
                [7] = { key = "MOUSEWHEELDOWN", button = "wheeldown" } }
-- attribute suffix the secure button code uses for each click
local function ClickSuffix(click)
    return WHEEL[click] and ("-" .. WHEEL[click].button) or tostring(click)
end

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
local AGGRO_COLOR = { 1, 0.08, 0.08 }   -- red outline: has aggro
local SHIELD_TINT = { 0.59, 0.82, 1 }  -- pale blue under the shield stripes
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
local OLD_DEFAULTS
do
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

    OLD_DEFAULTS = { V020, V021 }
end

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
local BuildAuraBoxes                  -- the game-drawn dispel glow and HoT icons, below
local MakeDebuffBox
local BuildTremorFx                   -- the Tremor Totem stripes, below

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

    -- Shields, part 2: white stripes on a pale blue tint in the missing
    -- health, after incoming heals and HoTs, showing how much of what they're
    -- missing the shield covers. (The strip along the top shows its full
    -- size, which matters at full health where there's no room here.)
    -- Two bars with the same value: a tint and the stripes. A status bar
    -- hides its own fill at zero, so both vanish cleanly with no shield.
    local function AbsorbBar(texture, r, g, b, a)
        local bar = CreateFrame("StatusBar", nil, c)
        bar:SetStatusBarTexture(texture)
        bar:SetStatusBarColor(r, g, b, a)
        bar:SetWidth(W)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        bar:SetFrameLevel(hot:GetFrameLevel())
        return bar
    end
    c.absorbTint = AbsorbBar(BAR, SHIELD_TINT[1], SHIELD_TINT[2], SHIELD_TINT[3], 0.35)
    c.absorbStripes = AbsorbBar(string.format("Interface\\AddOns\\%s\\media\\stripes", ADDON), 1, 1, 1, 0.8)
    local fill = c.absorbStripes:GetStatusBarTexture()
    fill:SetTexture(string.format("Interface\\AddOns\\%s\\media\\stripes", ADDON), "REPEAT", "REPEAT")
    fill:SetHorizTile(true)
    fill:SetVertTile(true)

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

    -- role: a small tank / healer / damage icon in the bottom-right corner
    -- (kept off the top edge, where the shield bar runs; clear of the mana bar)
    local role = text:CreateTexture(nil, "OVERLAY")
    role:SetSize(ROLE_SIZE, ROLE_SIZE)
    role:SetPoint("BOTTOMRIGHT", -2, 2 + POWER_H)
    role:Hide()
    c.role = role

    -- buffs this player needs from you: icons flashing beside the role icon
    local need = CreateFrame("Frame", nil, text)
    need:SetPoint("BOTTOMRIGHT", -(ROLE_SIZE + 4), 2 + POWER_H)
    need:SetSize((NEED_SIZE + 1) * 3, NEED_SIZE)
    need:Hide()
    c.need = need
    c.needIcons = {}
    for i = 1, 3 do
        local t = need:CreateTexture(nil, "OVERLAY")
        t:SetSize(NEED_SIZE, NEED_SIZE)
        t:SetPoint("BOTTOMRIGHT", -(i - 1) * (NEED_SIZE + 1), 0)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t:Hide()
        c.needIcons[i] = t
    end
    local flash = need:CreateAnimationGroup()
    flash:SetLooping("BOUNCE")
    local fa = flash:CreateAnimation("Alpha")
    fa:SetFromAlpha(1)
    fa:SetToAlpha(0.15)
    fa:SetDuration(0.5)
    fa:SetSmoothing("IN_OUT")
    c.needFlash = flash

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
    BuildAuraBoxes(btn)
    c.tremor = BuildTremorFx(c, c, c.hp:GetFrameLevel() + 5)
    c.tremor:Hide()
    -- threat: an outline just outside the frame. It lives on the unit button,
    -- not inside the frame body, which cuts off anything past its edges.
    local aggroF = CreateFrame("Frame", nil, btn)
    aggroF:SetAllPoints(c)
    aggroF:SetFrameLevel(selF:GetFrameLevel() + 1)
    c.aggro = Border(aggroF, 2, 2)
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

    local outline = Border(fx, 0, DISPEL_EDGE)

    c.dispel = {}
    function c.dispel:Set(r, g, b)
        if not r then
            pulse:Stop()
            fx:Hide()
            self.shown = false
            return
        end
        wash:SetVertexColor(r, g, b)
        outline:Set(r, g, b)
        fx:Show()
        self.shown = true
        if not pulse:IsPlaying() then pulse:Play() end
    end
end

---------------------------------------------------------------------------
-- Game-drawn auras. In combat WoW Forever refuses addon code every buff and
-- debuff. The game's own aura containers still draw them: given a unit and a
-- filter they fill their buttons themselves, and tint textures we hand them
-- by debuff type. So the dispel glow and the HoT icons are built on those
-- whenever the game has them; the addon's own readers are only the fallback.
---------------------------------------------------------------------------
local Flow = AnchorUtil and AnchorUtil.FlowDirection
local DISPEL_TINT = Enum.CustomAuraButtonDispelTypeTextureStyle
local HOT_MAX_SECONDS = 30            -- only short buffs (HoTs, shields) get an icon
local MAX_DEBUFF_ICONS = 4

local function NewAuraBox(c, point, hDir)
    local ok, box = pcall(CreateFrame, "AuraContainer", nil, c, "CustomAuraContainerTemplate")
    if not ok or not box then return nil end
    local set = pcall(function()
        box:SetPoint(point, c, point, point:find("RIGHT") and -2 or 0, point:find("TOP") and -2 or 0)
        box:SetFlowLayoutAnchorPoint(point)
        box:SetFlowLayoutGrowthDirection(hDir, point:find("TOP") and Flow.Down or Flow.Up)
        box:EnableMouse(false)
        if box.SetEditModePreviewEnabled then box:SetEditModePreviewEnabled(false) end
    end)
    if not set then box:Hide() return nil end
    return box
end

-- each dispel button the game makes gets the frame-wide glow and outline;
-- the game shows it only while there's a debuff you can remove, tinted by type
local function InitDispelButton(btn, c)
    pcall(btn.SetIcon, btn, btn.Icon)
    btn:EnableMouse(false)
    if btn.fhbGlow then return end
    local holder = CreateFrame("Frame", nil, btn)
    holder:SetAllPoints(c)
    holder:SetFrameLevel(c.hp:GetFrameLevel() + 1)        -- over the bars, under the name
    local wash = holder:CreateTexture(nil, "ARTWORK")
    wash:SetAllPoints()
    wash:SetTexture(BAR)
    local edges = {}
    for i = 1, 4 do edges[i] = holder:CreateTexture(nil, "OVERLAY") end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(DISPEL_EDGE)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(DISPEL_EDGE)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(DISPEL_EDGE)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(DISPEL_EDGE)
    for _, t in ipairs({ wash, unpack(edges) }) do
        if t ~= wash then t:SetTexture(BAR) end
        pcall(btn.AddDispelTypeTexture, btn, t, { style = DISPEL_TINT and DISPEL_TINT.PreserveAsset })
    end
    -- the same slow breathing as before (the wash only; the outline stays put)
    local pulse = wash:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local a = pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(0.6)
    a:SetToAlpha(0.3)
    a:SetDuration(1.25)
    a:SetSmoothing("IN_OUT")
    pulse:Play()
    btn.fhbGlow = holder
end

-- Debuffs never worth a slot, by name. The game only filters by spell ID,
-- so each one's ID is read off your own debuffs out of combat, saved, and
-- left out from then on (in combat too).
local IGNORED_DEBUFFS = { ["Boosted Rest"] = true }    -- Camp Tent rest bonus
local ApplyIconsRef                                    -- set once icon sizing is defined below
local debuffRowMode = "not built"                      -- for /fhb debug
-- The game accepts a spell ID exclusion for debuffs but doesn't apply it, so
-- long effects are also left out by length: anything over 30 minutes (the
-- hour-long Boosted Rest, lockouts). Fight debuffs are far shorter, and
-- Resurrection Sickness (10 minutes) still shows.
local DEBUFF_MAX_SECONDS = 1800

-- every debuff on the player, dispellable or not: small icons, bottom left
MakeDebuffBox = function(c)
    local box = NewAuraBox(c, "BOTTOMLEFT", Flow and Flow.Right)
    local exclude = {}
    for id in pairs(DB and DB.ignoredDebuffIDs or {}) do exclude[id] = true end
    local function group(filters)
        return pcall(box.AddAuraGroup, box, "debuffs", "HARMFUL", {
            maxFrameCount = MAX_DEBUFF_ICONS,
            templateNames = { "ForeverHealBarsHotTemplate" },
            initializeFrame = function(b)
                pcall(b.SetIcon, b, b.Icon)
                b:EnableMouse(false)
            end,
            candidateFilters = filters,
            layout = { elementSpacing = 1 },
        })
    end
    -- (if the game ever refuses the exclusion, still show the debuffs)
    debuffRowMode = "no exclusions"
    if box then
        local filters = { maxDuration = DEBUFF_MAX_SECONDS }
        if next(exclude) then filters.excludeSpellIDs = exclude end
        local ok, err = group(filters)
        if ok then
            debuffRowMode = "up to 30 min long" .. (next(exclude) and ", excluding learned IDs" or "")
        else
            debuffRowMode = "filters refused: " .. tostring(err)
            box:Hide()
            box = NewAuraBox(c, "BOTTOMLEFT", Flow and Flow.Right)
            if box and not group(nil) then box:Hide(); box = nil end
        end
    end
    if box then
        box:ClearAllPoints()
        box:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 2, 2 + POWER_H)      -- clear of the mana bar
        pcall(box.SetFrameLevel, box, c.hp:GetFrameLevel() + 3)
    end
    return box
end

-- out of combat: look for ignored debuffs on a unit; learning a new ID swaps
-- every frame's debuff row for one that leaves it out
local function LearnIgnoredDebuffs(u)
    if InCombatLockdown() or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    local learned = false
    pcall(function()
        for i = 1, 40 do
            local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HARMFUL")
            if not a then break end
            local name, id = a.name, a.spellId
            if Readable(name) and Readable(id) and IGNORED_DEBUFFS[name] then
                DB.ignoredDebuffIDs = DB.ignoredDebuffIDs or {}
                if not DB.ignoredDebuffIDs[id] then
                    DB.ignoredDebuffIDs[id] = true
                    learned = true
                end
            end
        end
    end)
    if not learned then return end
    for _, b in ipairs(buttons) do
        local c = b.c
        if c and c.debuffBox then
            pcall(c.debuffBox.SetUnit, c.debuffBox, "none")
            c.debuffBox:Hide()
            c.debuffBox = MakeDebuffBox(c)
            if c.debuffBox and b.unit then pcall(c.debuffBox.SetUnit, c.debuffBox, b.unit) end
            if ApplyIconsRef then ApplyIconsRef(b) end
        end
    end
end


---------------------------------------------------------------------------
-- Tremor Totem: fear, sleep and charm. Amber and black warning stripes slide
-- along the top and bottom edges, with a FEAR / SLEEP / CHARM tag.
-- In combat the game hides debuffs from addons, so three routes are used:
--  1. the game's own aura frames, each told to look only for known fear,
--     sleep or charm spells (the only route that can work in combat). Until
--     the addon has seen that the game really applies that list (a debuff
--     that isn't one of them is NOT picked up), these stay invisible;
--  2. the game's "is this player charmed" check;
--  3. reading the debuffs by name, out of combat.
---------------------------------------------------------------------------
local Tremor = {}                     -- fear / sleep / charm (Tremor Totem), below
do
    local TREMOR_KINDS = {
        fear = { tag = "FEAR",
            names = { "Fear", "Psychic Scream", "Howl of Terror", "Intimidating Shout", "Scare Beast",
                      "Bellowing Roar", "Panic", "Terrify", "Terrifying Screech", "Terrifying Howl",
                      "Terrifying Roar", "Frightening Shout", "Intimidating Roar" },
            ids = { 5782, 6213, 6215, 8122, 8124, 10888, 10890, 5484, 17928, 5246, 1513, 14326, 14327,
                    18431, 19408, 7399, 6605, 12096, 22686, 16508, 19134, 13704, 22884 } },
        sleep = { tag = "SLEEP",
            names = { "Sleep", "Hibernate", "Wyvern Sting", "Druid's Slumber", "Deep Sleep" },
            ids = { 700, 1090, 8399, 12098, 2637, 18657, 18658, 19386, 24132, 24133, 8040 } },
        charm = { tag = "CHARM",
            names = { "Mind Control", "Seduction", "Dominate Mind", "Domination", "Cause Insanity",
                      "True Fulfillment", "Gnomish Mind Control Cap" },
            ids = { 605, 10911, 10912, 6358, 20604, 7645, 14515, 15859, 24327, 785, 13180 } },
    }
    local TREMOR_NAME, TREMOR_ID = {}, {}
    for kind, k in pairs(TREMOR_KINDS) do
        k.idset = {}
        for _, n in ipairs(k.names) do TREMOR_NAME[n] = kind end
        for _, id in ipairs(k.ids) do TREMOR_ID[id] = kind; k.idset[id] = true end
    end
    local STRIPE_H = 6
    local HAZARD = "Interface\\AddOns\\" .. ADDON .. "\\media\\hazard"
    local TREMOR_TEXT = { 0.84, 0.63, 0.27 }
    Tremor.probe = "not seen yet"           -- for /fhb debug

    -- the stripes and tag, over the unit frame c (parent decides when it shows)
    BuildTremorFx = function(parent, c, level)
        local fx = CreateFrame("Frame", nil, parent)
        fx:SetAllPoints(c)
        fx:SetFrameLevel(level)
        local function strip(a1, a2)
            local t = fx:CreateTexture(nil, "OVERLAY")
            t:SetTexture(HAZARD, "REPEAT", "CLAMP")
            t:SetPoint(a1)
            t:SetPoint(a2)
            t:SetHeight(STRIPE_H)
            return t
        end
        local top, bottom = strip("TOPLEFT", "TOPRIGHT"), strip("BOTTOMLEFT", "BOTTOMRIGHT")
        local tagBg = fx:CreateTexture(nil, "ARTWORK")
        tagBg:SetColorTexture(0.08, 0.07, 0.05, 0.9)
        local tag = fx:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tag:SetPoint("BOTTOM", 0, STRIPE_H + 2)
        tag:SetTextColor(TREMOR_TEXT[1], TREMOR_TEXT[2], TREMOR_TEXT[3])
        tagBg:SetPoint("TOPLEFT", tag, "TOPLEFT", -3, 1)
        tagBg:SetPoint("BOTTOMRIGHT", tag, "BOTTOMRIGHT", 3, -1)
        fx.off = 0
        fx:SetScript("OnUpdate", function(self, elapsed)
            if self.gated then self:SetAlpha(DB.tremorBoxOK and 1 or 0) end
            self.off = (self.off + elapsed * 0.5) % 1
            local span = 64 * STRIPE_H / 16           -- one copy of the texture, in pixels
            local reach = (self:GetWidth() or 0) / span
            top:SetTexCoord(self.off, self.off + reach, 0, 1)
            bottom:SetTexCoord(-self.off, -self.off + reach, 0, 1)   -- the other way
        end)
        function fx:SetKind(kind)
            tag:SetText(TREMOR_KINDS[kind] and TREMOR_KINDS[kind].tag or "TREMOR")
        end
        fx:SetKind(nil)
        return fx
    end

    -- one of the game's aura frames per kind, each limited to that kind's spells
    Tremor.MakeBoxes = function(c)
        local boxes = {}
        for kind, k in pairs(TREMOR_KINDS) do
            local box = NewAuraBox(c, "CENTER", Flow and Flow.Right)
            if box and pcall(box.AddAuraGroup, box, "tremor-" .. kind, "HARMFUL", {
                maxFrameCount = 1,
                templateNames = { "ForeverHealBarsDispelTemplate" },
                initializeFrame = function(b)
                    pcall(b.SetIcon, b, b.Icon)
                    b:EnableMouse(false)
                    if not b.fhbTremor then
                        b.fhbTremor = BuildTremorFx(b, c, c.hp:GetFrameLevel() + 5)
                        b.fhbTremor.gated = true          -- invisible until the game's filter is proven
                    end
                    b.fhbTremor:SetKind(kind)
                b.fhbKind = kind
                end,
                candidateFilters = { includeSpellIDs = k.idset },
            }) then
                pcall(box.SetFrameLevel, box, c.hp:GetFrameLevel() + 5)
                pcall(box.SetUnit, box, "none")
                boxes[#boxes + 1] = box
            elseif box then
                box:Hide()
            end
        end
        return boxes
    end

    -- is one of the game's tremor frames on this unit frame showing right now?
    local function TremorBoxShowing(c)
        for _, box in ipairs(c.tremorBoxes or {}) do
            for _, child in ipairs({ box:GetChildren() }) do
                if child.fhbTremor and child:IsShown() and child.fhbTremor:IsShown() then return true end
            end
        end
        return false
    end

    -- what the addon can read itself: charm check, then debuff names / IDs
    local function ReadTremor(u)
        if UnitIsCharmed then
            local ok, charmed = pcall(UnitIsCharmed, u)
            if ok and Readable(charmed) and charmed then return "charm", true end
        end
        local kind, otherDebuff
        local ok = pcall(function()
            for i = 1, 40 do
                local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HARMFUL")
                if not a then break end
                local k = (Readable(a.name) and TREMOR_NAME[a.name]) or (Readable(a.spellId) and TREMOR_ID[a.spellId])
                if k then kind = kind or k else otherDebuff = true end
            end
        end)
        return kind, ok, otherDebuff
    end

    Tremor.Update = function(btn)
        local c, u = btn.c, btn.unit
        if not (c.tremor and u and UnitExists(u)) then return end
        local kind, readable, otherDebuff = ReadTremor(u)
        if readable and C_UnitAuras.GetAuraDataByIndex and DB.tremorBoxOK == nil and c.tremorBoxes and #c.tremorBoxes > 0 then
            -- prove (or disprove) that the game applies the spell lists: a debuff
            -- that isn't fear / sleep / charm must not light the game's frames up
            -- (the same answer three checks in a row, about a second, so a frame
            -- that hasn't caught up yet can't decide it)
            local showing = TremorBoxShowing(c)
            local verdict = (showing and not kind) and "bad" or (otherDebuff and not kind and not showing) and "good" or nil
            btn.tremorVotes = (verdict and verdict == btn.tremorVerdict) and (btn.tremorVotes or 0) + 1 or (verdict and 1 or 0)
            btn.tremorVerdict = verdict
            if verdict == "bad" and btn.tremorVotes >= 3 then
                DB.tremorBoxOK = false
                Tremor.probe = "the game ignores the spell list (in combat: charm only)"
            elseif verdict == "good" and btn.tremorVotes >= 3 then
                DB.tremorBoxOK = true
                Tremor.probe = "the game applies the spell list (works in combat)"
            end
        end
        if DB.tremorBoxOK == false then
            for _, box in ipairs(c.tremorBoxes or {}) do box:Hide() end
        end
        -- our own stripes: whatever we could read; the game's frames cover combat
        if kind then
            c.tremor:SetKind(kind)
            c.tremor:Show()
        else
            c.tremor:Hide()
        end
    end
    Tremor.Read = ReadTremor
    -- for /fhb debug: which of the game's fear / sleep / charm frames are lit
    Tremor.Lit = function(c)
        local lit, built = {}, #(c.tremorBoxes or {})
        for _, box in ipairs(c.tremorBoxes or {}) do
            for _, child in ipairs({ box:GetChildren() }) do
                if child.fhbTremor and child:IsShown() then lit[#lit + 1] = child.fhbKind or "?" end
            end
        end
        return built, lit
    end
end

BuildAuraBoxes = function(btn)
    local c = btn.c
    if not Flow then return end
    local dispel = NewAuraBox(c, "BOTTOMLEFT", Flow and Flow.Right)
    if dispel and not pcall(dispel.AddAuraGroup, dispel, "dispel", "HARMFUL|RAID", {
        maxFrameCount = 1,
        templateNames = { "ForeverHealBarsDispelTemplate" },
        initializeFrame = function(b) InitDispelButton(b, c) end,
    }) then dispel:Hide(); dispel = nil end
    local hots = NewAuraBox(c, "TOPRIGHT", Flow and Flow.Left)
    if hots and not pcall(hots.AddAuraGroup, hots, "hots", "HELPFUL|PLAYER", {
        maxFrameCount = MAX_HOTS,
        templateNames = { "ForeverHealBarsHotTemplate" },
        initializeFrame = function(b)
            pcall(b.SetIcon, b, b.Icon)
            b:EnableMouse(false)
        end,
        candidateFilters = { maxDuration = HOT_MAX_SECONDS },
        layout = { elementSpacing = 1 },
    }) then hots:Hide(); hots = nil end
    local debuffs = MakeDebuffBox(c)
    for _, box in ipairs({ dispel, hots, debuffs }) do
        pcall(box.SetFrameLevel, box, c.hp:GetFrameLevel() + 3)
        pcall(box.SetUnit, box, "none")
    end
    c.dispelBox, c.hotBox, c.debuffBox = dispel, hots, debuffs
    if DB.tremorBoxOK ~= false then c.tremorBoxes = Tremor.MakeBoxes(c) end
end

-- point the containers at the frame's player (also called in combat)
local function SetAuraBoxUnit(btn, unit)
    local list = { btn.c.dispelBox, btn.c.hotBox, btn.c.debuffBox }
    for _, box in ipairs(btn.c.tremorBoxes or {}) do list[#list + 1] = box end
    for _, box in ipairs(list) do
        if box then
            pcall(function()
                if box:GetUnit() ~= (unit or "none") then box:SetUnit(unit or "none") end
                box:Show()
            end)
        end
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
-- the shield stripes go after whatever is showing last: HoTs, else incoming
-- heals, else the health itself
local function PlaceAbsorb(btn)
    local c = btn.c
    local last = (c.hot:IsShown() and c.hot) or (btn.incActive and c.inc) or c.hp
    local edge = last:GetStatusBarTexture()
    for _, bar in ipairs({ c.absorbTint, c.absorbStripes }) do
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", edge, "TOPRIGHT")
        bar:SetPoint("BOTTOMLEFT", edge, "BOTTOMRIGHT")
    end
end

local function PlaceHot(btn, afterIncoming)
    local c = btn.c
    local edge = (afterIncoming and c.inc or c.hp):GetStatusBarTexture()
    c.hot:ClearAllPoints()
    c.hot:SetPoint("TOPLEFT", edge, "TOPRIGHT")
    c.hot:SetPoint("BOTTOMLEFT", edge, "BOTTOMRIGHT")
    PlaceAbsorb(btn)
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
    PlaceAbsorb(btn)
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
        c.name:SetPoint("CENTER", 0, (btn.roomy and has) and nameLift or 0)
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

-- Role from the group's role assignment, or the raid's main tank mark.
local ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }
local function UnitRole(u)
    local role
    if UnitGroupRolesAssigned then
        local ok, r = pcall(UnitGroupRolesAssigned, u)
        if ok and Readable(r) and ROLE_ATLAS[r] then role = r end
    end
    if not role and GetPartyAssignment then
        local ok, mt = pcall(GetPartyAssignment, "MAINTANK", u)
        if ok and mt == true then role = "TANK" end
    end
    return role
end

local function UpdateRole(btn)
    local u, icon = btn.unit, btn.c.role
    local role = (not btn.isPet and u and UnitExists(u)) and UnitRole(u) or nil
    if not role then icon:Hide() return end
    -- the game's small role icons; the older round role art as a fallback
    if not (icon.SetAtlas and pcall(icon.SetAtlas, icon, ROLE_ATLAS[role]) and icon:GetAtlas()) then
        icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
        if GetTexCoordsForRoleSmallCircle then
            icon:SetTexCoord(GetTexCoordsForRoleSmallCircle(role))
        end
    end
    icon:Show()
end

local function UpdateIdentity(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    c.name:SetText(UnitName(u) or "")
    local ok, col = pcall(function()
        local _, class = UnitClass(u)
        return class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    end)
    if btn.isPet and btn.owner and btn.owner.classColor then
        local oc = btn.owner.classColor
        btn.classColor = { oc[1] * 0.7, oc[2] * 0.7, oc[3] * 0.7 }
    elseif ok and col then
        btn.classColor = { col.r * 0.8, col.g * 0.8, col.b * 0.8 }
    else
        btn.classColor = { 0.3, 0.8, 0.3 }
    end
    local cc = btn.classColor
    UpdateRole(btn)
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

---------------------------------------------------------------------------
-- Tracked auras. In combat WoW Forever refuses addons the list of a unit's
-- buffs and debuffs (every index reader errors with "Auras cannot be
-- accessed when secret"). It still announces each aura as it comes and goes
-- (UNIT_AURA, by instance ID), so keep our own list of IDs per unit and ask
-- the game about each one directly.
---------------------------------------------------------------------------
local auraBook = {}       -- unit -> { [instanceID] = { harmful = bool|nil, dtype = "Magic"|nil } }
local DISPEL_FILTERS = { "HARMFUL|RAID_PLAYER_DISPELLABLE", "HARMFUL|RAID" }

local function SeedAuras(u)                -- the full list (out of combat)
    local list = {}
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        for i = 1, 40 do
            local a = C_UnitAuras.GetAuraDataByIndex(u, i, filter)
            if not a then break end
            local id = a.auraInstanceID
            if Readable(id) then
                local exp = a.expirationTime
                list[id] = { harmful = filter == "HARMFUL",
                    dtype = Readable(a.dispelName) and a.dispelName or nil,
                    expires = (Readable(exp) and type(exp) == "number" and exp > 0) and exp or nil }
            end
        end
    end
    auraBook[u] = list
end

local function SeedAuraIDs(u)              -- newer ID-only reader, if the game has it
    local f = C_UnitAuras.GetUnitAuraInstanceIDs
    if not f then return false end
    local list = {}
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        local ids = f(u, filter)
        if type(ids) ~= "table" then return false end
        for _, id in ipairs(ids) do
            if Readable(id) then
                local old = auraBook[u] and auraBook[u][id]
                list[id] = { harmful = filter == "HARMFUL", dtype = old and old.dtype }
            end
        end
    end
    auraBook[u] = list
    return true
end

local function IsHarmful(u, a, id)
    local h = a.isHarmful
    if Readable(h) then return h and true or false end
    local isOut = C_UnitAuras.IsAuraFilteredOutByInstanceID
    if isOut then
        local ok, out = pcall(isOut, u, id, "HARMFUL")
        if ok and Readable(out) then return not out end
    end
    return nil                              -- unknown: checked both ways later
end

local auraLog = {}         -- unit -> last few aura announcements, for /fhb debug
local function Show(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<hidden>" end
    return tostring(v)
end
local function LogAura(u, text)
    local l = auraLog[u] or {}
    auraLog[u] = l
    l[#l + 1] = string.format("%.1f %s", GetTime(), text)
    if #l > 6 then table.remove(l, 1) end
end

local function NoteAuras(u, info)
    local full = type(info) == "table" and info.isFullUpdate
    if type(info) == "table" then
        local okA, added = pcall(function() return info.addedAuras and #info.addedAuras or 0 end)
        local okR, removed = pcall(function()
            return info.removedAuraInstanceIDs and #info.removedAuraInstanceIDs or 0 end)
        local first = ""
        pcall(function()
            local a = info.addedAuras and info.addedAuras[1]
            if a then
                first = string.format("  first: id=%s harmful=%s type=%s name=%s", Show(a.auraInstanceID),
                    Show(a.isHarmful), Show(a.dispelName), Show(a.name))
            end
        end)
        LogAura(u, string.format("full=%s added=%s removed=%s%s", Show(full),
            okA and Show(added) or "error", okR and Show(removed) or "error", first))
    end
    if not Readable(full) then full = false end
    if type(info) ~= "table" or full or not auraBook[u] then
        if not pcall(SeedAuras, u) and not pcall(SeedAuraIDs, u) then
            auraBook[u] = auraBook[u] or {}
        end
        return
    end
    local list = auraBook[u]
    local ok, err = pcall(function()
        for _, a in ipairs(info.addedAuras or {}) do
            local id = a.auraInstanceID
            if Readable(id) then
                local okh, h = pcall(IsHarmful, u, a, id)
                local okt, t = pcall(function() return Readable(a.dispelName) and a.dispelName or nil end)
                local oke, exp = pcall(function()
                    local e = a.expirationTime
                    return (Readable(e) and type(e) == "number" and e > 0) and e or nil
                end)
                list[id] = { harmful = okh and h or nil, dtype = okt and t or nil, expires = oke and exp or nil }
                if okh and h == false then list[id].harmful = false end
            end
        end
    end)
    -- In combat the whole announcement is hidden: we only learn that
    -- something changed. A debuff seen before combat may just have been
    -- dispelled, so forget tracked debuffs rather than let one glow on.
    local hidden = not ok
    if not ok then LogAura(u, "added: " .. tostring(err)) end
    ok, err = pcall(function()
        for _, id in ipairs(info.removedAuraInstanceIDs or {}) do
            if Readable(id) then list[id] = nil end
        end
    end)
    if not ok then LogAura(u, "removed: " .. tostring(err)) hidden = true end
    if hidden then
        for id, e in pairs(list) do
            if e.harmful ~= false then list[id] = nil end
        end
    end
end

local function SortedIDs(list)
    local ids = {}
    for id in pairs(list) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- The game's "removed" notice doesn't always get through in combat (a dispel
-- would then glow until combat ends), so before trusting the list, ask about
-- each aura by ID and drop any the game says is gone or that has run out.
local function PruneAuras(u)
    local list = auraBook[u]
    if not list then return end
    local now = GetTime()
    local byID = C_UnitAuras.GetAuraDataByAuraInstanceID
    for id, e in pairs(list) do
        local gone = e.expires and now > e.expires + 0.5
        if not gone and byID then
            local ok, a = pcall(byID, u, id)
            if ok and a == nil then gone = true end
        end
        if gone then list[id] = nil end
    end
end

-- Route 3: go through the tracked debuffs and ask about each one.
local function FindDispelByID(u)
    pcall(PruneAuras, u)
    local list = auraBook[u]
    if not list then return end
    local ids = SortedIDs(list)
    for _, id in ipairs(ids) do                 -- types we already know
        local e = list[id]
        if e.harmful ~= false and e.dtype and canDispel[e.dtype] and DEBUFF_COLOR[e.dtype] then
            local col = DEBUFF_COLOR[e.dtype]
            return col.r, col.g, col.b, e.dtype
        end
    end
    local isOut = C_UnitAuras.IsAuraFilteredOutByInstanceID
    if not isOut then return end
    for _, id in ipairs(ids) do                 -- the rest: ask the game's filter
        local e = list[id]
        if e.harmful ~= false and not e.dtype then
            for _, filter in ipairs(DISPEL_FILTERS) do
                local ok, out = pcall(isOut, u, id, filter)
                if ok and Readable(out) then
                    if not out then
                        local okc, r, g, b = pcall(DispelColor, u, { auraInstanceID = id })
                        if okc and r then return r, g, b end
                        return NEUTRAL_DISPEL[1], NEUTRAL_DISPEL[2], NEUTRAL_DISPEL[3]
                    end
                    break
                end
            end
        end
    end
end

-- HoT icons from the tracked buffs, for when the list itself is refused.
local function HotIconsByID(btn)
    local u, c = btn.unit, btn.c
    local list = auraBook[u]
    local isOut = C_UnitAuras.IsAuraFilteredOutByInstanceID
    local n = 0
    if list and isOut then
        for _, id in ipairs(SortedIDs(list)) do
            if n >= MAX_HOTS then break end
            if list[id].harmful ~= true then
                local mine
                for _, filter in ipairs({ "HELPFUL|PLAYER|RAID_IN_COMBAT", "HELPFUL|PLAYER" }) do
                    local ok, out = pcall(isOut, u, id, filter)
                    if ok and Readable(out) then mine = not out; break end
                end
                if mine then
                    local oka, a = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, u, id)
                    if oka and a and pcall(c.hots[n + 1].SetTexture, c.hots[n + 1], a.icon) then
                        n = n + 1
                        c.hots[n]:Show()
                    end
                end
            end
        end
    end
    for k = n + 1, MAX_HOTS do c.hots[k]:Hide() end
end

local lastDispel = {}                  -- unit -> what UpdateDispel decided (for /fhb debug)
local function UpdateDispel(btn)
    local u = btn.unit
    local ok, r, g, b, kind, hidden = pcall(FindDispelByType, u)
    -- only ask the game's own filter when debuff details are hidden (combat):
    -- otherwise the exact type check above is authoritative
    if not (ok and r) and (not ok or hidden or InCombatLockdown()) then
        local ok2, r2, g2, b2 = pcall(FindDispelByFilter, u)
        if ok2 and r2 then
            r, g, b, kind = r2, g2, b2, nil
        else                                    -- list refused: use the tracked IDs
            local ok3, r3, g3, b3, k3 = pcall(FindDispelByID, u)
            if ok3 and r3 then r, g, b, kind = r3, g3, b3, k3 else r = nil end
        end
    end
    lastDispel[btn.unit] = r and (Readable(r) and string.format("%s (%.2f %.2f %.2f)", kind or "type hidden", r, g, b)
        or "found one, colour from game")
        or (ok and (hidden and "nothing (types hidden, game filter found none)" or "nothing")
        or "error reading debuffs")
    btn.c.dispel:Set(r, g, b, kind)
end

local function UpdateAurasModern(btn)
    if btn.c.hotBox then
        for k = 1, MAX_HOTS do btn.c.hots[k]:Hide() end      -- the game draws them
    elseif not pcall(UpdateHotIcons, btn) and not pcall(HotIconsByID, btn) then
        for k = 1, MAX_HOTS do btn.c.hots[k]:Hide() end
    end
    if btn.c.dispelBox then
        btn.c.dispel:Set(nil)                               -- the game draws it
        lastDispel[btn.unit] = "drawn by the game's aura container"
    else
        UpdateDispel(btn)
    end
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
    PlaceAbsorb(btn)
end

---------------------------------------------------------------------------
-- Buff reminders. Out of combat, each frame flashes the icon of any of your
-- buffs the player is missing or that runs out within 5 minutes. In combat
-- the game hides buffs from addons, so the icons go away then.
-- Each entry: the spells that count (single and group versions), who needs
-- it ("all", "mana" users, or "tank" role).
---------------------------------------------------------------------------
local RefreshMyBuffs, UpdateBuffNeeds   -- Buffwatch, below
do
    local BUFF_SOON = 300
    local CLASS_BUFFS = {
        PRIEST = {
            { "Power Word: Fortitude", "Prayer of Fortitude", who = "all" },
            { "Divine Spirit", "Prayer of Spirit", who = "mana" },
            { "Shadow Protection", "Prayer of Shadow Protection", who = "all" },
        },
        MAGE = { { "Arcane Intellect", "Arcane Brilliance", who = "mana" } },
        DRUID = {
            { "Mark of the Wild", "Gift of the Wild", who = "all" },
            { "Thorns", who = "tank" },
        },
    }
    local myBuffs = {}            -- the entries you know, each with its icon

    RefreshMyBuffs = function()
        wipe(myBuffs)
        local _, class = UnitClass("player")
        for _, entry in ipairs(CLASS_BUFFS[class] or {}) do
            local name, icon = SpellInfo(entry[1])
            if not name and entry[2] then name, icon = SpellInfo(entry[2]) end
            if name then
                local names = {}
                for _, n in ipairs(entry) do names[n] = true end
                myBuffs[#myBuffs + 1] = { names = names, icon = icon or 134400, who = entry.who }
            end
        end
    end

    local function NeedsBuff(u, entry)
        if entry.who == "mana" then
            local ok, pt = pcall(UnitPowerType, u)
            if not (ok and Readable(pt) and pt == 0) then return false end
        elseif entry.who == "tank" then
            if UnitRole(u) ~= "TANK" then return false end
        end
        return true
    end

    UpdateBuffNeeds = function(btn)
        local c, u = btn.c, btn.unit
        local shown = 0
        if DB.buffwatch and #myBuffs > 0 and u and UnitExists(u) and not InCombatLockdown()
            and UnitIsConnected(u) and not UnitIsDeadOrGhost(u) then
            local ok = pcall(function()
                -- what this player has, and how long it has left
                local left = {}
                local now = GetTime()
                for i = 1, 40 do
                    local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HELPFUL")
                    if not a then break end
                    local name, exp = a.name, a.expirationTime
                    if Readable(name) then
                        local rem = (Readable(exp) and exp > 0) and (exp - now) or math.huge
                        if not left[name] or rem > left[name] then left[name] = rem end
                    end
                end
                for _, entry in ipairs(myBuffs) do
                    if shown >= 3 then break end
                    if NeedsBuff(u, entry) then
                        local best = -1
                        for n in pairs(entry.names) do
                            if left[n] and left[n] > best then best = left[n] end
                        end
                        if best < BUFF_SOON then
                            shown = shown + 1
                            c.needIcons[shown]:SetTexture(entry.icon)
                            c.needIcons[shown]:Show()
                        end
                    end
                end
            end)
            if not ok then shown = 0 end
        end
        for i = shown + 1, 3 do c.needIcons[i]:Hide() end
        if shown > 0 then
            c.need:Show()
            if not c.needFlash:IsPlaying() then c.needFlash:Play() end
        else
            c.needFlash:Stop()
            c.need:Hide()
        end
    end
end

local function UpdateAuras(btn)
    local u = btn.unit
    if not u or not UnitExists(u) then return end
    if not InCombatLockdown() and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        pcall(SeedAuras, u)                     -- keep the tracked list exact while we can
        LearnIgnoredDebuffs(u)
    end
    UpdateHots(btn)
    local fn = (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) and UpdateAurasModern or UpdateAurasLegacy
    -- if the game hides aura details right now, show nothing rather than erroring
    if not pcall(fn, btn) then
        for k = 1, MAX_HOTS do btn.c.hots[k]:Hide() end
        btn.c.dispel:Set(nil)
    end
    UpdateBuffNeeds(btn)
    pcall(Tremor.Update, btn)
end

-- Threat: 0 none, 1 high threat, 2-3 has aggro. Used directly as the outline's
-- alpha (anything above 1 is fully visible), so it works when it's secret.
local function UpdateThreat(btn)
    local u = btn.unit
    if not u or not UnitExists(u) or not UnitThreatSituation then return end
    local ok, s = pcall(UnitThreatSituation, u)
    if not ok then return end
    if s == nil then
        btn.c.aggro:SetAlpha(0)
    elseif Readable(s) then
        -- 3 tanking, 2 has aggro but not tanking, 1 about to pull aggro
        btn.c.aggro:SetAlpha(s >= 2 and 1 or s == 1 and 0.35 or 0)
    else
        pcall(btn.c.aggro.SetAlpha, btn.c.aggro, s)          -- hidden: any threat shows fully
    end
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
    pcall(function()
        local max, absorb = UnitHealthMax(u), UnitGetTotalAbsorbs(u)
        for _, bar in ipairs({ btn.c.shield, btn.c.absorbTint, btn.c.absorbStripes }) do
            bar:SetMinMaxValues(0, max)
            bar:SetValue(absorb)
        end
    end)
end

local function UpdateAll(btn)
    SetAuraBoxUnit(btn, btn.unit)
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

-- Click to rez: a plain left click on a dead player casts your resurrection
-- spell; on anyone alive it does whatever plain left click is bound to. The
-- game decides at cast time with a [dead] macro condition, so it works in
-- combat too.
local REZ_SPELLS = { PRIEST = "Resurrection", PALADIN = "Redemption", SHAMAN = "Ancestral Spirit", DRUID = "Rebirth" }
local function RezSpell()
    local _, class = UnitClass("player")
    local spell = REZ_SPELLS[class]
    return spell and SpellInfo(spell) and spell or nil
end

local function ApplyBindings(btn)
    local binds = Binds()
    wipe(menuClicks)
    local wheelKeys = {}
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
            local sfx = ClickSuffix(click)
            btn:SetAttribute(mod .. "type" .. sfx, typ)
            btn:SetAttribute(mod .. "spell" .. sfx, spell)
            -- only bind the wheel where something is set, so it still zooms
            -- the camera everywhere else
            if WHEEL[click] and (typ or menuClicks[mod .. click]) then
                wheelKeys[#wheelKeys + 1] = { mod:upper() .. WHEEL[click].key, WHEEL[click].button }
            end
        end
    end
    for i = 1, 8 do
        local w = wheelKeys[i]
        btn:SetAttribute("fhbwheelkey" .. i, w and w[1] or nil)
        btn:SetAttribute("fhbwheelbtn" .. i, w and w[2] or nil)
    end
    -- plain left click: a macro filled in at click time (see InitButton)
    local rez = RezSpell()
    local leftType, leftSpell = btn:GetAttribute("type1"), btn:GetAttribute("spell1")
    if rez and (leftType == "spell" or leftType == "target" or leftType == nil) then
        btn:SetAttribute("fhbrez", rez)
        btn:SetAttribute("fhbleft", leftType == "spell" and leftSpell or "")
        btn:SetAttribute("type1", "macro")
        btn:SetAttribute("spell1", nil)
    else
        btn:SetAttribute("fhbrez", nil)
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

local CLICK_NUM = { LeftButton = 1, RightButton = 2, MiddleButton = 3, Button4 = 4, Button5 = 5,
    wheelup = 6, wheeldown = 7 }
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
    if btn.fhbHandOff then return end            -- the click handed something over instead
    local n = CLICK_NUM[button]
    if not n then return end
    local mod = IsAltKeyDown() and "alt-" or IsControlKeyDown() and "ctrl-" or IsShiftKeyDown() and "shift-" or ""
    if menuClicks[mod .. n] then OpenMenu(btn.unit) end
end

-- Pets: each player's frame carries a narrower frame for their pet, right
-- beside it. When the header moves a frame to another player (in combat too),
-- a secure snippet points the pet frame at that player's pet, and the game
-- shows it only while that pet exists.
local function PetsOn() return not DB or DB.pets ~= false end
local function PetWidth(w) return math.max(30, math.floor(w * 0.6 + 0.5)) end
local function ColumnSpacing(w)
    return PetsOn() and (GAP + PetWidth(w) + GAP) or GAP
end

local SetupUnitButton

local function CreatePetButton(owner)
    local pet = CreateFrame("Button", owner:GetName() .. "Pet", owner, "SecureUnitButtonTemplate")
    pet:SetPoint("TOPLEFT", owner, "TOPRIGHT", GAP, 0)
    pet:SetSize(PetWidth(DB.w or W), DB.h or H)
    pet.isPet = true
    pet.owner = owner
    SetupUnitButton(pet)
    pet:Hide()
    SecureHandlerSetFrameRef(owner, "fhbpet", pet)        -- (unit buttons have no SetFrameRef of their own)
    owner.pet = pet
    SecureHandlerWrapScript(owner, "OnAttributeChanged", secureHandler, [[
        if name ~= "unit" then return end
        local pet = self:GetFrameRef("fhbpet")
        if not pet then return end
        local pu
        if value == "player" then
            pu = "pet"
        elseif value then
            local kind, n = strmatch(value, "^(%a+)(%d+)$")
            if kind == "party" or kind == "raid" then pu = kind .. "pet" .. n end
        end
        pet:SetAttribute("unit", pu)
    ]])
    if PetsOn() then RegisterUnitWatch(pet) end
end

-- show or hide every pet frame (out of combat)
local function ApplyPets()
    return OutOfCombat(function()
        for _, b in ipairs(buttons) do
            if b.pet then
                if PetsOn() then RegisterUnitWatch(b.pet) else UnregisterUnitWatch(b.pet); b.pet:Hide() end
            end
        end
        if header then
            header:SetAttribute("columnSpacing", ColumnSpacing(DB.w or W))
        end
    end)
end

-- Called by the header (through CallMethod) for each button it creates.
local function InitButton(self, name)
    local btn = _G[name]
    if not btn or btn.fhb then return end
    SetupUnitButton(btn)
    CreatePetButton(btn)
end

SetupUnitButton = function(btn)
    btn.fhb = true
    buttons[#buttons + 1] = btn
    Build(btn)
    ApplyPowerShown(btn)
    btn:RegisterForClicks("AnyUp")
    -- secure pre-click snippet: point the target macro at this frame's unit
    SecureHandlerWrapScript(btn, "OnClick", secureHandler, [[
        local u = self:GetAttribute("unit")
        if u then self:SetAttribute("*macrotext*", "/target " .. u) end
        local rez = self:GetAttribute("fhbrez")
        if u and rez and button == "LeftButton" then
            local left = self:GetAttribute("fhbleft")
            local text = "/cast [@" .. u .. ",dead] " .. rez
            if left and left ~= "" then
                text = text .. "; [@" .. u .. "] " .. left
            else
                text = text .. "\n/stopmacro [@" .. u .. ",dead]\n/target " .. u
            end
            self:SetAttribute("macrotext1", text)
        end
    ]])
    -- mouse wheel: bound to this frame only while the pointer is over it
    SecureHandlerWrapScript(btn, "OnEnter", secureHandler, [[
        self:ClearBindings()
        for i = 1, 8 do
            local key = self:GetAttribute("fhbwheelkey" .. i)
            if key then self:SetBindingClick(true, key, self, self:GetAttribute("fhbwheelbtn" .. i)) end
        end
    ]])
    SecureHandlerWrapScript(btn, "OnLeave", secureHandler, [[ self:ClearBindings() ]])
    SecureHandlerWrapScript(btn, "OnHide", secureHandler, [[ self:ClearBindings() ]])
    btn:HookScript("OnClick", OnMenuClick)

    -- Something on the cursor (an item to trade or give, or a spell or item
    -- waiting for a target): this one click hands it to the player instead
    -- of casting the bound spell. Out of combat only: in combat the game
    -- doesn't let an addon change what a click does.
    btn:HookScript("PreClick", function(self, button)
        if InCombatLockdown() or not self.unit then return end
        if not (CursorHasItem() or (SpellIsTargeting and SpellIsTargeting())) then return end
        local key = SecureButton_GetModifierPrefix(self) .. "type" .. SecureButton_GetButtonSuffix(button)
        self.fhbHandOff = { key = key, value = self:GetAttribute(key) }
        self:SetAttribute(key, "target")      -- the game's target action drops the item or the spell
    end)
    btn:HookScript("PostClick", function(self)
        local h = self.fhbHandOff
        if not h then return end
        self.fhbHandOff = nil
        if not InCombatLockdown() then self:SetAttribute(h.key, h.value) end
    end)
    -- dragging an item and letting go over a frame does the same
    btn:SetScript("OnReceiveDrag", function(self)
        if self.unit and CursorHasItem() and not InCombatLockdown() then pcall(DropItemOnUnit, self.unit) end
    end)
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
            SetAuraBoxUnit(b, value)
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
    DB.scale = nil                            -- (scale was removed; size is set by dragging the corner)

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
    header:SetAttribute("columnSpacing", ColumnSpacing(DB.w or W))
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

-- Size of the whole grid on screen, never smaller than one frame.
local function GridSize()
    local sc = header:GetScale()
    local extra = PetsOn() and (GAP + PetWidth(DB.w or W)) or 0
    return (math.max(header:GetWidth() or 0, W) + extra) * sc, math.max(header:GetHeight() or 0, H) * sc
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
local function FontFor(w, h)
    local f = math.min(w / W, h / H)
    return math.max(FONT_MIN, math.min(FONT_MAX, math.floor(FONT_BASE * f + 0.5)))
end

local function ApplyFonts(b)
    local file, _, flags = GameFontHighlightSmall:GetFont()
    -- pets are narrower: their text follows their own width
    local size = b.isPet and math.max(FONT_MIN, math.min(fontSize, FontFor(b:GetWidth(), b:GetHeight()))) or fontSize
    b.c.name:SetFont(file, size, flags)
    b.c.status:SetFont(file, math.max(FONT_MIN - 1, size - 1), flags)
    b.c.status:ClearAllPoints()
    b.c.status:SetPoint("CENTER", 0, -math.floor(size * 0.8 + 0.5))
end

-- Corner icons (HoTs, debuffs, role, Buffwatch) grow with the frames too:
-- 11 px at the default size and never smaller, up to 22 px.
local ICON_BASE, ICON_MIN, ICON_MAX = 11, 11, 22
local iconSize = ICON_BASE
local function IconFor(w, h)
    local f = math.min(w / W, h / H)
    return math.max(ICON_MIN, math.min(ICON_MAX, math.floor(ICON_BASE * f + 0.5)))
end

local function ApplyIcons(b)
    local c = b.c
    local s = b.isPet and math.min(iconSize, IconFor(b:GetWidth(), b:GetHeight())) or iconSize
    c.role:SetSize(s, s)
    local ns = s + 1                                -- Buffwatch icons, a touch bigger
    c.need:ClearAllPoints()
    c.need:SetPoint("BOTTOMRIGHT", -(s + 4), 2 + POWER_H)
    c.need:SetSize((ns + 1) * 3, ns)
    for i, t in ipairs(c.needIcons) do
        t:SetSize(ns, ns)
        t:ClearAllPoints()
        t:SetPoint("BOTTOMRIGHT", -(i - 1) * (ns + 1), 0)
    end
    for i, t in ipairs(c.hots) do
        t:SetSize(s, s)
        t:ClearAllPoints()
        t:SetPoint("TOPRIGHT", -2 - (i - 1) * (s + 1), -2)
    end
    -- the game-drawn rows are scaled as a whole (offsets kept in screen pixels)
    local sc = s / ICON_BASE
    for _, spec in ipairs({ { c.hotBox, "TOPRIGHT", -2, -2 }, { c.debuffBox, "BOTTOMLEFT", 2, 2 + POWER_H } }) do
        local box = spec[1]
        if box then
            box:SetScale(sc)
            box:ClearAllPoints()
            box:SetPoint(spec[2], c, spec[2], spec[3] / sc, spec[4] / sc)
        end
    end
end

ApplyIconsRef = ApplyIcons

local function ApplySize(w, h)
    w = math.max(MIN_W, math.min(MAX_W, math.floor(w + 0.5)))
    h = math.max(MIN_H, math.min(MAX_H, math.floor(h + 0.5)))
    DB.w, DB.h = w, h
    fontSize = FontFor(w, h)
    iconSize = IconFor(w, h)
    nameLift = math.floor(fontSize * 0.6 + 0.5)
    for _, b in ipairs(buttons) do
        local bw = b.isPet and PetWidth(w) or w
        b:SetSize(bw, h)
        b.c.name:SetWidth(bw - 6)
        b.c.inc:SetWidth(bw)
        b.c.hot:SetWidth(bw)
        b.c.absorbTint:SetWidth(bw)
        b.c.absorbStripes:SetWidth(bw)
        b.c.powerCost:SetWidth(bw)
        ApplyFonts(b)
        ApplyIcons(b)
        -- short frames: name only, centred; tall enough: name above missing health
        b.roomy = h >= math.max(34, fontSize * 2 + 14)
        b.c.status:SetShown(b.roomy)
        b.c.name:ClearAllPoints()
        b.c.name:SetPoint("CENTER", 0, (b.roomy and b.hasStatus) and nameLift or 0)
    end
    anchor:SetSize(w, h)
    header:SetAttribute("columnSpacing", ColumnSpacing(w))
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
    for _, b in ipairs(buttons) do if b:IsShown() and not b.isPet then n = n + 1 end end
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
        local text = locked and "Can't lock the frames in combat. They'll lock when combat ends."
            or "Can't unlock or move the frames in combat. They'll unlock when combat ends."
        if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 1, 0.2, 0.2) end
        Msg(text)
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
        if InCombatLockdown() then
            GameTooltip:AddLine("You can't unlock, move or resize the frames in combat.", 1, 0.3, 0.3, true)
        else
            GameTooltip:AddLine("Can't be unlocked, moved or resized in combat.", 0.6, 0.6, 0.6, true)
        end
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
-- Hiding or re-parenting them from addon code runs their hide and layout code
-- as this addon's work. That marks the game's shared screen-layout data, and
-- the action bar refresh (page, stance and form changes) later trips over it,
-- which can leave the action bars hidden until a /reload. So the addon only
-- stops them listening for events (no game code runs) and hands hiding to a
-- secure state driver, which hides them as the game's own code.
-- The raid tools tab on the left edge of the screen is left alone. Bringing
-- them back needs a /reload, since the game rebuilds them on load.
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
                pcall(RegisterStateDriver, f, "visibility", "hide")
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
    -- Escape closes it. (Not through the game's Escape list: opening the
    -- spellbook closes every window on that list, and this one has to stay
    -- open while you drag spells across.) Other keys pass through as usual.
    if not InCombatLockdown() then
        f:EnableKeyboard(true)
        f:SetPropagateKeyboardInput(true)
        f:SetScript("OnKeyDown", function(self, key)
            if key ~= "ESCAPE" then return end
            if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
            self:Hide()
            if not InCombatLockdown() then
                C_Timer.After(0, function() if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end end)
            end
        end)
    end
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
        .. "right-click an empty one to set Target or Menu. Drag a square onto another to move it. "
        .. "After dropping from the spellbook, right-click "
        .. "anywhere or press Escape to let go of the spell.")

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
                -- The cursor is left alone: clearing it from addon code makes the
                -- action and totem bars update as this addon's work and trip over
                -- hidden cooldowns. Right-click or Escape lets go of the spell.
                if name then Assign(self, name) end
                return true
            end

            sq:SetScript("OnReceiveDrag", TakeCursorSpell)
            -- drag a filled square onto another to move it there (the two swap).
            -- Done entirely inside the window; the game cursor is never touched.
            sq:RegisterForDrag("LeftButton")
            sq:SetScript("OnDragStart", function(self)
                if GetCursorInfo() or not Binds()[self.key] then return end
                f:StartMove(self)
            end)
            sq:SetScript("OnDragStop", function(self) f:EndMove() end)
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
                if GetCursorInfo() == "spell" or f.moving then self.hl:Show() end
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
                    GameTooltip:AddLine("Right-click to change. Drag to another square to move.", 0.5, 0.5, 0.5, true)
                else
                    local name = SpellInfo(v)
                    GameTooltip:AddLine(v, 1, 0.82, 0)
                    if not name then GameTooltip:AddLine("Not in your spellbook yet.", 1, 0.3, 0.3) end
                    GameTooltip:AddLine("Right-click to clear. Drag to another square to move.", 0.5, 0.5, 0.5, true)
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

    -- moving a binding between squares: a copy of the icon follows the mouse
    local ghost = CreateFrame("Frame", nil, f)
    ghost:SetSize(SLOT, SLOT)
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetAlpha(0.85)
    ghost:Hide()
    ghost.icon = ghost:CreateTexture(nil, "ARTWORK")
    ghost.icon:SetAllPoints()
    ghost.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ghost.label = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ghost.label:SetPoint("CENTER")
    local ghostBg = ghost:CreateTexture(nil, "BACKGROUND")
    ghostBg:SetAllPoints()
    ghostBg:SetColorTexture(0.06, 0.07, 0.1, 0.95)

    function f:StartMove(src)
        self.moving = src
        ghost.icon:SetShown(src.icon:IsShown())
        ghost.icon:SetTexture(src.icon:GetTexture())
        ghost.label:SetText(src.label:GetText() or "")
        src:SetAlpha(0.4)
        ghost:Show()
        GameTooltip_Hide()
    end

    function f:EndMove()
        local src = self.moving
        if not src then return end
        self.moving = nil
        ghost:Hide()
        src:SetAlpha(1)
        for _, sq in ipairs(self.boxes) do
            if sq ~= src and sq:IsMouseOver() then
                local b = Binds()
                b[src.key], b[sq.key] = b[sq.key], b[src.key]     -- swap
                src:Refresh()
                sq:Refresh()
                if not ApplyBindingsAll() then Msg("bindings will update after combat.") end
                break
            end
        end
    end
    f:HookScript("OnHide", function(self) self:EndMove() end)

    -- while a spell is on the cursor (or a square is being moved), outline
    -- every square and light up the one under the mouse
    f.dragging = false
    f:SetScript("OnUpdate", function(self)
        if self.moving then
            local x, y = GetCursorPosition()
            local sc = ghost:GetEffectiveScale()
            ghost:ClearAllPoints()
            ghost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / sc, y / sc)
        end
        local dragging = GetCursorInfo() == "spell" or self.moving ~= nil
        if dragging ~= self.dragging then
            self.dragging = dragging
            for _, sq in ipairs(self.boxes) do sq.drop:SetAlpha(dragging and 0.8 or 0) end
        end
        if dragging then
            for _, sq in ipairs(self.boxes) do sq.hl:SetShown(sq ~= self.moving and sq:IsMouseOver()) end
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

    local remind = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    remind:SetSize(22, 22)
    remind:SetPoint("LEFT", hideLabel, "RIGHT", 24, 0)
    local remindLabel = remind.Text or remind.text or remind:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    remindLabel:ClearAllPoints()
    remindLabel:SetPoint("LEFT", remind, "RIGHT", 2, 0)
    remindLabel:SetFontObject("GameFontHighlightSmall")
    remindLabel:SetText("Buffwatch")
    remind:SetScript("OnClick", function(self)
        DB.buffwatch = self:GetChecked() and true or false
        for _, b in ipairs(buttons) do if b.c then UpdateBuffNeeds(b) end end
    end)
    f.showReminders = remind
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

    local pets = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    pets:SetSize(22, 22)
    pets:SetPoint("LEFT", pwrLabel, "RIGHT", 24, 0)
    local petsLabel = pets.Text or pets.text or pets:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    petsLabel:ClearAllPoints()
    petsLabel:SetPoint("LEFT", pets, "RIGHT", 2, 0)
    petsLabel:SetFontObject("GameFontHighlightSmall")
    petsLabel:SetText("Show pets")
    pets:SetScript("OnClick", function(self)
        DB.pets = self:GetChecked() and true or false
        if ApplyPets() then C_Timer.After(0.1, UpdateMover) else Msg("pets will update after combat.") end
    end)
    f.showPets = pets



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


    f:HookScript("OnShow", function(self)
        for _, e in ipairs(self.boxes) do e:Refresh() end
        self.hideBlizz:SetChecked(DB.hideBlizzard)
        self.showPower:SetChecked(DB.showPower)
        self.showPets:SetChecked(DB.pets ~= false)
        self.showReminders:SetChecked(DB.buffwatch and true or false)
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
    UNIT_THREAT_LIST_UPDATE = UpdateThreat,
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
    if event == "UNIT_AURA" and byUnit[arg1] and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        pcall(NoteAuras, arg1, arg2)
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
        if DB.pets == nil then DB.pets = true end
        -- Buffwatch is off until you turn it on (the old setting, on by default, is dropped)
        DB.buffReminders = nil
        if DB.buffwatch == nil then DB.buffwatch = false end
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
        pcall(ev.RegisterEvent, ev, "PLAYER_ROLES_ASSIGNED")
        ev:RegisterEvent("PLAYER_ENTERING_WORLD")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        ev:RegisterEvent("PLAYER_REGEN_DISABLED")
        pcall(ev.RegisterEvent, ev, "SPELLS_CHANGED")
        RefreshCures()
        RefreshMyBuffs()
    elseif event == "PLAYER_ROLES_ASSIGNED" then
        for _, b in ipairs(buttons) do if b.unit and b:IsShown() then UpdateRole(b) end end
    elseif event == "PLAYER_TARGET_CHANGED" then
        for _, b in ipairs(buttons) do if b.unit and b:IsShown() then UpdateSelected(b) end end
    elseif event == "SPELLS_CHANGED" then
        RefreshCures()
        RefreshMyBuffs()
        for _, b in ipairs(buttons) do if b.unit and b:IsShown() then UpdateAuras(b) end end
    elseif event == "PLAYER_REGEN_DISABLED" then
        for _, b in ipairs(buttons) do if b.c then UpdateBuffNeeds(b) end end
        if mover and mover:IsShown() then SetHint("|cffff5555Can't move or resize in combat|r") end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if mover and mover:IsShown() then SetHint(DEFAULT_HINT) end
        local list = pending
        pending = {}
        for _, f in ipairs(list) do f() end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        Remap()
        wipe(auraBook)                          -- unit tokens may now be other players
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            for u in pairs(byUnit) do pcall(NoteAuras, u, nil) end
        end
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
            UpdateThreat(b)
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
        local secretNow = C_Secrets and C_Secrets.ShouldAurasBeSecret
        Msg("  in combat=%s  auras hidden=%s", tostring(InCombatLockdown()),
            secretNow and tostring(select(2, pcall(secretNow))) or "?")
        local okList, listErr = pcall(function()
            for i = 1, 40 do
                local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HARMFUL")
                if not a then
                    if i == 1 then Msg("  no debuffs found") end
                    break
                end
                Msg("  %d. %s  type=%s  id=%s  lasts=%s  left=%s", i, show(a.name), show(a.dispelName), show(a.spellId),
                    show(a.duration), (Readable(a.expirationTime) and a.expirationTime > 0)
                        and string.format("%.0f", a.expirationTime - GetTime()) or show(a.expirationTime))
            end
        end)
        if not okList then Msg("  full debuff list: refused") end
        local ids = {}
        for id in pairs(DB.ignoredDebuffIDs or {}) do ids[#ids + 1] = tostring(id) end
        Msg("  tremor (fear/sleep/charm): %s  |  game frames: %s", tostring((Tremor.Read(u))),
            DB.tremorBoxOK == true and "proven" or DB.tremorBoxOK == false and "ignore the list"
            or ("untested: " .. Tremor.probe))
        for _, b in ipairs(buttons) do
            local fu = b.unit
            if fu and b:IsShown() and b.c and ((fu == u) or select(2, pcall(UnitIsUnit, fu, u)) == true) then
                local built, lit = Tremor.Lit(b.c)
                Msg("  game's fear/sleep/charm frames on %s: %d built, lit: %s", fu, built,
                    #lit > 0 and table.concat(lit, ", ") or "none")
            end
        end
        Msg("  hidden debuff IDs learned: %s  |  debuff icons: %s",
            #ids > 0 and table.concat(ids, ", ") or "none", debuffRowMode)
        -- the tracked-ID route, per frame showing this player
        local isOut = C_UnitAuras.IsAuraFilteredOutByInstanceID
        Msg("  ID readers: by ID=%s  filter check=%s  ID list=%s",
            tostring(C_UnitAuras.GetAuraDataByAuraInstanceID ~= nil), tostring(isOut ~= nil),
            tostring(C_UnitAuras.GetUnitAuraInstanceIDs ~= nil))
        if C_UnitAuras.GetUnitAuraInstanceIDs then
            local okI, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, u, "HARMFUL")
            Msg("  ID list for debuffs: %s", not okI and ("error: " .. tostring(ids))
                or (type(ids) == "table" and (#ids .. " found") or show(ids)))
        end
        for _, b in ipairs(buttons) do
            local fu = b.unit
            if fu and b:IsShown() and ((fu == u) or select(2, pcall(UnitIsUnit, fu, u)) == true) then
                local list = auraBook[fu] or {}
                local n = 0
                for id, e in pairs(list) do
                    n = n + 1
                    if e.harmful ~= false and n <= 12 then
                        local answers = {}
                        for _, flt in ipairs(DISPEL_FILTERS) do
                            local okf, out = isOut and pcall(isOut, fu, id, flt)
                            answers[#answers + 1] = (flt:gsub("HARMFUL|", "")) .. "="
                                .. (not isOut and "-" or not okf and "error" or show(out))
                        end
                        local oka, a = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, fu, id)
                        Msg("  tracked %s on %s: harmful=%s type=%s  %s  by ID=%s", tostring(id), fu,
                            tostring(e.harmful), tostring(e.dtype), table.concat(answers, " "),
                            not oka and "error" or (a and ("ok, name " .. show(a.name)) or "nil"))
                    end
                end
                Msg("  %s: %d tracked auras", fu, n)
                for _, line in ipairs(auraLog[fu] or {}) do Msg("    announced %s", line) end
            end
        end
        local okAll, err = pcall(function()
            for _, flt in ipairs({ "HARMFUL|RAID_PLAYER_DISPELLABLE", "HARMFUL|RAID" }) do
                local okf, r = pcall(C_UnitAuras.GetAuraDataByIndex, u, 1, flt)
                Msg("  game filter %s: %s", (flt:gsub("|", "||")), not okf and "not supported"
                    or (r and ("found " .. show(r.name)) or "nothing"))
            end
            -- what each frame showing this player computed for its HoT segment
            for _, b in ipairs(buttons) do
                if b.unit and b:IsShown() then
                    local same = (b.unit == u) or select(2, pcall(UnitIsUnit, b.unit, u)) == true
                    if same then
                        Msg("  dispel glow on %s: %s  (effect shown=%s)", b.unit,
                            tostring(lastDispel[b.unit]), tostring(b.c.dispel and b.c.dispel.shown))
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
    elseif cmd == "buffs" then
        DB.buffwatch = not DB.buffwatch
        if config and config.showReminders then config.showReminders:SetChecked(DB.buffwatch) end
        for _, b in ipairs(buttons) do if b.c then UpdateBuffNeeds(b) end end
        Msg("Buffwatch %s.", DB.buffwatch and "on" or "off")
    elseif cmd == "pets" then
        DB.pets = not DB.pets
        if config and config.showPets then config.showPets:SetChecked(DB.pets) end
        Msg("pets %s.", DB.pets and "shown beside their owners" or "hidden")
        if ApplyPets() then C_Timer.After(0.1, UpdateMover) else Msg("will update after combat.") end
    elseif cmd == "blizzard" then
        SetHideBlizzard(not DB.hideBlizzard)
    elseif cmd == "reset" then
        DB.pos, DB.w, DB.h = nil, nil, nil
        if not OutOfCombat(function() PlaceAnchor(); ApplySize(W, H) end) then
            Msg("will reset after combat.")
        end
    else
        Msg("/fhb  (settings)  |  unlock  |  lock  |  pets  |  buffs  |  blizzard  |  reset  |  debug")
    end
end
