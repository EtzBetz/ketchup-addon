-- Ketchup: encoding of quest snapshots into compact, chat-safe strings.
-- Pipeline: table -> CBOR -> deflate -> Base64.
local _, ns = ...
local L = ns.L

local S = {}
ns.Serialize = S

S.EXPORT_PREFIX = "KETCHUP1:"

local E = C_EncodingUtil

function S.IsAvailable()
    return E and E.SerializeCBOR and E.CompressString and E.EncodeBase64 and true or false
end

function S.Encode(tbl)
    if not S.IsAvailable() then
        return nil, L["C_EncodingUtil is not available on this client"]
    end
    local ok, result = pcall(function()
        return E.EncodeBase64(E.CompressString(E.SerializeCBOR(tbl)))
    end)
    if not ok then return nil, tostring(result) end
    return result
end

function S.Decode(str)
    if not S.IsAvailable() then
        return nil, L["C_EncodingUtil is not available on this client"]
    end
    if type(str) ~= "string" or str == "" then return nil, L["empty data"] end
    local ok, decoded = pcall(E.DecodeBase64, str)
    if not ok or not decoded then return nil, L["invalid Base64"] end
    local ok2, decompressed = pcall(E.DecompressString, decoded)
    if not ok2 or not decompressed then return nil, L["decompression failed"] end
    local ok3, tbl = pcall(E.DeserializeCBOR, decompressed)
    if not ok3 or type(tbl) ~= "table" then return nil, L["invalid payload"] end
    return tbl
end

function S.ToExportString(snapshot)
    local encoded, err = S.Encode(snapshot)
    if not encoded then return nil, err end
    return S.EXPORT_PREFIX .. encoded
end

function S.FromExportString(text)
    if type(text) ~= "string" then return nil, L["no text"] end
    -- Messengers like to wrap lines or add spaces: strip all whitespace.
    text = text:gsub("%s+", "")
    local start = text:find(S.EXPORT_PREFIX, 1, true)
    if not start then return nil, L["this is not a Ketchup string (missing %s)"]:format(S.EXPORT_PREFIX) end
    return S.Decode(text:sub(start + #S.EXPORT_PREFIX))
end
