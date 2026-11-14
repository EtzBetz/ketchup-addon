-- Ketchup: user interface (main window, export/import dialog, minimap & quest log buttons).
local _, ns = ...
local K = ns.K
local S = ns.Serialize
local Style = ns.Style
local L = ns.L

local UI = {}
K.UI = UI

local ICON = "Interface\\AddOns\\Ketchup\\Media\\Logo" -- 64x64 TGA, full-bleed art
local TABS = {
    { key = "completed", label = L["Done by them, not you"] },
    { key = "log",       label = L["Their quest log"] },
    { key = "ahead",     label = L["You're behind on"] },
}

local LOG_STATUS = {
    missing = "|cffff9933" .. L["not in your log"] .. "|r",
    even    = "|cff20ff20" .. L["in sync"] .. "|r",
    myahead = "|cff20ff20" .. L["you're ahead"] .. "|r",
    done    = "|cff888888" .. L["you already turned it in"] .. "|r",
}
local currentTab = "completed"
local transfers = {} -- [key] = "got/n"

local WIDTH, HEIGHT = 940, 600
local PAD = 10
local TITLE_H, FOOTER_H = 25, 24
local SIDEBAR_W = 240
local MAIN_W = WIDTH - SIDEBAR_W - 3 * PAD -- width of the right-hand area

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------
local function Ago(ts)
    if not ts or ts == 0 then return L["never"] end
    local d = time() - ts
    if d < 60 then return L["just now"] end
    if d < 3600 then return L["%d min ago"]:format(math.floor(d / 60)) end
    if d < 86400 then return L["%d h ago"]:format(math.floor(d / 3600)) end
    return L["%d d ago"]:format(math.floor(d / 86400))
end

local function Tooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", GameTooltip_Hide)
end

local function MakeButton(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 120, height or 24)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    local fs = b:GetFontString()
    if fs then Style.SetFont(fs, 12) end
    Style.Apply("Button", b)
    Style.Apply("StateButtonLabel", b)
    return b
end

local function MakeTab(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(160, 26)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    Style.Apply("Tab", b)
    return b
end

local function MakeCheck(parent, label, tooltip, get, set)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(20, 20)
    if c.Text then c.Text:SetText("") end
    local fs = Style.Text(c, 12, 0.85, 0.85, 0.85)
    fs:SetPoint("LEFT", c, "RIGHT", 4, 0)
    fs:SetText(label)
    c.label = fs
    -- let the label be clicked too
    c:SetHitRectInsets(0, -(fs:GetStringWidth() + 6), 0, 0)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    if tooltip then Tooltip(c, label, tooltip) end
    c:SetChecked(get())
    Style.Apply("Checkbox", c)
    return c
end

-- Long translations: cut a checkbox label to maxWidth ("…"); the tooltip
-- title still shows the full text.
local function FitCheckLabel(c, maxWidth)
    maxWidth = math.floor(maxWidth)
    if c.label:GetStringWidth() > maxWidth then
        c.label:SetWidth(maxWidth)
        c:SetHitRectInsets(0, -(maxWidth + 6), 0, 0)
    end
end

local function SectionLabel(parent, text)
    local fs = Style.Text(parent, 10, 0.55, 0.55, 0.55)
    fs:SetText(text)
    return fs
end

local function CreateList(parent, extent, initializer)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(extent)
    view:SetElementInitializer("Button", initializer)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
        pcall(ScrollUtil.AddManagedScrollBarVisibilityBehavior, box, bar)
    end
    Style.Apply("ScrollBar", bar)
    return box, bar
end

local function SetRows(box, rows)
    local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
    box:SetDataProvider(CreateDataProvider(rows), retain)
end

-- "Horde" / "Alliance" in the client's language
local function FactionName(fa)
    if not fa or fa == "" then return "" end
    return _G["FACTION_" .. fa:upper()] or fa
end

local function ClassRGB(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 0.7, 0.7, 0.7
end

-- A transparent child frame to draw our own textures on. EllesmereUI
-- re-fades every texture directly on the frames it skins (Shell/Panel
-- "restrip"), so icons, dots and color bars must not live on those frames.
local function Canvas(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetAllPoints()
    c:SetFrameLevel(parent:GetFrameLevel() + 2)
    return c
end

-- round dot (online indicator)
local function Dot(parent, size)
    local dot = parent:CreateTexture(nil, "OVERLAY")
    dot:SetSize(size, size)
    dot:SetColorTexture(0.25, 0.9, 0.35, 1)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(dot)
    dot:AddMaskTexture(mask)
    return dot
end

local function ObjectiveSummary(q)
    if not q then return "" end
    if q.c == 1 then return "|cff20ff20" .. L["ready to turn in"] .. "|r" end
    local done, total = 0, 0
    for _, o in ipairs(q.o or {}) do
        total = total + 1
        if o.f == 1 then done = done + 1 end
    end
    if total == 0 then return "" end
    return L["%d/%d objectives"]:format(done, total)
end

local function AheadSummary(e)
    local pq, mq = e.partnerQuest, e.myQuest
    if not pq or not mq then return "" end
    if pq.c == 1 and mq.c ~= 1 then return "|cff20ff20" .. L["they can turn it in"] .. "|r" end
    for j, po in ipairs(pq.o or {}) do
        local mo = mq.o and mq.o[j]
        if mo and po.h > mo.h then
            return L["them %d/%d"]:format(po.h, po.n) .. "  |cff777777·|r  " .. L["you %d/%d"]:format(mo.h, mo.n)
        end
    end
    return ""
end

------------------------------------------------------------------------
-- Main window
------------------------------------------------------------------------
function UI:Create()
    if self.frame then return end

    local f = CreateFrame("Frame", "KetchupFrame", UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnShow", function() UI:Refresh() end)
    f:Hide()
    tinsert(UISpecialFrames, "KetchupFrame")
    Style.Apply("Shell", f, { bottomBar = FOOTER_H })
    self.frame = f

    -- Title bar ----------------------------------------------------------
    local icon = Canvas(f):CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("TOPLEFT", 8, -5)
    icon:SetTexture(ICON)

    local title = Style.Text(f, 13)
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    title:SetText("Ketchup")

    local subtitle = Style.Text(f, 11, 0.5, 0.5, 0.5)
    subtitle:SetPoint("LEFT", title, "RIGHT", 8, -1)
    subtitle:SetText(L["quest catch-up"])

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() f:Hide() end)
    Style.Apply("CloseButton", close)

    -- Footer -------------------------------------------------------------
    local hint = Style.Text(f, 11, 0.5, 0.5, 0.5)
    hint:SetPoint("BOTTOMLEFT", 12, 6)
    hint:SetText(table.concat({ L["Hover a quest for details"], L["Shift-click: link in chat"],
        L["Right-click: ignore / unignore"] }, "  ·  "))

    local version = Style.Text(f, 11, 0.4, 0.4, 0.4)
    version:SetPoint("BOTTOMRIGHT", -12, 6)
    version:SetJustifyH("RIGHT")
    version:SetText("v" .. tostring(K.version))

    -- Sidebar --------------------------------------------------------------
    local side = CreateFrame("Frame", nil, f)
    side:SetPoint("TOPLEFT", PAD, -(TITLE_H + PAD))
    side:SetPoint("BOTTOMLEFT", PAD, FOOTER_H + PAD)
    side:SetWidth(SIDEBAR_W)
    Style.Apply("Panel", side, { inset = true })
    local innerW = SIDEBAR_W - 24

    local partnersLabel = SectionLabel(side, L["PARTNERS"])
    partnersLabel:SetPoint("TOPLEFT", 12, -12)

    local partnerBox = CreateList(side, 48, function(button, data) UI:InitPartnerRow(button, data) end)
    partnerBox:SetPoint("TOPLEFT", 6, -28)
    partnerBox:SetPoint("TOPRIGHT", -16, -28)
    partnerBox:SetHeight(4 * 48)
    self.partnerBox = partnerBox

    local emptyPartners = Style.Text(side, 12, 0.55, 0.55, 0.55)
    emptyPartners:SetPoint("TOPLEFT", partnerBox, "TOPLEFT", 6, -8)
    emptyPartners:SetPoint("RIGHT", partnerBox, "RIGHT", -6, 0)
    emptyPartners:SetWordWrap(true)
    emptyPartners:SetText(L["No partner data yet.\n\nGroup up with your friend (both need Ketchup), or import the string they exported."])
    self.emptyPartners = emptyPartners

    local actionsLabel = SectionLabel(side, L["ACTIONS"])
    actionsLabel:SetPoint("TOPLEFT", partnerBox, "BOTTOMLEFT", 6, -14)

    local y = -(28 + 4 * 48 + 32)
    local function addButton(text, onClick, tip)
        local b = MakeButton(side, text, innerW, 26, onClick)
        b:SetPoint("TOPLEFT", 12, y)
        if tip then Tooltip(b, text, tip) end
        y = y - 30
        return b
    end
    addButton(L["Sync with group"], function() K.Comm:RequestFromGroup() end,
        L["Ask every group member running Ketchup for their current progress, and send yours."])
    addButton(L["Export my progress"], function() UI:ShowExport() end,
        L["Create a string with your quest progress that you can paste to your partner over any messenger."])
    addButton(L["Import string"], function() UI:ShowImport() end,
        L["Paste a string your partner exported."])
    self.removeButton = addButton(L["Remove selected partner"], function()
        local key = K.db.selected
        if key then
            StaticPopup_Show("KETCHUP_REMOVE_PARTNER", K:ShortName(key), nil, key)
        end
    end)

    local settingsLabel = SectionLabel(side, L["SETTINGS"])
    settingsLabel:SetPoint("TOPLEFT", 12, y - 10)

    local auto = MakeCheck(side, L["Auto-share while grouped"],
        L["Automatically send your progress to group members running Ketchup whenever your quests change."],
        function() return K.db.settings.autoShare end,
        function(v) K.db.settings.autoShare = v; if v then K:ScheduleShare(1, true) end end)
    auto:SetPoint("TOPLEFT", 10, y - 26)

    local markers = MakeCheck(side, L["Sync icons in quest log"],
        L["Show an icon per quest in your quest log:"] .. "\n"
        .. "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t  " .. L["partner has this quest too"] .. "\n"
        .. "|A:creditsscreen-assets-buttons-fastforward:14:14:0:0:255:165:38|a  "
        .. L["do it to catch up (partner turned it in or has every objective done)"] .. "\n"
        .. "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t  " .. L["partner doesn't have it"],
        function() return K.db.settings.questLogMarkers end,
        function(v) K.db.settings.questLogMarkers = v; UI:UpdateQuestLogMarkers() end)
    markers:SetPoint("TOPLEFT", auto, "BOTTOMLEFT", 0, -4)

    local warn = MakeCheck(side, L["Warn on their active quests"],
        L["Show an on-screen warning when you make progress on a quest your partner has active, unless you're questing together: they're in your group, online and in the same zone."],
        function() return K.db.settings.warnProgress end,
        function(v) K.db.settings.warnProgress = v end)
    warn:SetPoint("TOPLEFT", markers, "BOTTOMLEFT", 0, -4)
    for _, c in ipairs({ auto, markers, warn }) do
        FitCheckLabel(c, SIDEBAR_W - 10 - 24 - 8) -- stay inside the sidebar
    end

    -- Main area --------------------------------------------------------------
    local main = CreateFrame("Frame", nil, f)
    main:SetPoint("TOPLEFT", side, "TOPRIGHT", PAD, 0)
    main:SetPoint("BOTTOMRIGHT", -PAD, FOOTER_H + PAD)
    self.main = main

    -- partner header card
    local card = CreateFrame("Frame", nil, main)
    card:SetPoint("TOPLEFT")
    card:SetPoint("TOPRIGHT")
    card:SetHeight(76)
    Style.Apply("Panel", card)

    local classBar = Canvas(card):CreateTexture(nil, "ARTWORK")
    classBar:SetPoint("TOPLEFT", 1, -1)
    classBar:SetPoint("BOTTOMLEFT", 1, 1)
    classBar:SetWidth(3)
    self.classBar = classBar

    local header = Style.Text(card, 18)
    header:SetPoint("TOPLEFT", 16, -10)
    self.header = header

    -- two stat lines, so longer languages don't get cut off
    local sub = Style.Text(card, 11, 0.62, 0.62, 0.62)
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -7)
    sub:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    self.sub = sub

    local sub2 = Style.Text(card, 11, 0.5, 0.5, 0.5)
    sub2:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -4)
    sub2:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    self.sub2 = sub2

    local pill = CreateFrame("Frame", nil, card)
    pill:SetSize(130, 20)
    pill:SetPoint("TOPRIGHT", -12, -12)
    Style.Apply("Panel", pill, { inset = true })
    pill.dot = Dot(Canvas(pill), 7)
    pill.dot:SetPoint("LEFT", 8, 0)
    pill.text = Style.Text(pill, 11, 0.85, 0.85, 0.85)
    pill.text:SetPoint("LEFT", pill.dot, "RIGHT", 6, 0)
    self.pill = pill

    -- tabs
    self.tabButtons = {}
    local prev
    for _, tab in ipairs(TABS) do
        local b = MakeTab(main, tab.label, function()
            currentTab = tab.key
            UI:RebuildRows()
        end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10) end
        b.tabKey = tab.key
        b.baseLabel = tab.label
        self.tabButtons[#self.tabButtons + 1] = b
        prev = b
    end

    -- toolbar: search + filters
    local search = CreateFrame("EditBox", nil, main, "SearchBoxTemplate")
    search:SetSize(190, 22)
    search:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 6, -46)
    search:HookScript("OnTextChanged", function() UI:RebuildRows() end)
    self.search = search

    local doable = MakeCheck(main, L["Only doable now"],
        L["Uses Questie to hide quests you don't have yet and can't pick up yet (level, race/class, missing prerequisite)."],
        function() return K.db.settings.onlyDoable end,
        function(v) K.db.settings.onlyDoable = v; UI:RebuildRows() end)
    doable:SetPoint("LEFT", search, "RIGHT", 16, 0)
    self.doableCheck = doable

    local hideLog = MakeCheck(main, L["Hide quests in my log"],
        L["On the '%s' tab: hide quests you already have in your quest log."]:format(L["Done by them, not you"]),
        function() return K.db.settings.hideInMyLog end,
        function(v) K.db.settings.hideInMyLog = v; UI:RebuildRows() end)
    hideLog:SetPoint("LEFT", doable.label, "RIGHT", 16, 0)

    local showIgn = MakeCheck(main, L["Show ignored"],
        L["Right-click a quest to ignore it (e.g. class quests you can't do)."],
        function() return K.db.settings.showIgnored end,
        function(v) K.db.settings.showIgnored = v; UI:RebuildRows() end)
    showIgn:SetPoint("LEFT", hideLog.label, "RIGHT", 16, 0)

    -- Fit the toolbar into the window for longer languages: shrink the
    -- search box first, then cut the filter labels proportionally.
    do
        local checks = { doable, hideLog, showIgn }
        local perCheck = 16 + 20 + 4 -- gap + box + label offset
        local labelsW = 0
        for _, c in ipairs(checks) do labelsW = labelsW + c.label:GetStringWidth() end
        local free = MAIN_W - 6 - #checks * perCheck - labelsW - 8
        local searchW = math.max(110, math.min(190, free))
        search:SetWidth(searchW)
        local room = MAIN_W - 6 - searchW - #checks * perCheck - 8
        if labelsW > room then
            for _, c in ipairs(checks) do
                FitCheckLabel(c, room * c.label:GetStringWidth() / labelsW)
            end
        end
    end
    Style.Apply("EditBox", search, { padInput = true })

    -- quest list
    local listPanel = CreateFrame("Frame", nil, main)
    listPanel:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -78)
    listPanel:SetPoint("BOTTOMRIGHT")
    Style.Apply("Panel", listPanel, { inset = true })

    local questBox = CreateList(listPanel, 24, function(button, data) UI:InitQuestRow(button, data) end)
    questBox:SetPoint("TOPLEFT", 4, -4)
    questBox:SetPoint("BOTTOMRIGHT", -18, 4)
    self.questBox = questBox

    local empty = Style.Text(listPanel, 14, 0.6, 0.6, 0.6)
    empty:SetPoint("CENTER", listPanel, "CENTER", 0, 20)
    empty:SetJustifyH("CENTER")
    self.emptyQuests = empty

    local emptySub = Style.Text(listPanel, 11, 0.45, 0.45, 0.45)
    emptySub:SetPoint("TOP", empty, "BOTTOM", 0, -8)
    emptySub:SetJustifyH("CENTER")
    self.emptyQuestsSub = emptySub

    -- live accent changes (EllesmereUI): recolor what we painted ourselves
    Style.OnLooksChanged(function() if UI:IsShown() then UI:Refresh() end end)
end

function UI:InitPartnerRow(button, data)
    if not button.ketchupInit then
        button.ketchupInit = true
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.04)
        local sel = button:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints()
        button.sel = sel
        local bar = button:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("TOPLEFT", 0, -6)
        bar:SetPoint("BOTTOMLEFT", 0, 6)
        bar:SetWidth(3)
        button.bar = bar
        button.name = Style.Text(button, 13)
        button.name:SetPoint("TOPLEFT", 12, -9)
        button.name:SetPoint("RIGHT", -22, 0)
        button.info = Style.Text(button, 11, 0.55, 0.55, 0.55)
        button.info:SetPoint("TOPLEFT", button.name, "BOTTOMLEFT", 0, -5)
        button.info:SetPoint("RIGHT", -8, 0)
        button.dot = Dot(button, 7)
        button.dot:SetPoint("TOPRIGHT", -10, -13)
        button:SetScript("OnClick", function(self)
            K.db.selected = self.key
            UI:Refresh()
        end)
    end
    local p = data.partner
    button.key = data.key
    local selected = K.db.selected == data.key
    local ar, ag, ab = Style.Accent()
    button.sel:SetColorTexture(ar, ag, ab, 0.14)
    button.sel:SetShown(selected)
    button.bar:SetColorTexture(ClassRGB(p.cl))
    button.name:SetText(K:ShortName(data.key))
    button.name:SetTextColor(ClassRGB(p.cl))
    button.dot:SetShown(K:IsPartnerOnline(data.key))
    local t = transfers[data.key]
    if t then
        button.info:SetText(L["receiving %s ..."]:format(t))
    else
        button.info:SetText(L["Level %d"]:format(p.lv or 0) .. "  ·  " .. Ago(p.ts)
            .. (p.source == "import" and ("  ·  " .. L["import"]) or ""))
    end
end

function UI:InitQuestRow(button, data)
    if not button.ketchupInit then
        button.ketchupInit = true
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        button.hl = hl
        -- quest row
        button.lvl = Style.Text(button, 11)
        button.lvl:SetPoint("LEFT", 6, 0)
        button.lvl:SetWidth(24)
        button.lvl:SetJustifyH("RIGHT")
        button.status = Style.Text(button, 11, 0.8, 0.8, 0.8)
        button.status:SetPoint("RIGHT", -8, 0)
        button.status:SetJustifyH("RIGHT")
        button.title = Style.Text(button, 12)
        button.title:SetPoint("LEFT", button.lvl, "RIGHT", 10, 0)
        button.title:SetPoint("RIGHT", button.status, "LEFT", -12, 0)
        -- zone header row
        button.zone = Style.Text(button, 11)
        button.zone:SetPoint("BOTTOMLEFT", 8, 5)
        button.count = Style.Text(button, 11, 0.45, 0.45, 0.45)
        button.count:SetPoint("LEFT", button.zone, "RIGHT", 6, 0)
        button.line = button:CreateTexture(nil, "ARTWORK")
        button.line:SetColorTexture(1, 1, 1, 0.08)
        button.line:SetHeight(1)
        button.line:SetPoint("LEFT", button.count, "RIGHT", 8, 0)
        button.line:SetPoint("RIGHT", -8, 0)
        button:SetScript("OnClick", function(self, mouse) UI:OnQuestClick(self.data, mouse) end)
        button:SetScript("OnEnter", function(self) UI:ShowQuestTooltip(self, self.data) end)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end
    button.data = data
    local isHeader = data.header and true or false
    button.hl:SetShown(not isHeader)
    button.lvl:SetShown(not isHeader)
    button.title:SetShown(not isHeader)
    button.status:SetShown(not isHeader)
    button.zone:SetShown(isHeader)
    button.count:SetShown(isHeader)
    button.line:SetShown(isHeader)

    if isHeader then
        button.zone:SetText(data.text)
        button.zone:SetTextColor(Style.Accent())
        button.count:SetText(data.count)
        return
    end

    local e = data.entry
    button.lvl:SetText(e.level and e.level > 0 and e.level or "")
    if e.level and e.level > 0 and GetQuestDifficultyColor then
        local c = GetQuestDifficultyColor(e.level)
        button.lvl:SetTextColor(c.r, c.g, c.b)
    else
        button.lvl:SetTextColor(0.6, 0.6, 0.6)
    end
    if e.ignored then
        button.title:SetText(e.title .. "  " .. L["(ignored)"])
        button.title:SetTextColor(0.45, 0.45, 0.45)
    else
        button.title:SetText(e.title)
        button.title:SetTextColor(0.92, 0.92, 0.92)
    end

    local status = ""
    if currentTab == "completed" then
        if e.inMyLog then status = "|cffffd100" .. L["in your log"] .. "|r" end
    elseif currentTab == "log" then
        if e.status == "behind" then
            status = "|cffff9933" .. L["behind:"] .. "|r " .. AheadSummary(e)
        elseif e.status == "missing" then
            local summary = ObjectiveSummary(e.partnerQuest)
            status = LOG_STATUS.missing .. (summary ~= "" and ("  |cff777777·|r  " .. L["them: %s"]:format(summary)) or "")
        else
            status = LOG_STATUS[e.status] or ""
        end
    else
        status = AheadSummary(e)
    end
    button.status:SetText(status)
end

function UI:OnQuestClick(data, mouse)
    if not data or data.header then return end
    local e = data.entry
    if mouse == "RightButton" then
        if K.db.ignored[e.id] then K.db.ignored[e.id] = nil else K.db.ignored[e.id] = true end
        e.ignored = K.db.ignored[e.id] and true or false
        self:RebuildRows()
    elseif IsShiftKeyDown() then
        local link = ("|cffffff00|Hquest:%d:%d|h[%s]|h|r"):format(e.id, e.level or 0, e.title)
        if ChatEdit_InsertLink and not ChatEdit_InsertLink(link) then
            ChatFrame_OpenChat(link)
        end
    end
end

local function AddObjectives(tt, header, q, r, g, b)
    if not q then return end
    tt:AddLine(header, r, g, b)
    if q.c == 1 then tt:AddLine("  " .. L["Ready to turn in"], 0.2, 1, 0.2) end
    for _, o in ipairs(q.o or {}) do
        local done = o.f == 1
        tt:AddLine("  " .. (o.t ~= "" and o.t or (o.h .. "/" .. o.n)), done and 0.5 or 1, done and 0.5 or 1, done and 0.5 or 1)
    end
end

function UI:ShowQuestTooltip(owner, data)
    if not data or data.header then return end
    local e = data.entry
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(e.title, 1, 0.82, 0)
    GameTooltip:AddDoubleLine(L["Quest ID"], e.id, 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine(L["Zone"], e.zone, 0.7, 0.7, 0.7, 1, 1, 1)
    if e.level then GameTooltip:AddDoubleLine(L["Level"], e.level, 0.7, 0.7, 0.7, 1, 1, 1) end
    if e.reqLevel then GameTooltip:AddDoubleLine(L["Required level"], e.reqLevel, 0.7, 0.7, 0.7, 1, 1, 1) end
    local doable = K:IsDoable(e.id)
    if doable ~= nil then
        GameTooltip:AddDoubleLine(L["Available to you now"], doable and L["yes"] or L["no"], 0.7, 0.7, 0.7,
            doable and 0.2 or 1, doable and 1 or 0.3, doable and 0.2 or 0.3)
    end
    if e.inMyLog then GameTooltip:AddLine(L["This quest is in your log."], 1, 0.82, 0) end
    local partnerName = K:ShortName(K.db.selected)
    if e.partnerQuest or e.myQuest then GameTooltip:AddLine(" ") end
    AddObjectives(GameTooltip, L["%s's progress:"]:format(partnerName), e.partnerQuest, 0.4, 0.8, 1)
    AddObjectives(GameTooltip, L["Your progress:"], e.myQuest, 1, 0.82, 0)
    if e.ignored then GameTooltip:AddLine(L["Ignored (right-click to unignore)"], 0.6, 0.6, 0.6) end
    GameTooltip:Show()
end

function UI:IsShown()
    return self.frame and self.frame:IsShown()
end

function UI:Toggle()
    self:Create()
    self.frame:SetShown(not self.frame:IsShown())
end

function UI:Open()
    self:Create()
    self.frame:Show()
end

function UI:SetTransferProgress(key, got, n)
    transfers[key] = got and (got .. "/" .. n) or nil
    if self:IsShown() then self:RefreshPartners() end
end

function UI:RefreshPartners()
    local rows = {}
    for key, p in pairs(K:VisiblePartners()) do -- never list my own character
        rows[#rows + 1] = { key = key, partner = p }
    end
    table.sort(rows, function(a, b)
        local oa, ob = K:IsPartnerOnline(a.key), K:IsPartnerOnline(b.key)
        if oa ~= ob then return oa end
        return (a.partner.ts or 0) > (b.partner.ts or 0)
    end)
    SetRows(self.partnerBox, rows)
    self.emptyPartners:SetShown(#rows == 0)
    self.removeButton:SetEnabled(K.db.selected ~= nil and K.db.partners[K.db.selected] ~= nil)
end

-- Full refresh: recompute diff for selected partner.
function UI:Refresh()
    self:UpdateQuestLogMarkers() -- partner data or selection may have changed
    if not self:IsShown() then return end
    K:ValidateSelection()
    self:RefreshPartners()

    local key = K.db.selected
    local p = K:GetPartner(key)
    if not p then
        self.header:SetText(L["Nobody to catch up with yet"])
        self.header:SetTextColor(1, 1, 1)
        self.classBar:SetColorTexture(Style.Accent())
        self.sub:SetText(L["Join a group with your partner, or import a string they exported."])
        self.sub2:SetText("")
        self.pill:Hide()
        self.diff = nil
    else
        self.header:SetText(K:ShortName(key))
        self.header:SetTextColor(ClassRGB(p.cl))
        self.classBar:SetColorTexture(ClassRGB(p.cl))
        self.diff = K:ComputeDiff(key)
        local sep = "  |cff555555·|r  "
        self.sub:SetText(table.concat({
            L["Level %d %s"]:format(p.lv or 0, FactionName(p.fa)),
            L["%d completed (%d also by you)"]:format(self.diff.completedTotal or 0, self.diff.completedShared or 0),
            L["%d in quest log"]:format(#(p.q or {})),
        }, sep))
        self.sub2:SetText(L["updated %s via %s"]:format(Ago(p.ts), p.source == "import" and L["import"] or L["group sync"]))
        local online = K:IsPartnerOnline(key)
        self.pill.dot:SetColorTexture(online and 0.25 or 0.5, online and 0.9 or 0.5, online and 0.35 or 0.5, 1)
        self.pill.text:SetText(online and L["In your group"] or L["Saved data"])
        self.pill:SetWidth(self.pill.text:GetStringWidth() + 30)
        self.pill:Show()
    end
    local hasQuestie = K:HasQuestie()
    self.doableCheck:SetEnabled(hasQuestie)
    self.doableCheck.label:SetTextColor(hasQuestie and 0.85 or 0.4, hasQuestie and 0.85 or 0.4, hasQuestie and 0.85 or 0.4)
    self:RebuildRows()
end

local function PassesFilter(e, tab, query)
    local st = K.db.settings
    if e.ignored and not st.showIgnored then return false end
    -- "in my log" / "can I pick it up" only make sense for quests I don't have yet
    local pickable = tab == "completed" or (tab == "log" and e.status == "missing")
    if tab == "completed" and st.hideInMyLog and e.inMyLog then return false end
    if pickable and st.onlyDoable and not e.inMyLog and K:IsDoable(e.id) == false then return false end
    if query and query ~= "" then
        local hay = (e.title .. " " .. e.zone .. " " .. e.id):lower()
        if not hay:find(query, 1, true) then return false end
    end
    return true
end

-- Re-filter the cached diff (cheap; used for tab/filter changes).
function UI:RebuildRows()
    if not self:IsShown() then return end
    local diff = self.diff or { completed = {}, log = {}, ahead = {} }
    local query = self.search:GetText() or ""
    query = query:lower()

    for _, b in ipairs(self.tabButtons) do
        local n, total = 0, #diff[b.tabKey]
        for _, e in ipairs(diff[b.tabKey]) do
            if PassesFilter(e, b.tabKey, query) then n = n + 1 end
        end
        if n == total then
            b:SetText(("%s  %d"):format(b.baseLabel, n))
        else
            b:SetText(("%s  %d / %d"):format(b.baseLabel, n, total))
        end
        b:SetWidth(math.max(120, b:GetFontString():GetStringWidth() + 32))
        Style.Apply("SetTabSelection", b, b.tabKey == currentTab)
    end
    -- longer languages: squeeze the tabs so the row never leaves the window
    local tabsW = 0
    for _, b in ipairs(self.tabButtons) do tabsW = tabsW + b:GetWidth() + 2 end
    if tabsW > MAIN_W then
        for _, b in ipairs(self.tabButtons) do
            b:SetWidth(math.floor(b:GetWidth() * MAIN_W / tabsW))
        end
    end

    local rows, lastZone, headerRow = {}, nil, nil
    for _, e in ipairs(diff[currentTab]) do
        if PassesFilter(e, currentTab, query) then
            if e.zone ~= lastZone then
                lastZone = e.zone
                headerRow = { header = true, text = e.zone, count = 0 }
                rows[#rows + 1] = headerRow
            end
            headerRow.count = headerRow.count + 1
            rows[#rows + 1] = { entry = e }
        end
    end
    SetRows(self.questBox, rows)

    if not self.diff then
        self.emptyQuests:SetText(L["No partner selected"])
        self.emptyQuestsSub:SetText(L["Group up with your partner or import their string to get started."])
    elseif #rows == 0 then
        self.emptyQuests:SetText(L["Nothing here - you're in sync!"])
        self.emptyQuestsSub:SetText(query ~= "" and L["No quest matches your search."] or "")
    else
        self.emptyQuests:SetText("")
        self.emptyQuestsSub:SetText("")
    end
end

StaticPopupDialogs["KETCHUP_REMOVE_PARTNER"] = {
    text = L["Remove the saved quest progress of %s?"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, key) K:RemovePartner(key) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

------------------------------------------------------------------------
-- Export / import dialog
------------------------------------------------------------------------
function UI:CreateStringDialog()
    if self.stringDialog then return self.stringDialog end
    local d = CreateFrame("Frame", "KetchupStringDialog", UIParent)
    d:SetSize(580, 380)
    d:SetPoint("CENTER", 0, 40)
    d:SetFrameStrata("DIALOG")
    d:SetToplevel(true)
    d:SetMovable(true)
    d:EnableMouse(true)
    d:SetClampedToScreen(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:Hide()
    tinsert(UISpecialFrames, "KetchupStringDialog")
    Style.Apply("Shell", d, { bottomBar = 44 })

    local icon = Canvas(d):CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("TOPLEFT", 8, -5)
    icon:SetTexture(ICON)

    d.titleText = Style.Text(d, 13)
    d.titleText:SetPoint("LEFT", icon, "RIGHT", 6, 0)

    local close = CreateFrame("Button", nil, d, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() d:Hide() end)
    Style.Apply("CloseButton", close)

    local info = Style.Text(d, 12, 0.8, 0.8, 0.8)
    info:SetPoint("TOPLEFT", 14, -(TITLE_H + 12))
    info:SetPoint("RIGHT", -14, 0)
    info:SetWordWrap(true)
    d.info = info

    local panel = CreateFrame("Frame", nil, d)
    panel:SetPoint("TOPLEFT", 12, -(TITLE_H + 50))
    panel:SetPoint("BOTTOMRIGHT", -12, 54)
    Style.Apply("Panel", panel, { inset = true })

    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, panel, "ScrollFrameTemplate")
    if not ok then scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate") end
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -22, 8)
    if scroll.ScrollBar then Style.Apply("ScrollBar", scroll.ScrollBar) end

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    Style.SetFont(edit, 12)
    edit:SetTextColor(0.9, 0.9, 0.9)
    edit:SetWidth(520)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function() d:Hide() end)
    edit:SetScript("OnTextChanged", function(self, user)
        if d.mode == "export" and user then
            -- keep the export string intact
            self:SetText(d.exportText or "")
            self:HighlightText()
        end
    end)
    scroll:SetScrollChild(edit)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
    d.edit = edit

    local action = MakeButton(d, L["Import"], 130, 26, function()
        if d.mode == "import" then
            UI:DoImport(edit:GetText())
        else
            edit:SetFocus()
            edit:HighlightText()
        end
    end)
    action:SetPoint("BOTTOMRIGHT", -12, 9)
    d.action = action

    local closeBtn = MakeButton(d, CLOSE or L["Close"], 100, 26, function() d:Hide() end)
    closeBtn:SetPoint("RIGHT", action, "LEFT", -8, 0)

    self.stringDialog = d
    return d
end

function UI:ShowExport()
    local d = self:CreateStringDialog()
    local snapshot = K:BuildSnapshot()
    local text, err = S.ToExportString(snapshot)
    if not text then
        K:Print(L["Export failed: %s"]:format(tostring(err)))
        return
    end
    d.mode = "export"
    d.exportText = text
    d.titleText:SetText(L["Export my progress"])
    d.info:SetText(L["Press %s to copy and send it to your partner over any messenger. They paste it via %s."]:format(
            "|cffffd100Ctrl+C|r", "|cffffd100" .. L["Import string"] .. "|r")
        .. "\n|cff888888" .. L["%d completed quests  ·  %d quests in log  ·  %d characters"]:format(
            #snapshot.c, #snapshot.q, #text) .. "|r")
    d.action:SetText(L["Select all"])
    d.edit:SetText(text)
    d:Show()
    d.edit:SetFocus()
    d.edit:HighlightText()
end

function UI:ShowImport()
    local d = self:CreateStringDialog()
    d.mode = "import"
    d.exportText = nil
    d.titleText:SetText(L["Import partner progress"])
    d.info:SetText(L["Paste the string your partner exported (%s), then click %s."]:format(
            "|cffffd100Ctrl+V|r", "|cffffd100" .. L["Import"] .. "|r")
        .. "\n|cff888888" .. L["Line breaks or spaces added by a messenger are fine."] .. "|r")
    d.action:SetText(L["Import"])
    d.edit:SetText("")
    d:Show()
    d.edit:SetFocus()
end

function UI:DoImport(text)
    local snapshot, err = S.FromExportString(text)
    if not snapshot then
        K:Print("|cffff5555" .. L["Import failed:"] .. "|r " .. tostring(err))
        return
    end
    local key, why = K:StorePartnerSnapshot(snapshot, "import")
    if not key then
        K:Print("|cffff5555" .. L["Import failed:"] .. "|r " .. tostring(why))
        return
    end
    K.db.selected = key
    K:Print(L["Imported progress of %s (%d completed quests)."]:format(K:ShortName(key), #(K.db.partners[key].c or {})))
    self.stringDialog:Hide()
    self:Open()
    self:Refresh()
end

------------------------------------------------------------------------
-- Minimap button
------------------------------------------------------------------------
local function UpdateMinimapPosition(button)
    local angle = math.rad(K.db.settings.minimap.angle or 215)
    local radius = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function UI:CreateMinimapButton()
    if self.minimapButton or not Minimap then return end
    local b = CreateFrame("Button", "KetchupMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture(ICON)
    -- round inside the tracking ring, like other minimap buttons
    local mask = b:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    b:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then K.Comm:RequestFromGroup() else UI:Toggle() end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            K.db.settings.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
            UpdateMinimapPosition(self)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self) Ketchup_OnAddonCompartmentEnter(nil, self) end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    self.minimapButton = b
    UpdateMinimapPosition(b)
    self:UpdateMinimapButton()
end

function UI:UpdateMinimapButton()
    if not self.minimapButton then return end
    self.minimapButton:SetShown(not K.db.settings.minimap.hide)
end

------------------------------------------------------------------------
-- Quest log button
------------------------------------------------------------------------
function UI:CreateQuestLogButton()
    if self.questLogButton or not K.db.settings.questLogButton then return end
    -- classic standalone log, or the quest panel of the modern world map
    -- (parented to the panel so the button hides along with the quest list)
    local parent = QuestLogFrame or (WorldMapFrame and QuestMapFrame)
    if not parent then return end

    local b = UI.CreateDetached("Button", "KetchupQuestLogButton", parent, "UIPanelButtonTemplate")
    b:SetSize(80, 20)
    b:SetText("Ketchup")
    local fs = b:GetFontString()
    if fs then Style.SetFont(fs, 12) end
    Style.Apply("Button", b)
    Style.Apply("StateButtonLabel", b)
    self.questLogButton = b

    if parent == QuestLogFrame then
        local close = QuestLogFrameCloseButton or parent.CloseButton
        if close then
            b:SetPoint("RIGHT", close, "LEFT", -4, 0)
            b:SetFrameLevel(close:GetFrameLevel() + 2)
        else
            b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -30, -4)
        end
    else
        -- The map's title bar differs per layout (default vs. Leatrix Maps, which
        -- moves the close/maximize buttons and the search box into its own bar),
        -- so re-place the button every time the map is shown or resized.
        local function place() UI:PlaceMapButton() end
        local function placeSoon()
            place()
            C_Timer.After(0, place)   -- after other addons re-laid the map out
            C_Timer.After(0.3, place)
        end
        WorldMapFrame:HookScript("OnShow", placeSoon)
        WorldMapFrame:HookScript("OnSizeChanged", placeSoon)
        QuestMapFrame:HookScript("OnShow", placeSoon)
        place()
    end
    b:SetScript("OnClick", function() UI:Toggle() end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Ketchup", 1, 1, 1)
        GameTooltip:AddLine(L["Compare quest progress with your partner."], nil, nil, nil, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
end

-- World map placement:
--  * search box in the title bar (Leatrix Maps): left of the search box,
--    in the empty middle of that bar
--  * default map: left of the maximize/minimize button
--  * otherwise: left of the close button, or the panel's top-right corner
function UI:PlaceMapButton()
    local b = self.questLogButton
    if not b or not WorldMapFrame then return end
    local border = WorldMapFrame.BorderFrame
    local close = border and border.CloseButton
    local maxmin = border and (border.MaximizeMinimizeFrame or border.MaxMinButtonFrame)
    local search = QuestScrollFrame and QuestScrollFrame.SearchBox

    local function centerY(f)
        if not f or not f:IsVisible() then return nil end
        local _, y = f:GetCenter()
        return y
    end
    local closeY, searchY = centerY(close), centerY(search)

    b:ClearAllPoints()
    if closeY and searchY and math.abs(closeY - searchY) < 12 then
        b:SetPoint("RIGHT", search, "LEFT", -10, 0)
    elseif centerY(maxmin) then
        b:SetPoint("RIGHT", maxmin, "LEFT", -4, 0)
    elseif closeY then
        b:SetPoint("RIGHT", close, "LEFT", -4, 0)
    else
        b:SetPoint("TOPRIGHT", b:GetParent(), "TOPRIGHT", -30, -4)
    end

    -- stay above whatever title bar the buttons were moved into
    local level = b:GetParent():GetFrameLevel()
    for _, f in ipairs({ close, maxmin, search }) do
        if f and f.GetFrameLevel then level = math.max(level, f:GetFrameLevel()) end
    end
    b:SetFrameLevel(level + 3)
end

------------------------------------------------------------------------
-- Quest log sync markers
------------------------------------------------------------------------
-- WoW Forever's gamepad navigation hooks CreateFrame: creating a frame whose
-- parent sits inside an open panel (like the quest log) taints that panel.
-- SetParent is not hooked, so create detached and re-parent.
function UI.CreateDetached(frameType, name, parent, template)
    local frame = CreateFrame(frameType, name, nil, template)
    frame:SetParent(parent)
    return frame
end

-- Catch-up: the credits screen's fast-forward ">>" atlas, tinted orange.
local CATCHUP_ATLAS = "creditsscreen-assets-buttons-fastforward"
local CATCHUP_RGB = { 255, 165, 38 }

local MARKERS = {
    together = { tex = "Interface\\RaidFrame\\ReadyCheck-Ready" },    -- partner has the quest too
    ahead    = { tex = "Interface\\RaidFrame\\ReadyCheck-Ready" },    -- ...and I'm further along (tooltip says so)
    catchup  = { atlas = CATCHUP_ATLAS, rgb = CATCHUP_RGB },          -- partner already turned it in
    none     = { tex = "Interface\\RaidFrame\\ReadyCheck-NotReady" }, -- partner doesn't have it
}

-- Inline markup for the catch-up icon at a given pixel size.
local function CatchupMarkup(size)
    return ("|A:%s:%d:%d:0:0:%d:%d:%d|a"):format(CATCHUP_ATLAS, size, size,
        CATCHUP_RGB[1], CATCHUP_RGB[2], CATCHUP_RGB[3])
end

-- Adds the Ketchup sync lines for a quest to GameTooltip. Returns false if
-- there is nothing to say (no partner selected).
local function AddSyncLines(questID, asSection)
    local status, pq, mine, key = K:GetSyncStatus(questID)
    if not status then return false end
    local who = K:ShortName(key)
    local p = K:GetPartner(key)
    if asSection then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Ketchup", 1, 0.55, 0.3)
    else
        GameTooltip:SetText("Ketchup", 1, 1, 1)
    end
    if status == "catchup" then
        if pq then -- still in their log, every objective done
            GameTooltip:AddLine(L["%s has completed all objectives but hasn't turned it in yet."]:format(who), 1, 0.65, 0.15, true)
        else
            GameTooltip:AddLine(L["%s already turned this in."]:format(who), 1, 0.65, 0.15, true)
        end
        GameTooltip:AddLine(L["Do it to catch up."], 1, 1, 1, true)
    elseif status == "together" then
        GameTooltip:AddLine(L["%s has this quest too."]:format(who), 0.2, 1, 0.2, true)
        GameTooltip:AddLine(L["Do it together."], 1, 1, 1, true)
    elseif status == "ahead" then
        GameTooltip:AddLine(L["%s has this quest too, but you're further along."]:format(who), 0.2, 1, 0.2, true)
        GameTooltip:AddLine(L["Wait for them to catch up."], 1, 1, 1, true)
    else
        GameTooltip:AddLine(L["%s doesn't have this quest."]:format(who), 1, 0.3, 0.3, true)
        GameTooltip:AddLine(L["Doing it puts you ahead of them."], 1, 1, 1, true)
    end
    if pq then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["%s's progress:"]:format(who), 0.4, 0.8, 1)
        if pq.c == 1 then GameTooltip:AddLine("  " .. L["Ready to turn in"], 0.2, 1, 0.2) end
        for j, o in ipairs(pq.o or {}) do
            local mo = mine and mine.o[j]
            local text = o.t ~= "" and o.t or (o.h .. "/" .. o.n)
            if mo then
                GameTooltip:AddDoubleLine("  " .. text, L["you %d/%d"]:format(mo.h, mo.n), 1, 1, 1, 1, 0.82, 0)
            else
                GameTooltip:AddLine("  " .. text, 1, 1, 1)
            end
        end
    end
    GameTooltip:AddLine(L["Their data is from %s."]:format(p and Ago(p.ts) or "?"), 0.6, 0.6, 0.6)
    return true
end

local function MarkerTooltip(marker)
    if not marker.questID then return end
    GameTooltip:SetOwner(marker, "ANCHOR_RIGHT")
    if AddSyncLines(marker.questID, false) then GameTooltip:Show() else GameTooltip:Hide() end
end

-- Hovering a row of the modern quest log: append to the client's own tooltip.
local function OnQuestRowEnter(row)
    if not (K.db and K.db.settings.questLogMarkers) or not row.questID then return end
    pcall(function()
        if GameTooltip:GetOwner() ~= row or not GameTooltip:IsShown() then
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            if not AddSyncLines(row.questID, false) then return GameTooltip:Hide() end
        elseif not AddSyncLines(row.questID, true) then
            return
        end
        GameTooltip:Show()
    end)
end

local function GetMarker(button)
    if button.ketchupMarker then return button.ketchupMarker end
    local m = UI.CreateDetached("Frame", nil, button)
    m:SetSize(14, 14)
    m:SetFrameLevel(button:GetFrameLevel() + 3)
    m:EnableMouse(true)
    if m.SetPropagateMouseClicks then m:SetPropagateMouseClicks(true) end
    m.icon = m:CreateTexture(nil, "OVERLAY")
    m.icon:SetAllPoints()
    m:SetScript("OnEnter", MarkerTooltip)
    m:SetScript("OnLeave", GameTooltip_Hide)
    m:Hide()
    button.ketchupMarker = m
    return m
end

------------------------------------------------------------------------
-- Modern map-attached quest log (what WoW Forever draws): pooled title rows
-- in QuestScrollFrame.titleFramePool, each with .questID and .Text. There is
-- no room on the row for an extra frame (Spoken's play button and the tag /
-- track checkbox use both ends), so the icon goes inline at the start of the
-- title text, like ForeverQuestTint does with its marker.
------------------------------------------------------------------------
local ICON_PATTERNS = {
    "|TInterface\\RaidFrame\\ReadyCheck%-%a+[^|]*|t ?",
    "|A:creditsscreen%-assets%-buttons%-fastforward[^|]*|a ?", -- catch-up ">>"
    -- markers of older Ketchup versions, so a stale one never sticks
    "|cffffa526\194\187|r ?",
    "|TInterface\\COMMON\\Indicator%-Gray[^|]*|t ?",
    "|cff8a8a89%-|r ?",
}
local function StripIcons(text)
    for _, pattern in ipairs(ICON_PATTERNS) do
        text = text:gsub(pattern, "")
    end
    return text
end

-- size: pixel size for atlas icons (textures use the font height via ":0")
local function InlineIcon(status, size)
    local style = MARKERS[status]
    if not style then return "" end
    if style.atlas then return CatchupMarkup(size or 14) .. " " end
    return "|T" .. style.tex .. ":0|t "
end

local titleToID, titleSource = {}, nil
local function QuestIDForTitle(text)
    local log = K.lastMyLog
    if log and log ~= titleSource then
        titleSource = log
        titleToID = {}
        for id, q in pairs(log) do
            if q.t and q.t ~= "" then titleToID[q.t] = id end
        end
    end
    return titleToID[text]
end

local function MarkTitle(fs, questID)
    local cur = fs:GetText()
    if not cur or cur == "" then return end
    local base = StripIcons(cur)
    local status = K.db and K.db.settings.questLogMarkers and questID and K:GetSyncStatus(questID)
    local _, fontSize = fs:GetFont()
    local size = math.floor((fontSize or 12) + 2) -- same size as in the picked preview
    local new = status and MARKERS[status] and (InlineIcon(status, size) .. base) or base
    if new ~= cur then
        fs.ketchupSetting = true
        fs:SetText(new)
        fs.ketchupSetting = nil
    end
end

-- Runs right after the client sets a row's title, before it measures the
-- row's height, so the icon is part of the layout instead of overflowing it.
local function OnTitleSetText(fs)
    if fs.ketchupSetting then return end
    local ok = pcall(function()
        local row = fs:GetParent()
        local base = StripIcons(fs:GetText() or "")
        -- a recycled row may still carry the previous quest's ID: prefer the title
        local questID = QuestIDForTitle(base) or (row and row.questID)
        MarkTitle(fs, questID)
    end)
    if not ok then fs.ketchupSetting = nil end
end

local hookedTitles = setmetatable({}, { __mode = "k" })
local function HookPoolTitles(pool)
    for row in pool:EnumerateActive() do
        if row.Text and not hookedTitles[row.Text] then
            hookedTitles[row.Text] = true
            hooksecurefunc(row.Text, "SetText", OnTitleSetText)
            if row.HookScript then row:HookScript("OnEnter", OnQuestRowEnter) end
        end
    end
end

local function ModernPool()
    return QuestScrollFrame and QuestScrollFrame.titleFramePool
        and QuestScrollFrame.titleFramePool.EnumerateActive and QuestScrollFrame.titleFramePool
end

local function UpdateModernMarkers()
    local pool = ModernPool()
    if not pool then return end
    HookPoolTitles(pool)
    for row in pool:EnumerateActive() do
        if row.Text then pcall(MarkTitle, row.Text, row.questID) end
    end
end

local function QuestLogOffset()
    if QuestLogListScrollFrame and FauxScrollFrame_GetOffset then
        return FauxScrollFrame_GetOffset(QuestLogListScrollFrame) or 0
    end
    return 0
end

local function QuestIDAt(index)
    if GetQuestLogTitle then
        local _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(index)
        if isHeader then return nil end
        return questID
    end
    local info = C_QuestLog.GetInfo(index)
    return info and not info.isHeader and info.questID or nil
end

function UI:UpdateQuestLogMarkers()
    UpdateModernMarkers()
    if not QuestLogFrame or not QUESTS_DISPLAYED then return end
    local enabled = K.db and K.db.settings.questLogMarkers and QuestLogFrame:IsShown()
    local numEntries = GetNumQuestLogEntries and GetNumQuestLogEntries() or C_QuestLog.GetNumQuestLogEntries()
    local offset = QuestLogOffset()
    for i = 1, QUESTS_DISPLAYED do
        local button = _G["QuestLogTitle" .. i]
        if button then
            local questID
            local index = i + offset
            if enabled and button:IsShown() and index <= numEntries then
                questID = QuestIDAt(index)
            end
            local status = questID and K:GetSyncStatus(questID)
            local style = status and MARKERS[status]
            if style then
                local m = GetMarker(button)
                m.questID = questID
                if style.atlas then
                    m.icon:SetAtlas(style.atlas)
                    m.icon:SetVertexColor(style.rgb[1] / 255, style.rgb[2] / 255, style.rgb[3] / 255)
                else
                    m.icon:SetTexture(style.tex)
                    m.icon:SetVertexColor(1, 1, 1)
                end
                -- keep clear of the "(Complete)" / "Elite" tag on the right
                local tag = _G["QuestLogTitle" .. i .. "Tag"]
                local pad = 4
                if tag and tag:IsShown() and (tag:GetText() or "") ~= "" then
                    pad = pad + tag:GetStringWidth() + 4
                end
                m:ClearAllPoints()
                m:SetPoint("RIGHT", button, "RIGHT", -pad, 0)
                m:Show()
            elseif button.ketchupMarker then
                button.ketchupMarker.questID = nil
                button.ketchupMarker:Hide()
            end
        end
    end
end

function UI:HookQuestLog()
    if self.questLogHooked then return end
    local pool = ModernPool()
    if type(QuestLogQuests_Update) == "function" and pool then
        -- modern map-attached quest log (WoW Forever)
        self.questLogHooked = "modern"
        HookPoolTitles(pool)
        -- rows handed out later get hooked before their title is set
        pcall(hooksecurefunc, pool, "Acquire", function() HookPoolTitles(pool) end)
        hooksecurefunc("QuestLogQuests_Update", function() UpdateModernMarkers() end)
    elseif type(QuestLog_Update) == "function" then
        -- classic standalone quest log
        self.questLogHooked = "classic"
        hooksecurefunc("QuestLog_Update", function() UI:UpdateQuestLogMarkers() end)
        if QuestLogFrame then
            QuestLogFrame:HookScript("OnShow", function() UI:UpdateQuestLogMarkers() end)
        end
    end
end

------------------------------------------------------------------------
-- Init & addon compartment
------------------------------------------------------------------------
function UI:Init()
    self:CreateMinimapButton()
    self:CreateQuestLogButton()
    self:HookQuestLog()
    if not self.questLogButton or not self.questLogHooked then
        -- Quest log may be load-on-demand or created later by another addon.
        local f = CreateFrame("Frame")
        f:RegisterEvent("ADDON_LOADED")
        f:SetScript("OnEvent", function(self)
            UI:CreateQuestLogButton()
            UI:HookQuestLog()
            if UI.questLogButton and UI.questLogHooked then self:UnregisterAllEvents() end
        end)
    end
end

function Ketchup_OnAddonCompartmentClick(_, mouse)
    if mouse == "RightButton" then K.Comm:RequestFromGroup() else UI:Toggle() end
end

function Ketchup_OnAddonCompartmentEnter(_, owner)
    GameTooltip:SetOwner(owner or UIParent, "ANCHOR_LEFT")
    GameTooltip:SetText("Ketchup", 1, 1, 1)
    local n = 0
    for _ in pairs(K.db and K:VisiblePartners() or {}) do n = n + 1 end
    GameTooltip:AddLine(L["%d partner(s) saved"]:format(n), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffd100" .. L["Left-click"] .. "|r " .. L["open window"], 1, 1, 1)
    GameTooltip:AddLine("|cffffd100" .. L["Right-click"] .. "|r " .. L["sync with group"], 1, 1, 1)
    GameTooltip:AddLine("|cffffd100" .. L["Drag"] .. "|r " .. L["move button"], 1, 1, 1)
    GameTooltip:Show()
end

function Ketchup_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
