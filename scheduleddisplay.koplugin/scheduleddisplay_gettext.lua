-- Self-contained localization for the Scheduled Display Adjustment plugin.
--
-- KOReader's gettext catalog does not contain strings defined by standalone
-- plugins. This wrapper reuses KOReader gettext for language detection and
-- fallback, while resolving this plugin's translations from l10n/<lang>.lua.

local GetText = require("gettext")
local logger = require("logger")

local function thisDir()
    local source = debug.getinfo(1, "S").source
    return source:match("^@(.*)[/\\][^/\\]+$")
end

local function loadLangTable(lang)
    if not lang or lang == "" or lang == "C" then
        return nil
    end

    local dir = thisDir()
    if not dir then
        return nil
    end

    local function tryCode(code)
        local chunk = loadfile(dir .. "/l10n/" .. code .. ".lua")
        if not chunk then
            return nil
        end

        local ok, tbl = pcall(chunk)
        if ok and type(tbl) == "table" then
            return tbl
        end

        logger.warn("scheduleddisplay_gettext: failed to load translation", code)
        return nil
    end

    local tbl = tryCode(lang)
    if not tbl then
        local base = lang:match("^(%a%a)")
        if base and base ~= lang then
            tbl = tryCode(base)
        end
    end
    return tbl
end

local function getConfiguredLang()
    -- KOReader treats en_US as untranslated and keeps gettext.current_lang at "C".
    -- Read the user's explicit language setting so the plugin can still select
    -- its bundled English translation in that case.
    if G_reader_settings then
        local lang = G_reader_settings:readSetting("language")
        if lang and lang ~= "" then
            return lang
        end
    end
    return GetText.current_lang
end

local function normalizeLang(lang)
    if not lang or lang == "" or lang == "C" then
        return lang
    end

    -- Locale strings may contain an encoding suffix or a fallback chain.
    lang = lang:match("^[^:.]+") or lang
    return lang:gsub("_", "-")
end

local configured_lang = normalizeLang(getConfiguredLang())
local translation = loadLangTable(configured_lang) or {}

return setmetatable({}, {
    __call = function(_self, msgid)
        return translation[msgid] or GetText(msgid)
    end,
    __index = GetText,
})
