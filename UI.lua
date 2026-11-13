-- Ketchup: user interface (main window, export/import dialog, minimap & quest log buttons).
local _, ns = ...
local K = ns.K
local S = ns.Serialize

local UI = {}
K.UI = UI

local ICON = "Interface\\Icons\\INV_Potion_49"
local TABS = {
    { key = "completed", label = "Done by them, not you" },
    { key = "log",       label = "Their quest log" },
    { key = "ahead",     label = "You're behind on" },
}

local LOG_STATUS = {
    missing = "|cffff9933not in your log|r",
    even    = "|cff20ff20in sync|r",
    myahead = "|cff20ff20you're ahead|r",
    done    = "|cff888888you already turned it in|r",
}
local currentTab = "completed"
local transfers = {} -- [key] = "got/n"

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------
local function Ago(ts)
    if not ts or ts == 0 then return "never" end
    local d = time() - ts
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. " min ago" end
    if d < 86400 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " d ago"
end

local function SetTitle(frame, text)
    if frame.TitleText then
        frame.TitleText:SetText(text)
    else
        if not frame.KetchupTitle then
            frame.KetchupTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            frame.KetchupTitle:SetPoint("TOP", 0, -5)
        end
        frame.KetchupTitle:SetText(text)
    end
end

local function MakeButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 120, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeCheck(parent, label, tooltip, get, set)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", c, "RIGHT", 0, 1)
    fs:SetText(label)
    c.label = fs
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    if tooltip then
        c:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", GameTooltip_Hide)
    end
    c:SetChecked(get())
    return c
end

local function CreateList(parent, extent, initializer)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(extent)
    view:SetElementInitializer("Button", initializer)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    return box, bar
end

local function SetRows(box, rows)
    local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
    box:SetDataProvider(CreateDataProvider(rows), retain)
end

local function ObjectiveSummary(q)
    if not q then return "" end
    if q.c == 1 then return "|cff20ff20ready to turn in|r" end
    local done, total = 0, 0
    for _, o in ipairs(q.o or {}) do
        total = total + 1
        if o.f == 1 then done = done + 1 end
    end
    if total == 0 then return "" end
    return ("%d/%d objectives"):format(done, total)
end

local function AheadSummary(e)
    local pq, mq = e.partnerQuest, e.myQuest
    if not pq or not mq then return "" end
    if pq.c == 1 and mq.c ~= 1 then return "|cff20ff20they can turn it in|r" end
    for j, po in ipairs(pq.o or {}) do
        local mo = mq.o and mq.o[j]
        if mo and po.h > mo.h then
            return ("them %d/%d  |cffaaaaaa·|r  you %d/%d"):format(po.h, po.n, mo.h, mo.n)
        end
    end
    return ""
end

------------------------------------------------------------------------
-- Main window
------------------------------------------------------------------------
function UI:Create()
    if self.frame then return end

    local f = CreateFrame("Frame", "KetchupFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(860, 520)
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
    SetTitle(f, "Ketchup - quest catch-up")
    self.frame = f

    -- Left column: partners -------------------------------------------
    local left = CreateFrame("Frame", nil, f)
    left:SetPoint("TOPLEFT", 14, -32)
    left:SetPoint("BOTTOMLEFT", 14, 12)
    left:SetWidth(210)

    local lh = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lh:SetPoint("TOPLEFT", 2, 0)
    lh:SetText("Partners")

    local partnerBox = CreateList(left, 38, function(button, data) UI:InitPartnerRow(button, data) end)
    partnerBox:SetPoint("TOPLEFT", 0, -18)
    partnerBox:SetPoint("TOPRIGHT", -14, -18)
    partnerBox:SetHeight(270)
    self.partnerBox = partnerBox

    local emptyPartners = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyPartners:SetPoint("TOPLEFT", partnerBox, "TOPLEFT", 4, -6)
    emptyPartners:SetPoint("RIGHT", partnerBox, "RIGHT", -4, 0)
    emptyPartners:SetJustifyH("LEFT")
    emptyPartners:SetText("No partner data yet.\n\nGroup up with your friend (both need Ketchup), or import their string.")
    self.emptyPartners = emptyPartners

    local y = -296
    local function addButton(text, onClick, tip)
        local b = MakeButton(left, text, 196, onClick)
        b:SetPoint("TOPLEFT", 0, y)
        if tip then
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(text, 1, 1, 1)
                GameTooltip:AddLine(tip, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", GameTooltip_Hide)
        end
        y = y - 25
        return b
    end
    addButton("Sync with group", function() K.Comm:RequestFromGroup() end,
        "Ask every group member running Ketchup for their current progress, and send yours.")
    addButton("Export my progress", function() UI:ShowExport() end,
        "Create a string with your quest progress that you can paste to your partner over any messenger.")
    addButton("Import string", function() UI:ShowImport() end,
        "Paste a string your partner exported.")
    self.removeButton = addButton("Remove selected partner", function()
        local key = K.db.selected
        if key then
            StaticPopup_Show("KETCHUP_REMOVE_PARTNER", K:ShortName(key), nil, key)
        end
    end)

    local auto = MakeCheck(left, "Auto-share while grouped",
        "Automatically send your progress to group members running Ketchup whenever your quests change.",
        function() return K.db.settings.autoShare end,
        function(v) K.db.settings.autoShare = v; if v then K:ScheduleShare(1, true) end end)
    auto:SetPoint("TOPLEFT", -2, y - 4)

    local markers = MakeCheck(left, "Sync icons in quest log",
        "Show an icon per quest in your quest log:\n|cff20ff20check|r = partner turned it in, do it to catch up\n"
        .. "|cffffd100?|r = partner has it active, do it together\n|cffff3333X|r = you're ahead of your partner\n"
        .. "grey = partner doesn't have it",
        function() return K.db.settings.questLogMarkers end,
        function(v) K.db.settings.questLogMarkers = v; UI:UpdateQuestLogMarkers() end)
    markers:SetPoint("TOPLEFT", auto, "BOTTOMLEFT", 0, 2)

    local warn = MakeCheck(left, "Warn on their active quests",
        "Show an on-screen warning when you make progress on a quest your partner has active "
        .. "while they're not in your group.",
        function() return K.db.settings.warnProgress end,
        function(v) K.db.settings.warnProgress = v end)
    warn:SetPoint("TOPLEFT", markers, "BOTTOMLEFT", 0, 2)

    -- Right column: diff -----------------------------------------------
    local right = CreateFrame("Frame", nil, f)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 14, 0)
    right:SetPoint("BOTTOMRIGHT", -14, 12)
    self.right = right

    local header = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    header:SetPoint("TOPLEFT", 2, 0)
    header:SetJustifyH("LEFT")
    self.header = header

    local sub = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    sub:SetPoint("RIGHT", right, "RIGHT", 0, 0)
    sub:SetJustifyH("LEFT")
    self.sub = sub

    self.tabButtons = {}
    local prev
    for _, tab in ipairs(TABS) do
        local b = MakeButton(right, tab.label, 190, function()
            currentTab = tab.key
            UI:RebuildRows()
        end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 0, -56) end
        b.tabKey = tab.key
        b.baseLabel = tab.label
        self.tabButtons[#self.tabButtons + 1] = b
        prev = b
    end

    local search = CreateFrame("EditBox", nil, right, "SearchBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPLEFT", 6, -86)
    search:HookScript("OnTextChanged", function() UI:RebuildRows() end)
    self.search = search

    local doable = MakeCheck(right, "Only quests I can do now",
        "Uses Questie to hide quests you don't have yet and can't pick up yet (level, race/class, missing prerequisite).",
        function() return K.db.settings.onlyDoable end,
        function(v) K.db.settings.onlyDoable = v; UI:RebuildRows() end)
    doable:SetPoint("LEFT", search, "RIGHT", 10, 0)
    self.doableCheck = doable

    local hideLog = MakeCheck(right, "Hide quests in my log",
        "On the 'Done by them, not you' tab: hide quests you already have in your quest log.",
        function() return K.db.settings.hideInMyLog end,
        function(v) K.db.settings.hideInMyLog = v; UI:RebuildRows() end)
    hideLog:SetPoint("LEFT", doable.label, "RIGHT", 10, -1)

    local showIgn = MakeCheck(right, "Show ignored",
        "Right-click a quest to ignore it (e.g. class quests you can't do).",
        function() return K.db.settings.showIgnored end,
        function(v) K.db.settings.showIgnored = v; UI:RebuildRows() end)
    showIgn:SetPoint("LEFT", hideLog.label, "RIGHT", 10, 0)

    local questBox = CreateList(right, 20, function(button, data) UI:InitQuestRow(button, data) end)
    questBox:SetPoint("TOPLEFT", 0, -112)
    questBox:SetPoint("BOTTOMRIGHT", -16, 18)
    self.questBox = questBox

    local empty = right:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOP", questBox, "TOP", 0, -40)
    self.emptyQuests = empty

    local hint = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 2, 0)
    hint:SetText("Hover for details  ·  Shift-click: link in chat  ·  Right-click: ignore / unignore")
end

function UI:InitPartnerRow(button, data)
    if not button.ketchupInit then
        button.ketchupInit = true
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local sel = button:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints()
        sel:SetColorTexture(1, 0.6, 0.1, 0.18)
        button.sel = sel
        button.name = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        button.name:SetPoint("TOPLEFT", 16, -4)
        button.name:SetPoint("RIGHT", -4, 0)
        button.name:SetJustifyH("LEFT")
        button.info = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        button.info:SetPoint("TOPLEFT", button.name, "BOTTOMLEFT", 0, -3)
        button.info:SetPoint("RIGHT", -4, 0)
        button.info:SetJustifyH("LEFT")
        button.dot = button:CreateTexture(nil, "OVERLAY")
        button.dot:SetSize(8, 8)
        button.dot:SetPoint("LEFT", 4, 6)
        button.dot:SetColorTexture(0.2, 1, 0.2, 1)
        button:SetScript("OnClick", function(self)
            K.db.selected = self.key
            UI:Refresh()
        end)
    end
    local p = data.partner
    button.key = data.key
    button.sel:SetShown(K.db.selected == data.key)
    button.name:SetText(K:ClassColored(K:ShortName(data.key), p.cl))
    local online = K:IsPartnerOnline(data.key)
    button.dot:SetShown(online)
    local t = transfers[data.key]
    if t then
        button.info:SetText("receiving " .. t .. " ...")
    else
        button.info:SetText(("Lv %d · %s%s"):format(p.lv or 0, Ago(p.ts), p.source == "import" and " · import" or ""))
    end
end

function UI:InitQuestRow(button, data)
    if not button.ketchupInit then
        button.ketchupInit = true
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        button.hl = hl
        button.left = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        button.left:SetPoint("LEFT", 6, 0)
        button.left:SetJustifyH("LEFT")
        button.right = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.right:SetPoint("RIGHT", -6, 0)
        button.right:SetJustifyH("RIGHT")
        button.left:SetPoint("RIGHT", button.right, "LEFT", -8, 0)
        button:SetScript("OnClick", function(self, mouse) UI:OnQuestClick(self.data, mouse) end)
        button:SetScript("OnEnter", function(self) UI:ShowQuestTooltip(self, self.data) end)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end
    button.data = data
    if data.header then
        button.hl:Hide()
        button.left:SetFontObject("GameFontNormal")
        button.left:SetText(data.text .. "  |cff888888(" .. data.count .. ")|r")
        button.right:SetText("")
        return
    end
    button.hl:Show()
    button.left:SetFontObject("GameFontHighlight")
    local e = data.entry
    local lvl = e.level and e.level > 0 and ("[" .. e.level .. "] ") or ""
    local color = ""
    if e.level and e.level > 0 and GetQuestDifficultyColor then
        local c = GetQuestDifficultyColor(e.level)
        color = ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
    end
    local title = "    " .. color .. lvl .. e.title .. (color ~= "" and "|r" or "")
    if e.ignored then title = "    |cff777777" .. lvl .. e.title .. " (ignored)|r" end
    button.left:SetText(title)

    local status = ""
    if currentTab == "completed" then
        if e.inMyLog then status = "|cffffd100in your log|r" end
    elseif currentTab == "log" then
        if e.status == "behind" then
            status = "|cffff9933behind:|r " .. AheadSummary(e)
        elseif e.status == "missing" then
            local summary = ObjectiveSummary(e.partnerQuest)
            status = LOG_STATUS.missing .. (summary ~= "" and ("  |cffaaaaaa·|r  them " .. summary) or "")
        else
            status = LOG_STATUS[e.status] or ""
        end
    else
        status = AheadSummary(e)
    end
    button.right:SetText(status)
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
    if q.c == 1 then tt:AddLine("  Ready to turn in", 0.2, 1, 0.2) end
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
    GameTooltip:AddDoubleLine("Quest ID", e.id, 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Zone", e.zone, 0.7, 0.7, 0.7, 1, 1, 1)
    if e.level then GameTooltip:AddDoubleLine("Level", e.level, 0.7, 0.7, 0.7, 1, 1, 1) end
    if e.reqLevel then GameTooltip:AddDoubleLine("Required level", e.reqLevel, 0.7, 0.7, 0.7, 1, 1, 1) end
    local doable = K:IsDoable(e.id)
    if doable ~= nil then
        GameTooltip:AddDoubleLine("Available to you now", doable and "yes" or "no", 0.7, 0.7, 0.7,
            doable and 0.2 or 1, doable and 1 or 0.3, doable and 0.2 or 0.3)
    end
    if e.inMyLog then GameTooltip:AddLine("This quest is in your log.", 1, 0.82, 0) end
    local partnerName = K:ShortName(K.db.selected)
    if e.partnerQuest or e.myQuest then GameTooltip:AddLine(" ") end
    AddObjectives(GameTooltip, partnerName .. "'s progress:", e.partnerQuest, 0.4, 0.8, 1)
    AddObjectives(GameTooltip, "Your progress:", e.myQuest, 1, 0.82, 0)
    if e.ignored then GameTooltip:AddLine("Ignored (right-click to unignore)", 0.6, 0.6, 0.6) end
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
    for key, p in pairs(K.db.partners) do
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
    if K.db.selected and not K.db.partners[K.db.selected] then K.db.selected = nil end
    if not K.db.selected then K.db.selected = next(K.db.partners) end
    self:RefreshPartners()

    local key = K.db.selected
    local p = K:GetPartner(key)
    if not p then
        self.header:SetText("Nobody to catch up with yet")
        self.sub:SetText("Join a group with your partner, or import a string they exported.")
        self.diff = nil
    else
        self.header:SetText(K:ClassColored(K:ShortName(key), p.cl))
        local online = K:IsPartnerOnline(key) and "|cff20ff20in your group|r" or "|cff999999not in group - showing saved data|r"
        self.diff = K:ComputeDiff(key)
        self.sub:SetText(("Level %d %s · %d quests completed (%d also by you) · %d in quest log\nData from %s via %s · %s"):format(
            p.lv or 0, p.fa or "", self.diff.completedTotal or 0, self.diff.completedShared or 0, #(p.q or {}),
            Ago(p.ts), p.source == "import" and "import" or "group sync", online))
    end
    self.doableCheck:SetEnabled(K:HasQuestie())
    self.doableCheck.label:SetFontObject(K:HasQuestie() and "GameFontHighlightSmall" or "GameFontDisableSmall")
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
            b:SetText(("%s (%d)"):format(b.baseLabel, n))
        else
            b:SetText(("%s (%d of %d)"):format(b.baseLabel, n, total))
        end
        b:SetWidth(b:GetFontString():GetStringWidth() + 28)
        if b.tabKey == currentTab then b:LockHighlight() else b:UnlockHighlight() end
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
        self.emptyQuests:SetText("")
    elseif #rows == 0 then
        self.emptyQuests:SetText("Nothing here - you're in sync!")
    else
        self.emptyQuests:SetText("")
    end
end

StaticPopupDialogs["KETCHUP_REMOVE_PARTNER"] = {
    text = "Remove the saved quest progress of %s?",
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
    local d = CreateFrame("Frame", "KetchupStringDialog", UIParent, "BasicFrameTemplateWithInset")
    d:SetSize(520, 340)
    d:SetPoint("CENTER", 0, 40)
    d:SetFrameStrata("DIALOG")
    d:SetMovable(true)
    d:EnableMouse(true)
    d:SetClampedToScreen(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:Hide()
    tinsert(UISpecialFrames, "KetchupStringDialog")

    local info = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("TOPLEFT", 16, -32)
    info:SetPoint("RIGHT", -16, 0)
    info:SetJustifyH("LEFT")
    d.info = info

    local scroll = CreateFrame("ScrollFrame", nil, d, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -64)
    scroll:SetPoint("BOTTOMRIGHT", -34, 44)

    local bg = d:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", scroll, -4, 4)
    bg:SetPoint("BOTTOMRIGHT", scroll, 4, -4)
    bg:SetColorTexture(0, 0, 0, 0.5)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(460)
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

    local action = MakeButton(d, "Import", 120, function()
        if d.mode == "import" then
            UI:DoImport(edit:GetText())
        else
            edit:SetFocus()
            edit:HighlightText()
        end
    end)
    action:SetPoint("BOTTOMRIGHT", -16, 14)
    d.action = action

    local close = MakeButton(d, CLOSE or "Close", 100, function() d:Hide() end)
    close:SetPoint("RIGHT", action, "LEFT", -6, 0)

    self.stringDialog = d
    return d
end

function UI:ShowExport()
    local d = self:CreateStringDialog()
    local snapshot = K:BuildSnapshot()
    local text, err = S.ToExportString(snapshot)
    if not text then
        K:Print("Export failed: " .. tostring(err))
        return
    end
    d.mode = "export"
    d.exportText = text
    SetTitle(d, "Ketchup - export my progress")
    d.info:SetText(("Press |cffffd100Ctrl+C|r to copy (%d characters) and send it to your partner. "
        .. "They paste it via |cffffd100Import string|r. %d completed quests, %d quests in log."):format(
        #text, #snapshot.c, #snapshot.q))
    d.action:SetText("Select all")
    d.edit:SetText(text)
    d:Show()
    d.edit:SetFocus()
    d.edit:HighlightText()
end

function UI:ShowImport()
    local d = self:CreateStringDialog()
    d.mode = "import"
    d.exportText = nil
    SetTitle(d, "Ketchup - import partner progress")
    d.info:SetText("Paste the string your partner exported (|cffffd100Ctrl+V|r), then click |cffffd100Import|r.")
    d.action:SetText("Import")
    d.edit:SetText("")
    d:Show()
    d.edit:SetFocus()
end

function UI:DoImport(text)
    local snapshot, err = S.FromExportString(text)
    if not snapshot then
        K:Print("|cffff5555Import failed:|r " .. tostring(err))
        return
    end
    local key, why = K:StorePartnerSnapshot(snapshot, "import")
    if not key then
        K:Print("|cffff5555Import failed:|r " .. tostring(why))
        return
    end
    K.db.selected = key
    K:Print(("Imported progress of %s (%d completed quests)."):format(K:ShortName(key), #(K.db.partners[key].c or {})))
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
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

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
        GameTooltip:AddLine("Compare quest progress with your partner.", nil, nil, nil, true)
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

local MARKERS = {
    catchup  = { tex = "Interface\\RaidFrame\\ReadyCheck-Ready" },
    together = { tex = "Interface\\RaidFrame\\ReadyCheck-Waiting" },
    ahead    = { tex = "Interface\\RaidFrame\\ReadyCheck-NotReady" },
    none     = { tex = "Interface\\RaidFrame\\ReadyCheck-Waiting", grey = true },
}

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
        GameTooltip:AddLine(who .. " already turned this in.", 0.2, 1, 0.2, true)
        GameTooltip:AddLine("Do it to catch up.", 1, 1, 1, true)
    elseif status == "together" then
        GameTooltip:AddLine(who .. " has this quest active.", 1, 0.82, 0, true)
        GameTooltip:AddLine("Stop here and do it together.", 1, 1, 1, true)
    elseif status == "ahead" then
        GameTooltip:AddLine("You're ahead of " .. who .. " on this quest.", 1, 0.3, 0.3, true)
        GameTooltip:AddLine("Stop until they catch up.", 1, 1, 1, true)
    else
        GameTooltip:AddLine(who .. " doesn't have this quest.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Doing it puts you ahead of them.", 0.7, 0.7, 0.7, true)
    end
    if pq then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(who .. "'s progress:", 0.4, 0.8, 1)
        if pq.c == 1 then GameTooltip:AddLine("  Ready to turn in", 0.2, 1, 0.2) end
        for j, o in ipairs(pq.o or {}) do
            local mo = mine and mine.o[j]
            local text = o.t ~= "" and o.t or (o.h .. "/" .. o.n)
            if mo then
                GameTooltip:AddDoubleLine("  " .. text, ("you %d/%d"):format(mo.h, mo.n), 1, 1, 1, 1, 0.82, 0)
            else
                GameTooltip:AddLine("  " .. text, 1, 1, 1)
            end
        end
    end
    GameTooltip:AddLine(("Their data is from %s."):format(p and Ago(p.ts) or "?"), 0.6, 0.6, 0.6)
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
    "|TInterface\\COMMON\\Indicator%-Gray[^|]*|t ?",
    "|cff8a8a89%-|r ?", -- fallback marker for "none"
}
local function StripIcons(text)
    for _, pattern in ipairs(ICON_PATTERNS) do
        text = text:gsub(pattern, "")
    end
    return text
end

-- "none" gets a grey dot so it can't be confused with the yellow "?" of "together".
local noneIcon
local function NoneIcon()
    if not noneIcon then
        local path = "Interface\\COMMON\\Indicator-Gray"
        if GetFileIDFromPath and GetFileIDFromPath(path) then
            noneIcon = "|T" .. path .. ":0|t "
        else
            noneIcon = "|cff8a8a89-|r "
        end
    end
    return noneIcon
end

local function InlineIcon(status)
    local style = MARKERS[status]
    if not style then return "" end
    if status == "none" then return NoneIcon() end
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
    local new = status and MARKERS[status] and (InlineIcon(status) .. base) or base
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
                m.icon:SetTexture(style.tex)
                m.icon:SetDesaturated(style.grey and true or false)
                m.icon:SetAlpha(style.grey and 0.5 or 1)
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

-- Prints diagnostics, stores them in KetchupDB.debugLog (readable from the
-- SavedVariables file after /reload) and takes a screenshot.
function UI:DebugQuestLog()
    local lines = {}
    local function out(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, " ")
        lines[#lines + 1] = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        K:Print(line)
    end
    local function yn(v) return v and "|cff20ff20yes|r" or "|cffff5555no|r" end

    out("QuestLogFrame:", yn(QuestLogFrame), " QuestLog_Update:", yn(type(QuestLog_Update) == "function"))
    out("QuestMapFrame:", yn(QuestMapFrame), " shown:", yn(QuestMapFrame and QuestMapFrame:IsVisible()),
        " WorldMapFrame shown:", yn(WorldMapFrame and WorldMapFrame:IsShown()))
    out("QuestScrollFrame:", yn(QuestScrollFrame), " titleFramePool:", yn(ModernPool()),
        " QuestLogQuests_Update:", yn(type(QuestLogQuests_Update) == "function"))
    out("hooked:", tostring(self.questLogHooked), " markers on:", yn(K.db.settings.questLogMarkers),
        " partner:", tostring(K.db.selected), " my log cached:", yn(K.lastMyLog))
    local pool = ModernPool()
    if pool then
        local n = 0
        for row in pool:EnumerateActive() do
            n = n + 1
            local status = row.questID and K:GetSyncStatus(row.questID)
            local text = row.Text and row.Text:GetText()
            if n <= 6 then
                out(("  row %d: questID=%s status=%s text=%s"):format(n, tostring(row.questID),
                    tostring(status), tostring(text)))
            else
                lines[#lines + 1] = ("  row %d: questID=%s status=%s text=%s"):format(n, tostring(row.questID),
                    tostring(status), tostring(text))
            end
        end
        out("active rows:", n, "(open the quest log first if 0)")
    end
    -- frame layout around the quest log, for placing the Ketchup button
    local function geo(name, f)
        if f and f.GetRect then
            local l, b, w, h = f:GetRect()
            lines[#lines + 1] = ("%s rect: left=%s bottom=%s w=%s h=%s shown=%s"):format(name,
                tostring(l), tostring(b), tostring(w), tostring(h), tostring(f:IsShown()))
        end
    end
    geo("WorldMapFrame", WorldMapFrame)
    geo("WorldMapFrame.BorderFrame", WorldMapFrame and WorldMapFrame.BorderFrame)
    geo("QuestMapFrame", QuestMapFrame)
    geo("QuestScrollFrame", QuestScrollFrame)
    geo("KetchupQuestLogButton", self.questLogButton)
    local border = WorldMapFrame and WorldMapFrame.BorderFrame
    geo("BorderFrame.CloseButton", border and border.CloseButton)
    geo("BorderFrame.MaximizeMinimizeFrame", border and border.MaximizeMinimizeFrame)
    geo("QuestScrollFrame.SearchBox", QuestScrollFrame and QuestScrollFrame.SearchBox)
    if QuestMapFrame then
        for k, v in pairs(QuestMapFrame) do
            if type(v) == "table" and v.GetObjectType and v.GetRect then geo("QuestMapFrame." .. tostring(k), v) end
        end
    end

    lines[#lines + 1] = "time: " .. date("%Y-%m-%d %H:%M:%S")
    K.db.debugLog = lines
    K:Print("Saved debug info. Taking a screenshot...")
    C_Timer.After(0.5, function()
        if Screenshot then pcall(Screenshot) end
    end)
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
    for _ in pairs(K.db and K.db.partners or {}) do n = n + 1 end
    GameTooltip:AddLine(("%d partner(s) saved"):format(n), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffd100Left-click|r open window", 1, 1, 1)
    GameTooltip:AddLine("|cffffd100Right-click|r sync with group", 1, 1, 1)
    GameTooltip:AddLine("|cffffd100Drag|r move button", 1, 1, 1)
    GameTooltip:Show()
end

function Ketchup_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
