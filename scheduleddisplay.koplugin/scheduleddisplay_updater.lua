local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("scheduleddisplay_gettext")
local T = require("ffi/util").template

local RELEASE_API_URL = "https://api.github.com/repos/yEs1do/scheduleddisplay.koplugin/releases/latest"
local RELEASES_URL = "https://github.com/yEs1do/scheduleddisplay.koplugin/releases"

local function parseVersion(version)
    local parts = {}
    for part in tostring(version):gsub("^v", ""):gmatch("([^.]+)") do
        table.insert(parts, tonumber(part) or 0)
    end
    return parts
end

local function isNewer(remote, local_version)
    local a, b = parseVersion(remote), parseVersion(local_version)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

local function fetchLatestRelease()
    local body = {}
    local code, headers, status

    local ok, err = pcall(function()
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
        code, headers, status = socket.skip(1, http.request{
            url = RELEASE_API_URL,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-ScheduledDisplay",
                ["Accept"] = "application/vnd.github.v3+json",
            },
            sink = ltn12.sink.table(body),
            redirect = true,
        })
    end)
    pcall(function() socketutil:reset_timeout() end)

    if not ok then
        return nil, tostring(err)
    end
    if code ~= 200 then
        return nil, tostring(status or code or "network error")
    end

    local ok_json, release = pcall(JSON.decode, table.concat(body))
    if not ok_json or type(release) ~= "table" then
        return nil, "invalid JSON response"
    end
    if release.draft or release.prerelease or not release.tag_name then
        return nil, "no stable release available"
    end

    return release
end

local Updater = {}

function Updater.check(installed_version)
    local function run_check()
        if not NetworkMgr:isConnected() then
            return
        end

        UIManager:show(InfoMessage:new{
            text = _("正在检查更新…"),
            timeout = 1,
        })

        UIManager:scheduleIn(0.1, function()
            local completed, release_or_error = Trapper:dismissableRunInSubprocess(
                fetchLatestRelease,
                _("正在检查更新…")
            )

            if not completed then
                UIManager:show(InfoMessage:new{
                    text = _("检查更新已取消。"),
                    timeout = 2,
                })
                return
            end

            local release = release_or_error
            if type(release) ~= "table" or not release.tag_name then
                logger.warn(
                    "ScheduledDisplay: update check failed:",
                    tostring(release_or_error)
                )
                UIManager:show(InfoMessage:new{
                    text = _("检查更新失败，请检查网络连接后重试。"),
                    timeout = 4,
                })
                return
            end

            local latest = release.tag_name:gsub("^v", "")
            if not isNewer(latest, installed_version) then
                UIManager:show(InfoMessage:new{
                    text = T(_("当前已是最新版本：v%1"), installed_version),
                    timeout = 3,
                })
                return
            end

            local message = T(
                _("发现新版本：v%1\n当前版本：v%2\n\n请前往 GitHub Releases 下载。"),
                latest,
                installed_version
            )
            local release_url = release.html_url or RELEASES_URL

            if Device:canOpenLink() then
                UIManager:show(ConfirmBox:new{
                    text = message,
                    ok_text = _("打开"),
                    cancel_text = _("取消"),
                    ok_callback = function()
                        Device:openLink(release_url)
                    end,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = message .. "\n" .. release_url,
                    timeout = 6,
                })
            end
        end)
    end

    if NetworkMgr:isConnected() then
        run_check()
    else
        NetworkMgr:runWhenConnected(run_check)
    end
end

return Updater
