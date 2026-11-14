-- Ketchup: localization.
--
-- The English text is the key: L["Sync with group"]. A translation file only
-- has to list what it translates; anything missing falls back to English, so
-- a gap never shows up as an error or an empty label.
--
-- Translation files (Locales\*.lua) call ns.RegisterLocale("deDE", { ... })
-- and only the one matching the game client's language is used.
local _, ns = ...

local L = setmetatable({}, {
    __index = function(_, key) return key end,
})
ns.L = L

local current = GetLocale and GetLocale() or "enUS"
if current == "enGB" then current = "enUS" end
ns.locale = current

-- locales: one or more codes separated by spaces, e.g. "esES esMX"
function ns.RegisterLocale(locales, strings)
    for code in locales:gmatch("%S+") do
        if code == current then
            for key, text in pairs(strings) do
                if type(text) == "string" and text ~= "" then rawset(L, key, text) end
            end
            return
        end
    end
end
