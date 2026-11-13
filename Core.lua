-- Ketchup: core state, quest snapshots, diffing and events.
local ADDON, ns = ...

local K = {}
ns.K = K
_G.Ketchup = K

K.ADDON = ADDON
K.PROTOCOL = 1
K.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"

local DEFAULTS = {
    partners = {},  -- [ "Name-Realm" ] = snapshot (see BuildSnapshot) + meta
    ignored = {},   -- [ questID ] = true, hidden from all lists unless "show ignored"
    selected = nil, -- currently selected partner key
    settings = {
        autoShare = true,        -- broadcast my progress to group members running Ketchup
        onlyDoable = false,      -- Questie: only show quests I can currently pick up
        hideInMyLog = false,     -- hide "completed" entries that are already in my log
        showIgnored = false,
        minimap = { hide = false, angle = 215 },
        questLogButton = true,
        questLogMarkers = true,  -- sync status icons in the quest log
        warnProgress = true,     -- warn when I progress a quest my partner has active
    },
}

local function ApplyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ApplyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function K:Print(...)
    print("|cffe8463aKetchup|r:", ...)
end

------------------------------------------------------------------------
-- Identity helpers
------------------------------------------------------------------------
function K:MyRealm()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or ""):gsub("%s+", "")
end

function K:NormalizeName(name)
    if not name or name == "" then return nil end
    if not name:find("-", 1, true) then
        name = name .. "-" .. self:MyRealm()
    end
    return name
end

function K:PlayerKey()
    local name, realm = UnitFullName("player")
    if not realm or realm == "" then realm = self:MyRealm() end
    return name .. "-" .. realm
end

function K:ShortName(key)
    if not key then return "?" end
    local name, realm = key:match("^([^-]+)-(.+)$")
    if name and realm == self:MyRealm() then return name end
    return key
end

function K:ClassColored(text, classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then
        return ("|cff%02x%02x%02x%s|r"):format(c.r * 255, c.g * 255, c.b * 255, text)
    end
    return text
end

------------------------------------------------------------------------
-- Snapshot of my own quest state
------------------------------------------------------------------------
local function GetMyCompletedList()
    local list = {}
    if C_QuestLog.GetAllCompletedQuestIDs then
        for _, id in ipairs(C_QuestLog.GetAllCompletedQuestIDs() or {}) do
            list[#list + 1] = id
        end
    elseif GetQuestsCompleted then
        for id in pairs(GetQuestsCompleted() or {}) do
            list[#list + 1] = id
        end
    end
    table.sort(list)
    return list
end

function K:IsCompletedByMe(id)
    if C_QuestLog.IsQuestFlaggedCompleted then
        return C_QuestLog.IsQuestFlaggedCompleted(id) and true or false
    end
    return IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(id) and true or false
end

-- Returns { [questID] = { id, t = title, l = level, c = 0/1, o = { {t,h,n,f}, ... } } }
function K:GetMyLog()
    local log = {}
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden and info.questID and info.questID > 0 then
            local id = info.questID
            local q = { id = id, t = info.title or "", l = info.level or 0, c = C_QuestLog.IsComplete(id) and 1 or 0, o = {} }
            for j, obj in ipairs(C_QuestLog.GetQuestObjectives(id) or {}) do
                q.o[j] = {
                    t = obj.text or "",
                    h = tonumber(obj.numFulfilled) or 0,
                    n = tonumber(obj.numRequired) or 0,
                    f = obj.finished and 1 or 0,
                }
            end
            log[id] = q
        end
    end
    return log
end

-- Compact, serializable snapshot of my progress.
function K:BuildSnapshot()
    local name = UnitName("player")
    local _, class = UnitClass("player")
    local completed = GetMyCompletedList()
    local logMap = self:GetMyLog()
    local log = {}
    for _, q in pairs(logMap) do log[#log + 1] = q end
    table.sort(log, function(a, b) return a.id < b.id end)

    -- signature excludes the timestamp so we can detect "nothing changed"
    local sig = { #completed, completed[#completed] or 0 }
    for _, q in ipairs(log) do
        sig[#sig + 1] = q.id .. ":" .. q.c
        for _, o in ipairs(q.o) do sig[#sig + 1] = o.h end
    end

    return {
        v = K.PROTOCOL,
        n = name,
        r = self:MyRealm(),
        cl = class,
        lv = UnitLevel("player"),
        fa = UnitFactionGroup("player"),
        ts = time(),
        c = completed,
        q = log,
    }, table.concat(sig, ",")
end

------------------------------------------------------------------------
-- Partner storage
------------------------------------------------------------------------
local function SanitizeSnapshot(s)
    if type(s) ~= "table" or type(s.n) ~= "string" or type(s.c) ~= "table" then
        return nil, "malformed snapshot"
    end
    if tonumber(s.v) ~= K.PROTOCOL then
        return nil, "incompatible Ketchup version (protocol " .. tostring(s.v) .. ")"
    end
    local out = {
        v = K.PROTOCOL,
        n = s.n:sub(1, 48),
        r = type(s.r) == "string" and s.r:sub(1, 64) or "",
        cl = type(s.cl) == "string" and s.cl or nil,
        lv = tonumber(s.lv) or 0,
        fa = type(s.fa) == "string" and s.fa or nil,
        ts = tonumber(s.ts) or 0,
        c = {},
        q = {},
    }
    for _, id in ipairs(s.c) do
        id = tonumber(id)
        if id and id > 0 then out.c[#out.c + 1] = id end
    end
    if type(s.q) == "table" then
        for _, q in ipairs(s.q) do
            if type(q) == "table" and tonumber(q.id) then
                local nq = { id = tonumber(q.id), t = tostring(q.t or ""):sub(1, 128), l = tonumber(q.l) or 0, c = tonumber(q.c) or 0, o = {} }
                if type(q.o) == "table" then
                    for _, o in ipairs(q.o) do
                        if type(o) == "table" then
                            nq.o[#nq.o + 1] = {
                                t = tostring(o.t or ""):sub(1, 160),
                                h = tonumber(o.h) or 0,
                                n = tonumber(o.n) or 0,
                                f = tonumber(o.f) or 0,
                            }
                        end
                    end
                end
                out.q[#out.q + 1] = nq
            end
        end
    end
    return out
end

-- source: "group" or "import". Returns key or nil, reason.
function K:StorePartnerSnapshot(snapshot, source, senderKey)
    local s, err = SanitizeSnapshot(snapshot)
    if not s then return nil, err end
    local key = senderKey or self:NormalizeName(s.r ~= "" and (s.n .. "-" .. s.r) or s.n)
    if key == self:PlayerKey() then
        return nil, "that is your own progress"
    end
    local existing = self.db.partners[key]
    if existing and (existing.ts or 0) > s.ts then
        return nil, "older than the data already stored for " .. self:ShortName(key)
    end
    s.source = source
    s.received = time()
    self.db.partners[key] = s
    self.partnerCache[key] = nil
    if not self.db.selected or not self.db.partners[self.db.selected] then
        self.db.selected = key
    end
    if self.UI then self.UI:Refresh() end
    return key
end

function K:RemovePartner(key)
    self.db.partners[key] = nil
    self.partnerCache[key] = nil
    if self.db.selected == key then self.db.selected = next(self.db.partners) end
    if self.UI then self.UI:Refresh() end
end

function K:GetPartner(key)
    return key and self.db.partners[key]
end

------------------------------------------------------------------------
-- Quest metadata (Questie if available, Blizzard API otherwise)
------------------------------------------------------------------------
K.metaCache = {}
K.partnerCache = {} -- [key] = { completed = set, log = map }

function K:GetQuestieDB()
    if not QuestieLoader or not QuestieLoader.ImportModule then return nil end
    local ok, db = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
    if ok and type(db) == "table" and db.GetQuest then return db end
    return nil
end

function K:HasQuestie()
    local db = self:GetQuestieDB()
    if not db then return false end
    local ok, q = pcall(db.GetQuest, 2) -- probe; Questie may still be initializing
    return ok and q ~= nil
end

local OTHER_ZONE = "Other / Class / Profession"

function K:GetQuestMeta(id, fallbackTitle, fallbackLevel)
    local cached = self.metaCache[id]
    if cached then return cached end

    local meta = { id = id }
    local qdb = self:GetQuestieDB()
    if qdb then
        local ok, q = pcall(qdb.GetQuest, id)
        if ok and type(q) == "table" then
            meta.title = q.name
            meta.level = q.questLevel
            meta.reqLevel = q.requiredLevel
            local z = q.zoneOrSort
            if type(z) == "number" and z > 0 and C_Map and C_Map.GetAreaInfo then
                meta.zone = C_Map.GetAreaInfo(z)
            elseif type(z) == "number" and z < 0 then
                meta.zone = OTHER_ZONE
            end
            meta.questie = true
        end
    end
    if not meta.title then
        meta.title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
        if not meta.title and fallbackTitle and fallbackTitle ~= "" then meta.title = fallbackTitle end
    end
    meta.level = meta.level or fallbackLevel
    meta.zone = meta.zone or "Unknown zone"

    if meta.title then
        self.metaCache[id] = meta
    else
        meta.title = "Quest #" .. id
        if C_QuestLog.RequestLoadQuestByID then C_QuestLog.RequestLoadQuestByID(id) end
    end
    return meta
end

-- true / false, or nil when unknown (no Questie)
function K:IsDoable(id)
    local qdb = self:GetQuestieDB()
    if not qdb or not qdb.IsDoable then return nil end
    local ok, res = pcall(qdb.IsDoable, id)
    if not ok then return nil end
    return res and true or false
end

------------------------------------------------------------------------
-- Diff: what is the partner ahead on?
------------------------------------------------------------------------
-- Returns { completed = {...}, log = {...}, ahead = {...} }, each a list of entries:
-- { id, title, level, zone, inMyLog, partnerQuest, myQuest }
function K:ComputeDiff(key)
    local p = self:GetPartner(key)
    local result = { completed = {}, log = {}, ahead = {} }
    if not p then return result end

    local myLog = self:GetMyLog()
    local partnerLogged = {}
    for _, q in ipairs(p.q or {}) do partnerLogged[q.id] = q end

    local function entry(id, pq)
        local meta = self:GetQuestMeta(id, pq and pq.t, pq and pq.l)
        return {
            id = id,
            title = meta.title,
            level = meta.level,
            reqLevel = meta.reqLevel,
            zone = meta.zone,
            inMyLog = myLog[id] ~= nil,
            partnerQuest = pq,
            myQuest = myLog[id],
            ignored = self.db.ignored[id] and true or false,
        }
    end

    -- 1) quests the partner has turned in that I have not
    result.completedTotal = #(p.c or {})
    for _, id in ipairs(p.c or {}) do
        if not self:IsCompletedByMe(id) then
            result.completed[#result.completed + 1] = entry(id)
        end
    end
    result.completedShared = result.completedTotal - #result.completed

    -- 2) the partner's complete quest log, each with a status relative to me:
    --    missing  = not in my log, not completed by me
    --    behind   = in both logs, partner is further along (also listed in "ahead")
    --    even     = in both logs, same progress
    --    myahead  = in both logs, I'm further along
    --    done     = I already turned it in
    -- 3) "ahead" = the "behind" subset, for a focused view
    for id, pq in pairs(partnerLogged) do
        local e = entry(id, pq)
        local mine = myLog[id]
        if self:IsCompletedByMe(id) then
            e.status = "done"
        elseif not mine then
            e.status = "missing"
        else
            local theyAhead = (pq.c == 1 and mine.c ~= 1)
            local meAhead = (mine.c == 1 and pq.c ~= 1)
            for j, po in ipairs(pq.o or {}) do
                local mo = mine.o[j]
                if mo then
                    if po.h > mo.h or (po.f == 1 and mo.f ~= 1) then theyAhead = true end
                    if mo.h > po.h or (mo.f == 1 and po.f ~= 1) then meAhead = true end
                end
            end
            if theyAhead then
                e.status = "behind"
                result.ahead[#result.ahead + 1] = e
            elseif meAhead then
                e.status = "myahead"
            else
                e.status = "even"
            end
        end
        result.log[#result.log + 1] = e
    end

    local function sorter(a, b)
        if a.zone ~= b.zone then
            if a.zone == OTHER_ZONE or a.zone == "Unknown zone" then return false end
            if b.zone == OTHER_ZONE or b.zone == "Unknown zone" then return true end
            return a.zone < b.zone
        end
        local la, lb = a.level or 0, b.level or 0
        if la ~= lb then return la < lb end
        return a.title < b.title
    end
    table.sort(result.completed, sorter)
    table.sort(result.log, sorter)
    table.sort(result.ahead, sorter)
    return result
end

------------------------------------------------------------------------
-- Per-quest sync status (for the quest log markers and progress warnings)
------------------------------------------------------------------------
function K:GetPartnerSets(key)
    local cached = self.partnerCache[key]
    if cached then return cached end
    local p = self:GetPartner(key)
    if not p then return nil end
    cached = { completed = {}, log = {} }
    for _, id in ipairs(p.c or {}) do cached.completed[id] = true end
    for _, q in ipairs(p.q or {}) do cached.log[q.id] = q end
    self.partnerCache[key] = cached
    return cached
end

-- Compare one quest in my log against the selected partner.
-- Returns status, partnerQuest, myQuest, partnerKey. Status is one of:
--   "catchup"  partner already turned it in -> do it to catch up
--   "together" partner has it active, same progress or ahead of me -> do it together
--   "ahead"    partner has it active, I'm further along -> stop
--   "none"     partner neither has it nor completed it
-- or nil when there is no partner / no data.
function K:GetSyncStatus(questID)
    local key = self.db.selected
    local sets = key and self:GetPartnerSets(key)
    if not sets then return nil end
    if sets.completed[questID] then return "catchup", nil, nil, key end
    local pq = sets.log[questID]
    if not pq then return "none", nil, nil, key end
    local mine = (self.lastMyLog or self:GetMyLog())[questID]
    if mine then
        local meAhead = (mine.c == 1 and pq.c ~= 1)
        local theyAhead = (pq.c == 1 and mine.c ~= 1)
        for j, po in ipairs(pq.o or {}) do
            local mo = mine.o[j]
            if mo then
                if mo.h > po.h or (mo.f == 1 and po.f ~= 1) then meAhead = true end
                if po.h > mo.h or (po.f == 1 and mo.f ~= 1) then theyAhead = true end
            end
        end
        if meAhead and not theyAhead then return "ahead", pq, mine, key end
    end
    return "together", pq, mine, key
end

local function Progressed(old, new)
    if new.c == 1 and old.c ~= 1 then return true end
    for j, o in ipairs(new.o) do
        local prev = old.o[j]
        if prev and (o.h > prev.h or (o.f == 1 and prev.f ~= 1)) then return true end
    end
    return false
end

K.warnedAt = {}
local WARN_COOLDOWN = 45

function K:WarnStop(questID, title, partnerKey, pq)
    local now = GetTime()
    if (self.warnedAt[questID] or 0) + WARN_COOLDOWN > now then return end
    self.warnedAt[questID] = now

    local who = self:ShortName(partnerKey)
    local detail = ""
    for _, o in ipairs(pq and pq.o or {}) do
        if o.n > 0 then
            detail = (" (they're at %d/%d)"):format(o.h, o.n)
            break
        end
    end
    local msg = ("%s has \"%s\" active%s - stop and do it together!"):format(who, title, detail)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "Ketchup: " .. msg, ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.3, b = 0.1 })
    end
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
    self:Print("|cffff6633" .. msg .. "|r")
end

-- Snapshot my log, compare with the previous one, warn about progress on
-- quests the partner has active (unless they're in my group).
function K:CheckProgress()
    local now = self:GetMyLog()
    local before = self.lastMyLog
    self.lastMyLog = now
    if self.UI then self.UI:UpdateQuestLogMarkers() end
    if not before or not self.db.settings.warnProgress then return end

    local key = self.db.selected
    if not key or not self:GetPartner(key) then return end
    if self:GetGroupMembers()[key] then return end -- questing together, all good

    for id, q in pairs(now) do
        local old = before[id]
        if old and Progressed(old, q) then
            local status, pq = self:GetSyncStatus(id)
            if status == "together" or status == "ahead" then
                self:WarnStop(id, q.t ~= "" and q.t or ("Quest #" .. id), key, pq)
            end
        end
    end
end

local progressTimer
function K:ScheduleProgressCheck()
    if progressTimer then return end
    progressTimer = C_Timer.NewTimer(0.3, function()
        progressTimer = nil
        self:CheckProgress()
    end)
end

------------------------------------------------------------------------
-- Group helpers
------------------------------------------------------------------------
function K:GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function K:GetGroupMembers()
    local members = {}
    if not IsInGroup() then return members end
    local prefix, count = "party", GetNumSubgroupMembers()
    if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
    for i = 1, count do
        local unit = prefix .. i
        local name, realm = UnitName(unit)
        if name and name ~= UNKNOWNOBJECT then
            local key = (realm and realm ~= "") and (name .. "-" .. realm) or self:NormalizeName(name)
            if key ~= self:PlayerKey() then members[key] = unit end
        end
    end
    return members
end

-- Partners currently in my group that run Ketchup (seen a message from them)
K.online = {}

function K:IsPartnerOnline(key)
    return self.online[key] and self:GetGroupMembers()[key] ~= nil
end

------------------------------------------------------------------------
-- Auto-sharing
------------------------------------------------------------------------
K.lastSentSig = nil
local shareTimer

function K:ScheduleShare(delay, force)
    if force then self.lastSentSig = nil end
    -- QUEST_LOG_UPDATE fires constantly; don't keep pushing an existing timer back.
    if shareTimer and not force then return end
    if shareTimer then shareTimer:Cancel() end
    shareTimer = C_Timer.NewTimer(delay or 5, function()
        shareTimer = nil
        self:ShareNow(false)
    end)
end

-- manual = true when the user clicked a button (bypasses autoShare and sig check)
function K:ShareNow(manual)
    if not manual and not self.db.settings.autoShare then return end
    if not self:GetGroupChannel() then
        if manual then self:Print("You are not in a group. Use Export to share via string instead.") end
        return
    end
    local snapshot, sig = self:BuildSnapshot()
    if not manual and sig == self.lastSentSig then return end
    self.lastSentSig = sig
    self.Comm:SendSnapshot(snapshot)
end

function K:GetGroupChannel() return self:GroupChannel() end

local knownMembers = {}
function K:OnRosterChanged()
    local members = self:GetGroupMembers()
    local newcomer = false
    for key in pairs(members) do
        if not knownMembers[key] then newcomer = true end
    end
    for key in pairs(self.online) do
        if not members[key] then self.online[key] = nil end
    end
    knownMembers = members
    if newcomer then
        -- Someone new joined: make sure they get my current state.
        self:ScheduleShare(3, true)
    end
    if self.UI then self.UI:Refresh() end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local frame = CreateFrame("Frame")
K.eventFrame = frame

local uiRefreshTimer
function K:QueueUIRefresh()
    if not self.UI or not self.UI:IsShown() then return end
    if uiRefreshTimer then return end
    uiRefreshTimer = C_Timer.NewTimer(0.5, function()
        uiRefreshTimer = nil
        if self.UI then self.UI:Refresh() end
    end)
end

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON then return end
    KetchupDB = KetchupDB or {}
    ApplyDefaults(KetchupDB, DEFAULTS)
    K.db = KetchupDB
end

function handlers.PLAYER_LOGIN()
    if not ns.Serialize.IsAvailable() then
        K:Print("|cffff5555C_EncodingUtil is missing on this client, syncing will not work.|r")
    end
    K.Comm:Init()
    if K.UI then K.UI:Init() end
end

function handlers.PLAYER_ENTERING_WORLD(isLogin, isReload)
    knownMembers = K:GetGroupMembers()
    if IsInGroup() and (isLogin or isReload) then
        K:ScheduleShare(6, true)
    end
end

function handlers.GROUP_ROSTER_UPDATE()
    K:OnRosterChanged()
end

local function QuestChanged()
    K:QueueUIRefresh()
    K:ScheduleProgressCheck()
    if IsInGroup() then K:ScheduleShare(5) end
end
handlers.QUEST_TURNED_IN = QuestChanged
handlers.QUEST_ACCEPTED = QuestChanged
handlers.QUEST_REMOVED = QuestChanged
handlers.QUEST_LOG_UPDATE = QuestChanged

function handlers.QUEST_DATA_LOAD_RESULT()
    K:QueueUIRefresh()
end

frame:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h then h(...) end
end)
for event in pairs(handlers) do
    pcall(frame.RegisterEvent, frame, event)
end

------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------
SLASH_KETCHUP1 = "/ketchup"
SLASH_KETCHUP2 = "/ketch"
SlashCmdList.KETCHUP = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "sync" or msg == "request" then
        K.Comm:RequestFromGroup()
    elseif msg == "share" or msg == "send" then
        K:ShareNow(true)
    elseif msg == "export" then
        K.UI:ShowExport()
    elseif msg == "import" then
        K.UI:ShowImport()
    elseif msg == "minimap" then
        K.db.settings.minimap.hide = not K.db.settings.minimap.hide
        K.UI:UpdateMinimapButton()
    elseif msg == "debug" then
        K.UI:HookQuestLog()
        K.UI:DebugQuestLog()
    elseif msg == "help" then
        K:Print("/ketchup - toggle window")
        K:Print("/ketchup sync - ask group members for their progress")
        K:Print("/ketchup share - send your progress to the group now")
        K:Print("/ketchup export | import - share progress via string")
        K:Print("/ketchup minimap - toggle the minimap button")
    else
        K.UI:Toggle()
    end
end
