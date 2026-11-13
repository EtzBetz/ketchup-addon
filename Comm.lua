-- Ketchup: addon-message transport (chunking, throttled queue, reassembly).
--
-- Messages (prefix "Ketchup", tab separated):
--   R                          request: "please send me your progress"
--   D <msgid> <i> <n> <data>   chunk i of n of an encoded snapshot
local _, ns = ...
local K = ns.K
local S = ns.Serialize

local Comm = {}
K.Comm = Comm

local PREFIX = "Ketchup"
local CHUNK_SIZE = 220            -- addon messages are limited to 255 bytes
local SEND_INTERVAL = 0.2
local RETRY_DELAY = 1.0
local STALE_AFTER = 120           -- seconds before an incomplete transfer is dropped

local Result = Enum and Enum.SendAddonMessageResult or {
    Success = 0, AddonMessageThrottle = 3, NotInGroup = 5, ChannelThrottle = 8, GeneralError = 9,
}

local queue = {}
local pumping = false
local msgCounter = 0
local incoming = {} -- [sender] = { id, n, got, parts, t }

local function InLockdown()
    return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() or false
end

local function RawSend(text, channel, target)
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, channel, target)
    if not ok then return Result.GeneralError end
    if res == nil or res == true then return Result.Success end
    if res == false then return Result.GeneralError end
    return res
end

local function Pump()
    local m = queue[1]
    if not m then pumping = false return end
    if InLockdown() then
        C_Timer.After(2, Pump)
        return
    end
    -- group messages are pointless once we left the group
    if (m.channel == "PARTY" or m.channel == "RAID" or m.channel == "INSTANCE_CHAT") and not IsInGroup() then
        table.remove(queue, 1)
        C_Timer.After(0, Pump)
        return
    end
    local res = RawSend(m.text, m.channel, m.target)
    if res == Result.AddonMessageThrottle or res == Result.ChannelThrottle then
        C_Timer.After(RETRY_DELAY, Pump)
        return
    end
    table.remove(queue, 1)
    if m.onDone and (not queue[1] or queue[1].tag ~= m.tag) then m.onDone() end
    C_Timer.After(SEND_INTERVAL, Pump)
end

local function Enqueue(text, channel, target, tag, onDone)
    queue[#queue + 1] = { text = text, channel = channel, target = target, tag = tag, onDone = onDone }
    if not pumping then
        pumping = true
        Pump()
    end
end

local function DropQueued(tag)
    for i = #queue, 2, -1 do -- keep [1], it may be mid-send
        if queue[i].tag == tag then table.remove(queue, i) end
    end
end

function Comm:Init()
    if C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
        if prefix == PREFIX then Comm:OnMessage(text, channel, sender) end
    end)
end

function Comm:SendSnapshot(snapshot)
    local channel = K:GroupChannel()
    if not channel then return false end
    local encoded, err = S.Encode(snapshot)
    if not encoded then
        K:Print("Could not encode progress: " .. tostring(err))
        return false
    end
    -- a newer snapshot supersedes anything still waiting in the queue
    DropQueued("snapshot")
    msgCounter = (msgCounter + 1) % 10000
    local id = tostring(msgCounter)
    local n = math.ceil(#encoded / CHUNK_SIZE)
    for i = 1, n do
        local part = encoded:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
        Enqueue(("D\t%s\t%d\t%d\t%s"):format(id, i, n, part), channel, nil, "snapshot")
    end
    return true
end

function Comm:RequestFromGroup()
    local channel = K:GroupChannel()
    if not channel then
        K:Print("You are not in a group. Ask your partner for an export string instead.")
        return
    end
    Enqueue("R", channel, nil, "request")
    -- send mine along so both sides end up in sync
    K:ScheduleShare(1, true)
    K:Print("Requested quest progress from your group.")
end

function Comm:OnMessage(text, channel, sender)
    local key = K:NormalizeName(sender)
    -- WoW echoes my own addon messages back to me
    if not key or K:IsMe(key) then return end

    if not K.online[key] then
        K.online[key] = true
        if K.UI then K.UI:Refresh() end
    end

    local kind = text:sub(1, 1)
    if kind == "R" then
        K:ScheduleShare(1, true)
    elseif kind == "D" then
        local id, i, n, data = text:match("^D\t(%d+)\t(%d+)\t(%d+)\t(.*)$")
        i, n = tonumber(i), tonumber(n)
        if not id or not i or not n or n < 1 or n > 2000 or i < 1 or i > n then return end

        local now = GetTime()
        local t = incoming[key]
        if not t or t.id ~= id or now - t.t > STALE_AFTER then
            t = { id = id, n = n, got = 0, parts = {}, t = now }
            incoming[key] = t
        end
        t.t = now
        if not t.parts[i] then
            t.parts[i] = data
            t.got = t.got + 1
        end
        if K.UI then K.UI:SetTransferProgress(key, t.got, t.n) end
        if t.got >= t.n then
            incoming[key] = nil
            local snapshot, err = S.Decode(table.concat(t.parts, "", 1, t.n))
            if not snapshot then
                K:Print("Received broken data from " .. K:ShortName(key) .. ": " .. tostring(err))
                return
            end
            local prev = K.db.partners[key]
            local prevCount = prev and prev.c and #prev.c
            local stored, why = K:StorePartnerSnapshot(snapshot, "group", key)
            if not stored and why then
                K:Print("Ignored data from " .. K:ShortName(key) .. ": " .. why)
            elseif stored and prevCount ~= #(K.db.partners[key].c or {}) then
                K:Print(("Saved quest progress of %s (%d completed quests). /ketchup to compare.")
                    :format(K:ShortName(key), #(K.db.partners[key].c or {})))
            end
            if K.UI then K.UI:SetTransferProgress(key, nil) end
        end
    end
end
