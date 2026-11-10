-- Forever Heal Bars: a minimalist grid of party/raid frames for healers.
-- Click-casting, your HoTs, dispellable debuffs, incoming heals, range and aggro.

local ADDON = ...
local PREFIX = "|cff33ff99Forever Heal Bars|r: "

local W, H, GAP = 72, 46, 3          -- button size and spacing
local MAX_BUTTONS = 40
local OOR_ALPHA = 0.35                -- alpha for out-of-range players
local HOT_SIZE, MAX_HOTS = 11, 3
local BAR = "Interface\\Buttons\\WHITE8X8"

local DB, charKey
local header, anchor, mover
local buttons = {}                    -- every unit button the header made
local byUnit = {}                     -- unit token -> { button, ... }
local pending = {}                    -- functions waiting for combat to end

local MODS = { "", "shift-", "ctrl-", "alt-" }
local MOD_LABEL = { [""] = "Click", ["shift-"] = "Shift", ["ctrl-"] = "Ctrl", ["alt-"] = "Alt" }
local CLICKS = { 1, 2, 3 }
local CLICK_LABEL = { "Left", "Right", "Middle" }

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

local function Binds()
    DB.binds[charKey] = DB.binds[charKey] or {}
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
    b:Set(nil)
    return b
end

local function Build(btn)
    -- everything visual lives on a plain child frame, so fading it for range
    -- never touches the secure button
    local c = CreateFrame("Frame", nil, btn)
    c:SetAllPoints()
    btn.c = c

    local bg = c:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.13, 0.17, 0.9)

    local hp = CreateFrame("StatusBar", nil, c)
    hp:SetAllPoints()
    hp:SetStatusBarTexture(BAR)
    hp:SetMinMaxValues(0, 1)
    c.hp = hp

    local inc = hp:CreateTexture(nil, "ARTWORK", nil, 1)
    inc:SetColorTexture(0.47, 0.9, 0.55, 0.85)
    inc:SetPoint("TOPLEFT", hp:GetStatusBarTexture(), "TOPRIGHT")
    inc:SetPoint("BOTTOMLEFT", hp:GetStatusBarTexture(), "BOTTOMRIGHT")
    inc:Hide()
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

    c.dispel = Border(text, 0, 3)     -- inside edge: dispellable debuff, by type
    c.aggro = Border(text, 2, 2)      -- outside edge: has aggro
end

local function UpdateHealth(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    local cur, max = UnitHealth(u), UnitHealthMax(u)
    if max <= 0 then max = 1 end
    c.hp:SetMinMaxValues(0, max)
    c.hp:SetValue(cur)

    local inc = UnitGetIncomingHeals and UnitGetIncomingHeals(u) or 0
    local missing = max - cur
    if inc and inc > 0 and missing > 0 then
        c.inc:SetWidth(math.max(1, math.min(inc, missing) / max * btn:GetWidth()))
        c.inc:Show()
    else
        c.inc:Hide()
    end

    if not UnitIsConnected(u) then
        c.status:SetText("Offline")
    elseif UnitIsGhost(u) then
        c.status:SetText("Ghost")
    elseif UnitIsDead(u) then
        c.status:SetText("Dead")
    elseif missing > 0 then
        c.status:SetText("-" .. (BreakUpLargeNumbers and BreakUpLargeNumbers(missing) or missing))
    else
        c.status:SetText("")
    end
end

local function UpdateIdentity(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end
    c.name:SetText(UnitName(u) or "")
    local _, class = UnitClass(u)
    local col = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if col then
        c.hp:SetStatusBarColor(col.r * 0.8, col.g * 0.8, col.b * 0.8)
    else
        c.hp:SetStatusBarColor(0.3, 0.8, 0.3)
    end
end

local function UpdateAuras(btn)
    local u, c = btn.unit, btn.c
    if not u or not UnitExists(u) then return end

    -- your HoTs: helpful auras you cast that have a duration
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

    -- first debuff you can dispel ("RAID" filter = dispellable by you)
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

local function UpdateThreat(btn)
    local u = btn.unit
    if not u or not UnitExists(u) then return end
    local s = UnitThreatSituation and UnitThreatSituation(u)
    if s and s >= 2 then btn.c.aggro:Set(0.9, 0.15, 0.15) else btn.c.aggro:Set(nil) end
end

local function UpdateRange(btn)
    local u = btn.unit
    if not u or not UnitExists(u) then return end
    local alpha = 1
    if not UnitIsConnected(u) then
        alpha = OOR_ALPHA
    elseif not UnitIsUnit(u, "player") then
        local inRange, checked = UnitInRange(u)
        if checked and not inRange then alpha = OOR_ALPHA end
    end
    btn.c:SetAlpha(alpha)
end

local function UpdateAll(btn)
    UpdateIdentity(btn)
    UpdateHealth(btn)
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
local function ApplyBindings(btn)
    local binds = Binds()
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
-- Called by the header (through CallMethod) for each button it creates.
local function InitButton(self, name)
    local btn = _G[name]
    if not btn or btn.fhb then return end
    btn.fhb = true
    buttons[#buttons + 1] = btn
    Build(btn)
    btn:RegisterForClicks("AnyUp")
    ApplyBindings(btn)
    btn:HookScript("OnAttributeChanged", function(b, key, value)
        if key == "unit" then
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
local function SetLocked(locked)
    if InCombatLockdown() then
        pending[#pending + 1] = function() SetLocked(locked) end
        Msg("will %s after combat.", locked and "lock" or "unlock")
        return
    end
    DB.locked = locked
    if not mover then
        mover = CreateFrame("Frame", nil, UIParent)
        mover:SetFrameStrata("DIALOG")
        mover:SetPoint("TOPLEFT", anchor, "TOPLEFT", -4, 4)
        mover:SetSize(W * 3, H + 8)
        local t = mover:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(0.2, 1, 0.6, 0.25)
        local fs = mover:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("CENTER")
        fs:SetText("Drag to move\n|cffaaaaaa/fhb lock when done|r")
        mover:EnableMouse(true)
        mover:RegisterForDrag("LeftButton")
        mover:SetScript("OnDragStart", function()
            if not InCombatLockdown() then anchor:StartMoving() end
        end)
        mover:SetScript("OnDragStop", function()
            anchor:StopMovingOrSizing()
            SavePosition()
        end)
    end
    mover:SetShown(not locked)
end

---------------------------------------------------------------------------
-- Click-casting setup window
---------------------------------------------------------------------------
local config

local function CreateConfig()
    local f = CreateFrame("Frame", "ForeverHealBarsConfig", UIParent, "BasicFrameTemplateWithInset")
    local colW, rowH = 150, 30
    f:SetSize(90 + colW * #CLICKS + 20, 110 + rowH * #MODS)
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
    title:SetText("Forever Heal Bars: click-casting")

    local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 16, -32)
    help:SetPoint("TOPRIGHT", -16, -32)
    help:SetJustifyH("LEFT")
    help:SetText("Type a spell name as it appears in your spellbook, then press Enter. "
        .. "|cffaaaaaatarget|r and |cffaaaaaamenu|r also work. Blank = default (left: target, right: menu).")

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

    local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 16, 14)
    note:SetText("Red text: spell not found in your spellbook. Bindings are saved per character.")

    f:SetScript("OnShow", function(self) for _, e in ipairs(self.boxes) do e:Refresh() end end)
    f:Hide()
    return f
end

local function ToggleConfig()
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
    UNIT_HEALTH = UpdateHealth,
    UNIT_HEALTH_FREQUENT = UpdateHealth,
    UNIT_MAXHEALTH = UpdateHealth,
    UNIT_HEAL_PREDICTION = UpdateHealth,
    UNIT_CONNECTION = UpdateAll,
    UNIT_FLAGS = UpdateHealth,
    UNIT_AURA = UpdateAuras,
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
        if DB.locked == nil then DB.locked = true end
    elseif event == "PLAYER_LOGIN" then
        charKey = UnitName("player") .. "-" .. GetRealmName()
        OutOfCombat(function()
            CreateHeader()
            if not DB.locked then SetLocked(false) end
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
        if not OutOfCombat(function() header:SetScale(s) end) then Msg("will rescale after combat.") end
    elseif cmd == "reset" then
        DB.pos, DB.scale = nil, 1
        if not OutOfCombat(function() PlaceAnchor(); header:SetScale(1) end) then
            Msg("will reset after combat.")
        end
    else
        Msg("/fhb  (click-casting)  |  /fhb unlock  |  /fhb lock  |  /fhb scale 0.5-2  |  /fhb reset")
    end
end
