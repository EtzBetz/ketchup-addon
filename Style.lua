-- Ketchup: visual style.
--
-- With EllesmereUI installed, Ketchup's frames are painted through its
-- official skinning API (SKINNING_API.md), so they match the user's theme and
-- follow live accent color changes. Without it (or with third-party skinning
-- turned off for Ketchup in EllesmereUI's options), a built-in flat dark
-- style with the same shapes is used instead.
--
-- UI code only ever calls Style.Apply("<Primitive>", frame, ...). The choice
-- between the two backends is made once, at login, before anything is
-- painted, so a frame never gets both looks.
local _, ns = ...
local K = ns.K

local Style = {}
ns.Style = Style
K.Style = Style

local FALLBACK_ACCENT = { 0.90, 0.29, 0.22 } -- ketchup red

local eui            -- EllesmereUI skin facade, when it skins us
local decided = false
local pending = {}
local looksCallbacks = {}

------------------------------------------------------------------------
-- Queries
------------------------------------------------------------------------
function Style.IsEUI() return eui ~= nil end

function Style.Accent()
    if eui and eui.GetAccentColor then return eui.GetAccentColor() end
    return FALLBACK_ACCENT[1], FALLBACK_ACCENT[2], FALLBACK_ACCENT[3]
end

function Style.AccentHex()
    local r, g, b = Style.Accent()
    return ("ff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

-- Called when EllesmereUI's accent/theme changes live.
function Style.OnLooksChanged(fn)
    looksCallbacks[#looksCallbacks + 1] = fn
end

local FALLBACK_FONT = "Fonts\\ARIALN.TTF"
do
    local loc = GetLocale and GetLocale()
    if loc == "koKR" or loc == "zhCN" or loc == "zhTW" or loc == "ruRU" then
        FALLBACK_FONT = STANDARD_TEXT_FONT
    end
end

-- Sets a FontString to the theme font at the given size.
function Style.SetFont(fs, size, flags)
    local path, flag
    if eui and eui.GetFont then path, flag = eui.GetFont() end
    path = path or FALLBACK_FONT
    -- SetFont returns false when the file can't be used; some clients return nothing on success
    if fs:SetFont(path, size, flags or flag or "") == false then
        fs:SetFont(STANDARD_TEXT_FONT, size, flags or "")
    end
end

-- Creates a themed FontString.
function Style.Text(parent, size, r, g, b, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    Style.SetFont(fs, size or 12)
    fs:SetTextColor(r or 1, g or 1, b or 1)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

------------------------------------------------------------------------
-- Fallback primitives (flat dark, 1px borders, accent highlights)
------------------------------------------------------------------------
local F = {}

local function Solid(frame, layer, sub, r, g, b, a)
    local t = frame:CreateTexture(nil, layer, nil, sub)
    t:SetColorTexture(r, g, b, a)
    return t
end

local function FadeRegions(frame)
    for _, r in ipairs({ frame:GetRegions() }) do
        if r:IsObjectType("Texture") then r:SetAlpha(0) end
    end
end

-- 1px border drawn on the frame itself (no child frames: WoW Forever taints
-- panels when frames are created inside them).
local function Border(frame, r, g, b, a)
    if frame.__kBorder then return end
    local t = {}
    for i = 1, 4 do t[i] = Solid(frame, "OVERLAY", 7, r or 0, g or 0, b or 0, a or 1) end
    t[1]:SetPoint("TOPLEFT"); t[1]:SetPoint("TOPRIGHT"); t[1]:SetHeight(1)
    t[2]:SetPoint("BOTTOMLEFT"); t[2]:SetPoint("BOTTOMRIGHT"); t[2]:SetHeight(1)
    t[3]:SetPoint("TOPLEFT"); t[3]:SetPoint("BOTTOMLEFT"); t[3]:SetWidth(1)
    t[4]:SetPoint("TOPRIGHT"); t[4]:SetPoint("BOTTOMRIGHT"); t[4]:SetWidth(1)
    for _, tex in ipairs(t) do
        if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false); tex:SetTexelSnappingBias(0) end
    end
    frame.__kBorder = t
end

function F.Shell(frame, opts)
    if frame.__kShell then return end
    frame.__kShell = true
    FadeRegions(frame)
    Solid(frame, "BACKGROUND", -8, 0.055, 0.055, 0.062, 0.97):SetAllPoints()
    if not (opts and opts.noTopBar) then
        local bar = Solid(frame, "BACKGROUND", -5, 0, 0, 0, 0.5)
        bar:SetPoint("TOPLEFT"); bar:SetPoint("TOPRIGHT"); bar:SetHeight(25)
    end
    if opts and opts.bottomBar then
        local bar = Solid(frame, "BACKGROUND", -5, 0, 0, 0, 0.5)
        bar:SetPoint("BOTTOMLEFT"); bar:SetPoint("BOTTOMRIGHT")
        bar:SetHeight(type(opts.bottomBar) == "number" and opts.bottomBar or 25)
    end
    Border(frame, 0, 0, 0, 1)
end

function F.Panel(frame, opts)
    if frame.__kPanel then return end
    frame.__kPanel = true
    if not (opts and opts.noBg) then
        local a = (opts and opts.inset) and 0.35 or 0.2
        Solid(frame, "BACKGROUND", -6, 0, 0, 0, a):SetAllPoints()
    end
    if not (opts and opts.noBorder) then Border(frame, 1, 1, 1, 0.08) end
end

local function ClearButtonArt(b)
    for _, setter in ipairs({ "SetNormalTexture", "SetPushedTexture", "SetHighlightTexture", "SetDisabledTexture" }) do
        if b[setter] then b[setter](b, "") end
    end
    FadeRegions(b)
end

function F.Button(b)
    if b.__kButton then return end
    b.__kButton = true
    ClearButtonArt(b)
    Solid(b, "BACKGROUND", -6, 0.11, 0.11, 0.12, 1):SetAllPoints()
    local hl = Solid(b, "HIGHLIGHT", 0, 1, 1, 1, 0.07)
    hl:SetAllPoints()
    Border(b, 1, 1, 1, 0.12)
    if b.SetPushedTextOffset then b:SetPushedTextOffset(0, -1) end
end

function F.StateButtonLabel(b)
    local lab = b.Text or (b.GetFontString and b:GetFontString())
    if not lab or b.__kState then return end
    b.__kState = true
    local function reflect()
        if b:IsEnabled() then lab:SetTextColor(1, 1, 1) else lab:SetTextColor(0.45, 0.45, 0.45) end
    end
    b:HookScript("OnEnable", reflect)
    b:HookScript("OnDisable", reflect)
    reflect()
end

function F.EditBox(eb)
    if eb.__kEdit then return end
    eb.__kEdit = true
    FadeRegions(eb)
    for _, k in ipairs({ "Left", "Right", "Middle", "Mid" }) do
        if eb[k] and eb[k].SetAlpha then eb[k]:SetAlpha(0) end
    end
    if eb.searchIcon then eb.searchIcon:SetAlpha(0.6) end
    Solid(eb, "BACKGROUND", -6, 0.02, 0.02, 0.02, 1):SetAllPoints()
    Border(eb, 1, 1, 1, 0.12)
end

function F.Checkbox(cb)
    if cb.__kCheck then return end
    cb.__kCheck = true
    if cb.SetNormalTexture then cb:SetNormalTexture("") end
    if cb.SetPushedTexture then cb:SetPushedTexture("") end
    if cb.SetHighlightTexture then cb:SetHighlightTexture("") end
    local box = Solid(cb, "BACKGROUND", 0, 0.02, 0.02, 0.02, 1)
    box:SetPoint("CENTER")
    box:SetSize(14, 14)
    local edges = {}
    for i = 1, 4 do edges[i] = Solid(cb, "BORDER", 0, 1, 1, 1, 0.2) end
    edges[1]:SetPoint("TOPLEFT", box); edges[1]:SetPoint("TOPRIGHT", box); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT", box); edges[2]:SetPoint("BOTTOMRIGHT", box); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT", box); edges[3]:SetPoint("BOTTOMLEFT", box); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT", box); edges[4]:SetPoint("BOTTOMRIGHT", box); edges[4]:SetWidth(1)
    local check = cb.GetCheckedTexture and cb:GetCheckedTexture()
    if check then
        check:ClearAllPoints()
        check:SetPoint("CENTER", box)
        check:SetSize(18, 18)
        check:SetDesaturated(true)
        check:SetVertexColor(Style.Accent())
        cb.__kCheckTex = check
    end
end

function F.ScrollBar(sb)
    if sb.__kScroll then return end
    sb.__kScroll = true
    for _, k in ipairs({ "Back", "Forward" }) do
        if sb[k] then FadeRegions(sb[k]); if sb[k].Texture then sb[k].Texture:SetAlpha(0) end end
    end
    if sb.Track then FadeRegions(sb.Track) end
    local thumb = (sb.Track and sb.Track.Thumb) or (sb.GetThumb and sb:GetThumb())
    if thumb then
        FadeRegions(thumb)
        local t = Solid(thumb, "ARTWORK", 0, 1, 1, 1, 0.3)
        t:SetPoint("TOP"); t:SetPoint("BOTTOM"); t:SetWidth(4)
    end
end

function F.Tab(tab)
    if tab.__kTab then return end
    ClearButtonArt(tab)
    local d = {}
    tab.__kTab = d
    d.bg = Solid(tab, "BACKGROUND", -6, 0.068, 0.056, 0.052, 1)
    d.bg:SetAllPoints()
    d.hl = Solid(tab, "HIGHLIGHT", 0, 1, 1, 1, 0.05)
    d.hl:SetAllPoints()
    d.under = Solid(tab, "OVERLAY", 6, 1, 1, 1, 1)
    d.under:SetPoint("BOTTOMLEFT"); d.under:SetPoint("BOTTOMRIGHT"); d.under:SetHeight(2)
    d.under:Hide()
    local lab = tab.Text or (tab.GetFontString and tab:GetFontString())
    if lab then Style.SetFont(lab, 11) end
    d.label = lab
    if tab.SetPushedTextOffset then tab:SetPushedTextOffset(0, 0) end
end

function F.SetTabSelection(tab, selected)
    local d = tab.__kTab
    if not d then return end
    d.under:SetColorTexture(Style.Accent())
    d.under:SetShown(selected and true or false)
    if d.label then
        if selected then d.label:SetTextColor(1, 1, 1) else d.label:SetTextColor(0.6, 0.6, 0.6) end
    end
end

function F.CloseButton(b)
    if b.__kClose then return end
    b.__kClose = true
    if not (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("uitools-icon-close")) then
        return -- keep the stock art rather than end up with an invisible button
    end
    ClearButtonArt(b)
    local x = b:CreateTexture(nil, "OVERLAY")
    x:SetAtlas("uitools-icon-close")
    x:SetSize(14, 14)
    x:SetPoint("CENTER")
    x:SetVertexColor(1, 1, 1, 0.75)
    b:HookScript("OnEnter", function() x:SetVertexColor(1, 1, 1, 1) end)
    b:HookScript("OnLeave", function() x:SetVertexColor(1, 1, 1, 0.75) end)
end

------------------------------------------------------------------------
-- Dispatch
------------------------------------------------------------------------
local function Run(kind, frame, ...)
    if eui then
        local fn = (kind == "Shell") and eui.Shell or eui[kind]
        if fn then return fn(frame, ...) end
    end
    local fb = F[kind]
    if fb then return fb(frame, ...) end
end

-- Style.Apply("Button", btn) etc. Safe to call repeatedly on the same frame.
function Style.Apply(kind, frame, ...)
    if not frame then return end
    if decided then
        local ok, err = pcall(Run, kind, frame, ...)
        if not ok then geterrorhandler()(err) end
        return
    end
    pending[#pending + 1] = { kind = kind, frame = frame, n = select("#", ...), ... }
end

local function Decide()
    if decided then return end
    decided = true
    for _, p in ipairs(pending) do
        pcall(Run, p.kind, p.frame, unpack(p, 1, p.n))
    end
    pending = nil
end

if EllesmereUI and EllesmereUI.RegisterSkin then
    EllesmereUI.RegisterSkin("Ketchup", function(S)
        if decided then return end -- too late: frames already have the built-in look
        eui = S
        if S.OnLooksChanged then
            S.OnLooksChanged(function()
                for _, fn in ipairs(looksCallbacks) do pcall(fn) end
            end)
        end
        Decide()
    end)
end

-- EllesmereUI dispatches its skins at PLAYER_LOGIN. If it hasn't called us
-- shortly after login, it isn't going to: use the built-in look.
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    C_Timer.After(0.5, Decide)
end)
