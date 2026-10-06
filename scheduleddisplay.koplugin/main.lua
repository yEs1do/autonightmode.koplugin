--[[--
自动显示调节

按时间表自动调整前光亮度、色温和夜间模式（反色）。

@module koplugin.ScheduledDisplay
--]]--

local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Menu = require("ui/widget/menu")
local _ = require("gettext")
local C_ = _.pgettext
local T = require("ffi/util").template

local Powerd = Device:getPowerDevice()
local Screen = Device.screen

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/scheduleddisplay.lua"
local LEGACY_FILE = DataStorage:getSettingsDir() .. "/autonightmode.lua"

local MAX_ENTRIES = 24
local TIME_STEP_MIN = 5
local SMOOTH_MIN_S = 5
local SMOOTH_MAX_S = 60
local SMOOTH_STEP_S = 5
local RAMP_INTERVAL_S = 0.25
local UNCHANGED = "unchanged"

local function clamp(value, min_value, max_value)
    return math.max(min_value, math.min(max_value, value))
end

local function round(value)
    return math.floor(value + 0.5)
end

local function nowMinutes()
    local t = os.date("*t")
    return t.hour * 60 + t.min
end

local function clock(minutes)
    minutes = minutes % (24 * 60)
    return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function normalizeNative(value, max_value)
    if value == nil or max_value == nil or max_value <= 0 then
        return UNCHANGED
    end
    return round(clamp(value, 0, max_value) / max_value * 100)
end

local function denormalizeNative(value, max_value)
    if value == nil or value == UNCHANGED or max_value == nil or max_value <= 0 then
        return nil
    end
    return round(clamp(value, 0, 100) / 100 * max_value)
end

local function hasFrontlight()
    return Device:hasFrontlight()
end

local function hasWarmth()
    return Device:hasNaturalLight()
end

local function hasNightMode()
    return Screen ~= nil and type(Screen.toggleNightMode) == "function"
end

local function sortSchedule(schedule)
    table.sort(schedule, function(a, b)
        return a.time < b.time
    end)
end

local function findTime(schedule, minutes)
    for i, entry in ipairs(schedule) do
        if entry.time == minutes then return i end
    end
    return nil
end

local function findEntry(schedule, entry)
    for i, item in ipairs(schedule) do
        if item == entry then return i end
    end
    return nil
end

local function copySchedule(schedule)
    local result = {}
    for i, entry in ipairs(schedule) do
        result[i] = {
            time = entry.time,
            brightness = entry.brightness,
            warmth = entry.warmth,
            night_mode = entry.night_mode,
        }
    end
    return result
end

local function validateSchedule(schedule)
    if type(schedule) ~= "table" or #schedule > MAX_ENTRIES then return false end
    local previous = -1
    for _, entry in ipairs(schedule) do
        if type(entry) ~= "table" then return false end
        if type(entry.time) ~= "number" or entry.time < 0 or entry.time >= 1440 then return false end
        if entry.time % TIME_STEP_MIN ~= 0 or entry.time <= previous then return false end
        previous = entry.time
        if entry.brightness ~= UNCHANGED and
            (type(entry.brightness) ~= "number" or entry.brightness < 0 or entry.brightness > 100) then
            return false
        end
        if entry.warmth ~= UNCHANGED and
            (type(entry.warmth) ~= "number" or entry.warmth < 0 or entry.warmth > 100) then
            return false
        end
        if entry.night_mode ~= UNCHANGED and entry.night_mode ~= "on" and entry.night_mode ~= "off" then
            return false
        end
    end
    return true
end

local function repairSchedule(schedule)
    if type(schedule) ~= "table" then return nil end
    local result = {}
    for _, entry in ipairs(schedule) do
        if type(entry) ~= "table" or tonumber(entry.time) == nil then return nil end
        local time_value = math.floor(tonumber(entry.time) / TIME_STEP_MIN + 0.5) * TIME_STEP_MIN
        time_value = time_value % 1440
        table.insert(result, {
            time = time_value,
            brightness = entry.brightness == nil and UNCHANGED or entry.brightness,
            warmth = entry.warmth == nil and UNCHANGED or entry.warmth,
            night_mode = entry.night_mode == nil and UNCHANGED or entry.night_mode,
        })
    end
    sortSchedule(result)
    for i = 2, #result do
        if result[i - 1].time == result[i].time then return nil end
    end
    return result
end

local function effectiveState(schedule, minutes)
    local state = { brightness = nil, warmth = nil, night_mode = nil }
    if #schedule == 0 then return state end

    local start = #schedule
    for i = #schedule, 1, -1 do
        if schedule[i].time <= minutes then
            start = i
            break
        end
    end

    local unresolved = 3
    for offset = 0, #schedule - 1 do
        local index = ((start - 1 - offset) % #schedule) + 1
        local entry = schedule[index]

        if state.brightness == nil and entry.brightness ~= UNCHANGED then
            state.brightness = entry.brightness
            unresolved = unresolved - 1
        end
        if state.warmth == nil and entry.warmth ~= UNCHANGED then
            state.warmth = entry.warmth
            unresolved = unresolved - 1
        end
        if state.night_mode == nil and entry.night_mode ~= UNCHANGED then
            state.night_mode = entry.night_mode
            unresolved = unresolved - 1
        end
        if unresolved == 0 then break end
    end
    return state
end

local function stateChanged(a, b)
    return a.brightness ~= b.brightness
        or a.warmth ~= b.warmth
        or a.night_mode ~= b.night_mode
end

local function nextDelay(target)
    local now = os.date("*t")
    local current = now.hour * 3600 + now.min * 60 + now.sec
    local target_seconds = target * 60
    local delay = target_seconds - current
    if delay <= 0 then delay = delay + 86400 end
    return delay
end

local ScheduledDisplay = WidgetContainer:extend{
    name = "scheduleddisplay",
    is_doc_only = false,
}

function ScheduledDisplay:getDefaultSchedule()
    local schedule = {}
    local fl_max = Powerd and Powerd.fl_max or 24
    local warmth_max = Powerd and Powerd.fl_warmth_max or 24
    table.insert(schedule, {
        time = 7 * 60,
        brightness = hasFrontlight() and normalizeNative(18, fl_max) or UNCHANGED,
        warmth = hasWarmth() and normalizeNative(6, warmth_max) or UNCHANGED,
        night_mode = hasNightMode() and "off" or UNCHANGED,
    })
    table.insert(schedule, {
        time = 18 * 60,
        brightness = hasFrontlight() and normalizeNative(12, fl_max) or UNCHANGED,
        warmth = hasWarmth() and normalizeNative(18, warmth_max) or UNCHANGED,
        night_mode = UNCHANGED,
    })
    table.insert(schedule, {
        time = 23 * 60,
        brightness = hasFrontlight() and normalizeNative(6, fl_max) or UNCHANGED,
        warmth = UNCHANGED,
        night_mode = hasNightMode() and "on" or UNCHANGED,
    })
    return schedule
end

function ScheduledDisplay:migrateLegacy()
    local fd = io.open(LEGACY_FILE, "r")
    if not fd then return nil end
    fd:close()

    local ok, legacy = pcall(LuaSettings.open, LuaSettings, LEGACY_FILE)
    if not ok or not legacy then return nil end

    local enabled = legacy:readSetting("enabled")
    local on_hour = legacy:readSetting("on_hour")
    local on_min = legacy:readSetting("on_min")
    local off_hour = legacy:readSetting("off_hour")
    local off_min = legacy:readSetting("off_min")
    local night_warmth = legacy:readSetting("night_warmth")
    local day_warmth = legacy:readSetting("day_warmth")
    local night_brightness = legacy:readSetting("night_brightness")
    local day_brightness = legacy:readSetting("day_brightness")
    local notify = legacy:readSetting("notify")

    local has_any = enabled ~= nil or on_hour ~= nil or on_min ~= nil
        or off_hour ~= nil or off_min ~= nil or night_warmth ~= nil
        or day_warmth ~= nil or night_brightness ~= nil or day_brightness ~= nil
    if not has_any then return nil end

    local fl_max = Powerd and Powerd.fl_max or 24
    local function oldBrightness(value)
        if type(value) ~= "number" or value < 0 then return UNCHANGED end
        return normalizeNative(value, fl_max)
    end
    local function oldWarmth(value)
        if type(value) ~= "number" or value < 0 then return UNCHANGED end
        return clamp(round(value), 0, 100)
    end

    local day_time = ((tonumber(off_hour) or 7) * 60 + (tonumber(off_min) or 0)) % 1440
    local night_time = ((tonumber(on_hour) or 20) * 60 + (tonumber(on_min) or 0)) % 1440

    local schedule = {
        {
            time = day_time - day_time % TIME_STEP_MIN,
            brightness = oldBrightness(day_brightness),
            warmth = hasWarmth() and oldWarmth(day_warmth) or UNCHANGED,
            night_mode = hasNightMode() and "off" or UNCHANGED,
        },
        {
            time = night_time - night_time % TIME_STEP_MIN,
            brightness = oldBrightness(night_brightness),
            warmth = hasWarmth() and oldWarmth(night_warmth) or UNCHANGED,
            night_mode = hasNightMode() and "on" or UNCHANGED,
        },
    }

    if schedule[1].time == schedule[2].time then schedule[2] = nil end
    sortSchedule(schedule)

    return {
        enabled = enabled == true,
        schedule = schedule,
        smooth = true,
        smooth_duration = 5,
        notify = notify == true,
    }
end

function ScheduledDisplay:load()
    self.settings = LuaSettings:open(SETTINGS_FILE)
    self.enabled = self.settings:readSetting("enabled")
    self.schedule = repairSchedule(self.settings:readSetting("schedule"))
    self.smooth = self.settings:readSetting("smooth")
    self.smooth_duration = self.settings:readSetting("smooth_duration")
    self.notify = self.settings:readSetting("notify")

    if self.schedule == nil then
        local migrated = self:migrateLegacy()
        if migrated then
            self.enabled = migrated.enabled
            self.schedule = migrated.schedule
            self.smooth = migrated.smooth
            self.smooth_duration = migrated.smooth_duration
            self.notify = migrated.notify
        else
            self.schedule = self:getDefaultSchedule()
        end
    end

    if self.enabled == nil then self.enabled = false end
    if self.smooth == nil then self.smooth = true end
    if self.smooth_duration == nil then self.smooth_duration = 5 end
    if self.notify == nil then self.notify = false end
    if not validateSchedule(self.schedule) then
        self.schedule = self:getDefaultSchedule()
    end
    self.smooth_duration = math.floor((tonumber(self.smooth_duration) or 5) / 5 + 0.5) * 5
    self.smooth_duration = clamp(self.smooth_duration, SMOOTH_MIN_S, SMOOTH_MAX_S)
    table.sort(self.schedule, function(a, b) return a.time < b.time end)
end

function ScheduledDisplay:save()
    self.settings:saveSetting("enabled", self.enabled)
    self.settings:saveSetting("schedule", self.schedule)
    self.settings:saveSetting("smooth", self.smooth)
    self.settings:saveSetting("smooth_duration", self.smooth_duration)
    self.settings:saveSetting("notify", self.notify)
    self.settings:flush()
end

function ScheduledDisplay:init()
    self:load()
    self.ui.menu:registerToMainMenu(self)
    UIManager.event_hook:registerWidget("InputEvent", self)
    self:_reschedule()
end

function ScheduledDisplay:_cancelRamp()
    if self.ramp_task then UIManager:unschedule(self.ramp_task) end
    self.ramp_task = nil
    self.ramp_expected_brightness = nil
    self.ramp_expected_warmth = nil
    self.ramp_token = (self.ramp_token or 0) + 1
end

function ScheduledDisplay:_cancelSchedule()
    if self.schedule_task then UIManager:unschedule(self.schedule_task) end
    self.schedule_task = nil
end

function ScheduledDisplay:_reschedule()
    self:_cancelSchedule()
    if not self.enabled or #self.schedule == 0 then return end

    local now = nowMinutes()
    local next_item
    for _, entry in ipairs(self.schedule) do
        if entry.time > now then
            next_item = entry
            break
        end
    end
    next_item = next_item or self.schedule[1]

    self.schedule_task = function()
        self.schedule_task = nil
        self:_applyCurrent(true)
        if self.notify then
            UIManager:show(InfoMessage:new{
                text = _("自动显示调节：已应用当前时间点设置。"),
                timeout = 2,
            })
        end
        self:_reschedule()
    end
    UIManager:scheduleIn(math.max(0.1, nextDelay(next_item.time)), self.schedule_task, self)
end

function ScheduledDisplay:_currentBrightness()
    return hasFrontlight() and Powerd:frontlightIntensity() or nil
end

function ScheduledDisplay:_currentWarmth()
    return hasWarmth() and Powerd:toNativeWarmth(Powerd:frontlightWarmth()) or nil
end

function ScheduledDisplay:_currentNightMode()
    return hasNightMode() and G_reader_settings:isTrue("night_mode") or nil
end

function ScheduledDisplay:_setBrightness(value)
    if value == nil or not hasFrontlight() then return end
    Powerd:setIntensity(round(clamp(value, Powerd.fl_min, Powerd.fl_max)), true)
end

function ScheduledDisplay:_setWarmth(value)
    if value == nil or not hasWarmth() then return end
    value = round(clamp(value, Powerd.fl_warmth_min, Powerd.fl_warmth_max))
    Powerd:setWarmth(Powerd:fromNativeWarmth(value))
end

function ScheduledDisplay:_setNightMode(mode)
    if mode == nil or mode == UNCHANGED or not hasNightMode() then return end
    local wanted = mode == "on"
    if self:_currentNightMode() ~= wanted then
        self.ui:handleEvent(Event:new("SetNightMode", wanted))
    end
end

function ScheduledDisplay:_applyImmediate(state)
    local brightness = state.brightness and denormalizeNative(state.brightness, Powerd.fl_max) or nil
    local warmth = state.warmth and denormalizeNative(state.warmth, Powerd.fl_warmth_max) or nil
    if brightness ~= nil then self:_setBrightness(brightness) end
    if warmth ~= nil then self:_setWarmth(warmth) end
    if state.night_mode ~= nil then self:_setNightMode(state.night_mode) end
end

function ScheduledDisplay:_applyCurrent(allow_smooth)
    if #self.schedule == 0 then return end
    local state = effectiveState(self.schedule, nowMinutes())

    local target_brightness = hasFrontlight() and denormalizeNative(state.brightness, Powerd.fl_max) or nil
    local target_warmth = hasWarmth() and denormalizeNative(state.warmth, Powerd.fl_warmth_max) or nil

    local current_brightness = self:_currentBrightness()
    local current_warmth = self:_currentWarmth()

    local need_brightness = target_brightness ~= nil and current_brightness ~= target_brightness
    local need_warmth = target_warmth ~= nil and current_warmth ~= target_warmth

    self:_cancelRamp()
    if state.night_mode ~= nil then self:_setNightMode(state.night_mode) end

    if not allow_smooth or not self.smooth then
        self:_applyImmediate({
            brightness = state.brightness,
            warmth = state.warmth,
        })
        return
    end

    if not need_brightness and not need_warmth then return end

    local duration = self.smooth_duration
    local start = UIManager:getElapsedTimeSinceBoot()
    local finish = start + duration
    local from_brightness = current_brightness
    local from_warmth = current_warmth
    local token = (self.ramp_token or 0) + 1
    self.ramp_token = token
    self.ramp_expected_brightness = from_brightness
    self.ramp_expected_warmth = from_warmth

    self.ramp_task = function()
        if token ~= self.ramp_token or not self.enabled then return end

        local elapsed = UIManager:getElapsedTimeSinceBoot() - start
        local progress = clamp(elapsed / duration, 0, 1)
        local eased = 0.5 - 0.5 * math.cos(math.pi * progress)

        if need_brightness then
            local value = round(from_brightness + (target_brightness - from_brightness) * eased)
            self.ramp_expected_brightness = value
            self:_setBrightness(value)
        end
        if need_warmth then
            local value = round(from_warmth + (target_warmth - from_warmth) * eased)
            self.ramp_expected_warmth = value
            self:_setWarmth(value)
        end

        if elapsed >= duration then
            if need_brightness then
                self.ramp_expected_brightness = target_brightness
                self:_setBrightness(target_brightness)
            end
            if need_warmth then
                self.ramp_expected_warmth = target_warmth
                self:_setWarmth(target_warmth)
            end
            self.ramp_task = nil
            self.ramp_expected_brightness = nil
            self.ramp_expected_warmth = nil
            return
        end

        UIManager:scheduleIn(RAMP_INTERVAL_S, self.ramp_task, self)
    end
    self.ramp_task()
end

function ScheduledDisplay:_stateSummary(entry)
    local parts = {}
    if hasFrontlight() and entry.brightness ~= UNCHANGED then
        table.insert(parts, T(_("亮%1"), denormalizeNative(entry.brightness, Powerd.fl_max)))
    end
    if hasWarmth() and entry.warmth ~= UNCHANGED then
        table.insert(parts, T(_("色%1"), denormalizeNative(entry.warmth, Powerd.fl_warmth_max)))
    end
    if hasNightMode() then
        if entry.night_mode == "on" then
            table.insert(parts, _("反色开"))
        elseif entry.night_mode == "off" then
            table.insert(parts, _("反色关"))
        end
    end
    return #parts > 0 and table.concat(parts, " · ") or _("不调整")
end

function ScheduledDisplay:_setCurrentAndRefresh(old_state, parent)
    if not self.enabled then
        if parent then parent:updateItems() end
        return
    end
    local new_state = effectiveState(self.schedule, nowMinutes())
    if stateChanged(old_state, new_state) then
        self:_applyCurrent(true)
    end
    self:_reschedule()
    if parent then parent:updateItems() end
end

function ScheduledDisplay:_timePicker(initial, callback)
    local h = math.floor(initial / 60)
    local m = initial % 60
    UIManager:show(SpinWidget:new{
        title_text = _("小时"),
        value = h,
        value_min = 0,
        value_max = 23,
        value_step = 1,
        value_hold_step = 1,
        default_value = h,
        callback = function(hour_widget)
            if not hour_widget then return end
            UIManager:show(SpinWidget:new{
                title_text = _("分钟"),
                value = m,
                value_min = 0,
                value_max = 55,
                value_step = TIME_STEP_MIN,
                value_hold_step = TIME_STEP_MIN,
                default_value = m,
                callback = function(min_widget)
                    if not min_widget then return end
                    callback(hour_widget.value * 60 + min_widget.value)
                end,
            })
        end,
    })
end

function ScheduledDisplay:_pickBrightness(entry, parent)
    if not hasFrontlight() then return end
    local current = entry.brightness == UNCHANGED
        and Powerd:frontlightIntensity()
        or denormalizeNative(entry.brightness, Powerd.fl_max)
    UIManager:show(SpinWidget:new{
        title_text = _("前光亮度"),
        value = current or 0,
        value_min = Powerd.fl_min,
        value_max = Powerd.fl_max,
        value_step = 1,
        value_hold_step = 1,
        default_value = current or 0,
        extra_text = _("不调整"),
        extra_callback = function()
            local old_state = effectiveState(self.schedule, nowMinutes())
            entry.brightness = UNCHANGED
            self:save()
            self:_setCurrentAndRefresh(old_state, parent)
        end,
        callback = function(spin)
            if not spin then return end
            local old_state = effectiveState(self.schedule, nowMinutes())
            entry.brightness = normalizeNative(spin.value, Powerd.fl_max)
            self:save()
            self:_setCurrentAndRefresh(old_state, parent)
        end,
    })
end

function ScheduledDisplay:_pickWarmth(entry, parent)
    if not hasWarmth() then return end
    local current = entry.warmth == UNCHANGED
        and Powerd:toNativeWarmth(Powerd:frontlightWarmth())
        or denormalizeNative(entry.warmth, Powerd.fl_warmth_max)
    UIManager:show(SpinWidget:new{
        title_text = _("色温"),
        value = current or 0,
        value_min = Powerd.fl_warmth_min,
        value_max = Powerd.fl_warmth_max,
        value_step = 1,
        value_hold_step = 1,
        default_value = current or 0,
        extra_text = _("不调整"),
        extra_callback = function()
            local old_state = effectiveState(self.schedule, nowMinutes())
            entry.warmth = UNCHANGED
            self:save()
            self:_setCurrentAndRefresh(old_state, parent)
        end,
        callback = function(spin)
            if not spin then return end
            local old_state = effectiveState(self.schedule, nowMinutes())
            entry.warmth = normalizeNative(spin.value, Powerd.fl_warmth_max)
            self:save()
            self:_setCurrentAndRefresh(old_state, parent)
        end,
    })
end

function ScheduledDisplay:_pickNightMode(entry, parent)
    if not hasNightMode() then return end
    UIManager:show(RadioButtonWidget:new{
        title_text = _("夜间模式（反色）"),
        radio_buttons = {
            { { text = _("不调整"), provider = UNCHANGED, checked = entry.night_mode == UNCHANGED } },
            { { text = _("开启"), provider = "on", checked = entry.night_mode == "on" } },
            { { text = _("关闭"), provider = "off", checked = entry.night_mode == "off" } },
        },
        callback = function(widget)
            local old_state = effectiveState(self.schedule, nowMinutes())
            entry.night_mode = widget.provider
            self:save()
            self:_setCurrentAndRefresh(old_state, parent)
        end,
    })
end

function ScheduledDisplay:_editEntry(index, parent)
    local entry = self.schedule[index]
    if not entry then return end

    local items = {
        {
            text_func = function()
                return T(_("时间：%1"), clock(entry.time))
            end,
            callback = function()
                local old_state = effectiveState(self.schedule, nowMinutes())
                self:_timePicker(entry.time, function(new_time)
                    local existing = findTime(self.schedule, new_time)
                    if existing and existing ~= index then
                        UIManager:show(InfoMessage:new{
                            text = T(_("时间 %1 已存在。"), clock(new_time)),
                            timeout = 2,
                        })
                        return
                    end
                    entry.time = new_time
                    sortSchedule(self.schedule)
                    self:save()
                    self:_setCurrentAndRefresh(old_state, parent)
                end)
            end,
            keep_menu_open = true,
        },
    }

    if hasFrontlight() then
        table.insert(items, {
            text_func = function()
                local value = entry.brightness == UNCHANGED and _("不调整")
                    or tostring(denormalizeNative(entry.brightness, Powerd.fl_max))
                return T(_("前光亮度：%1"), value)
            end,
            callback = function(menu) self:_pickBrightness(entry, menu) end,
            keep_menu_open = true,
        })
    end

    if hasWarmth() then
        table.insert(items, {
            text_func = function()
                local value = entry.warmth == UNCHANGED and _("不调整")
                    or tostring(denormalizeNative(entry.warmth, Powerd.fl_warmth_max))
                return T(_("色温：%1"), value)
            end,
            callback = function(menu) self:_pickWarmth(entry, menu) end,
            keep_menu_open = true,
        })
    end

    if hasNightMode() then
        table.insert(items, {
            text_func = function()
                local value = entry.night_mode == UNCHANGED and _("不调整")
                    or entry.night_mode == "on" and _("开启") or _("关闭")
                return T(_("夜间模式（反色）：%1"), value)
            end,
            callback = function(menu) self:_pickNightMode(entry, menu) end,
            keep_menu_open = true,
        })
    end

    UIManager:show(Menu:new{
        title = _("编辑时间点"),
        item_table = items,
        show_parent = self.ui,
    })
end

function ScheduledDisplay:_deleteEntry(entry, parent)
    UIManager:show(ConfirmBox:new{
        text = T(_("确定删除 %1 的自动显示设置吗？"), clock(entry.time)),
        ok_text = _("删除"),
        cancel_text = _("取消"),
        ok_callback = function()
            local index = findEntry(self.schedule, entry)
            if not index then return end
            local old_state = effectiveState(self.schedule, nowMinutes())
            table.remove(self.schedule, index)
            self:save()
            if #self.schedule == 0 then
                self.enabled = false
                self:_cancelSchedule()
                self:_cancelRamp()
                self:save()
            elseif self.enabled then
                self:_setCurrentAndRefresh(old_state, parent)
            end
            if parent then parent:updateItems() end
        end,
    })
end

function ScheduledDisplay:_addEntry(parent)
    if #self.schedule >= MAX_ENTRIES then
        UIManager:show(InfoMessage:new{
            text = T(_("最多只能设置 %1 个时间点。"), MAX_ENTRIES),
            timeout = 2,
        })
        return
    end

    self:_timePicker(nowMinutes() - nowMinutes() % TIME_STEP_MIN, function(new_time)
        local existing = findTime(self.schedule, new_time)
        if existing then
            self:_editEntry(existing, parent)
            return
        end
        local old_state = effectiveState(self.schedule, nowMinutes())
        table.insert(self.schedule, {
            time = new_time,
            brightness = UNCHANGED,
            warmth = UNCHANGED,
            night_mode = UNCHANGED,
        })
        sortSchedule(self.schedule)
        self:save()
        if self.enabled then self:_setCurrentAndRefresh(old_state, parent) end
        local index = findTime(self.schedule, new_time)
        if index then self:_editEntry(index, parent) end
    end)
end

function ScheduledDisplay:_setEnabled(value, parent)
    self.enabled = value
    self:save()
    if self.enabled and #self.schedule > 0 then
        self:_applyCurrent(true)
        self:_reschedule()
    else
        self:_cancelSchedule()
        self:_cancelRamp()
    end
    if parent then parent:updateItems() end
end

function ScheduledDisplay:_hasAutoWarmthConflict()
    local active = G_reader_settings:readSetting("autowarmth_activate") or 0
    if active == 0 then return false end
    local warmth = G_reader_settings:nilOrTrue("autowarmth_control_warmth")
    local night = G_reader_settings:nilOrTrue("autowarmth_control_nightmode")
    local frontlight = G_reader_settings:isTrue("autowarmth_fl_off_during_day")
    return warmth or night or frontlight
end

function ScheduledDisplay:_currentSummary()
    local parts = {}
    if hasFrontlight() then table.insert(parts, T(_("亮度 %1"), self:_currentBrightness())) end
    if hasWarmth() then table.insert(parts, T(_("色温 %1"), self:_currentWarmth())) end
    if hasNightMode() then
        table.insert(parts, self:_currentNightMode() and _("反色开") or _("反色关"))
    end
    return table.concat(parts, " · ")
end

function ScheduledDisplay:getMenu()
    local menu = {
        {
            text_func = function()
                return self.enabled and _("自动调节：已启用") or _("自动调节：已停用")
            end,
            checked_func = function() return self.enabled end,
            callback = function(parent) self:_setEnabled(not self.enabled, parent) end,
            keep_menu_open = true,
        },
        {
            text = _("时间表"),
            enabled_func = function() return #self.schedule > 0 end,
            sub_item_table_func = function()
                local items = {}
                for _, entry in ipairs(self.schedule) do
                    local captured = entry
                    table.insert(items, {
                        text_func = function()
                            return clock(captured.time) .. "  " .. self:_stateSummary(captured)
                        end,
                        callback = function(parent)
                            local index = findEntry(self.schedule, captured)
                            if index then self:_editEntry(index, parent) end
                        end,
                        hold_callback = function(parent)
                            self:_deleteEntry(captured, parent)
                        end,
                    })
                end
                return items
            end,
        },
        {
            text_func = function()
                return T(_("添加时间点（%1/24）"), #self.schedule)
            end,
            enabled_func = function() return #self.schedule < MAX_ENTRIES end,
            callback = function(parent) self:_addEntry(parent) end,
        },
        {
            text_func = function()
                return self.smooth and _("亮度与色温变化：平滑") or _("亮度与色温变化：立即")
            end,
            checked_func = function() return self.smooth end,
            callback = function(parent)
                self.smooth = not self.smooth
                self:save()
                if parent then parent:updateItems() end
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                return T(_("变化时间：%1 秒"), self.smooth_duration)
            end,
            enabled_func = function() return self.smooth end,
            callback = function(parent)
                UIManager:show(SpinWidget:new{
                    title_text = _("平滑变化时间"),
                    info_text = _("亮度和色温同时完成过渡所需的时间。"),
                    value = self.smooth_duration,
                    value_min = SMOOTH_MIN_S,
                    value_max = SMOOTH_MAX_S,
                    value_step = SMOOTH_STEP_S,
                    value_hold_step = SMOOTH_STEP_S,
                    default_value = 5,
                    unit = C_("Time", "s"),
                    callback = function(spin)
                        if not spin then return end
                        self.smooth_duration = spin.value
                        self:save()
                        if parent then parent:updateItems() end
                    end,
                })
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                return self.notify and _("自动切换提示：已开启") or _("自动切换提示：已关闭")
            end,
            checked_func = function() return self.notify end,
            callback = function(parent)
                self.notify = not self.notify
                self:save()
                if parent then parent:updateItems() end
            end,
            keep_menu_open = true,
        },
        {
            text = _("立即应用当前时间表"),
            enabled_func = function() return #self.schedule > 0 end,
            callback = function() self:_applyCurrent(true) end,
        },
        {
            text_func = function()
                return T(_("当前显示状态：%1"), self:_currentSummary())
            end,
        },
    }

    if self:_hasAutoWarmthConflict() then
        table.insert(menu, 7, {
            text = _("提示：检测到 AutoWarmth 可能冲突"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("检测到 AutoWarmth 可能正在控制色温、夜间模式或前光。自动显示调节不会关闭或修改它，请避免两个时间表同时控制同一项目。"),
                    width = math.floor(Screen:getWidth() * 0.9),
                })
            end,
            keep_menu_open = true,
        })
    end

    return menu
end

function ScheduledDisplay:addToMainMenu(menu_items)
    menu_items.scheduleddisplay = {
        text = _("自动显示调节"),
        sorting_hint = "screen",
        checked_func = function() return self.enabled end,
        sub_item_table_func = function() return self:getMenu() end,
    }
end

function ScheduledDisplay:onInputEvent()
    if not self.ramp_task then return end

    local brightness_changed = self.ramp_expected_brightness ~= nil
        and hasFrontlight()
        and self:_currentBrightness() ~= self.ramp_expected_brightness
    local warmth_changed = self.ramp_expected_warmth ~= nil
        and hasWarmth()
        and self:_currentWarmth() ~= self.ramp_expected_warmth

    if brightness_changed or warmth_changed then
        self:_cancelRamp()
    end
end

function ScheduledDisplay:onSuspend()
    self:_cancelSchedule()
    self:_cancelRamp()
end

function ScheduledDisplay:onResume()
    if self.enabled and #self.schedule > 0 then
        self:_applyCurrent(false)
        self:_reschedule()
    end
end

function ScheduledDisplay:onCloseWidget()
    self:_cancelSchedule()
    self:_cancelRamp()
end

return ScheduledDisplay
