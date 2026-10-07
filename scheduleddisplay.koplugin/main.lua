local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
local SpinWidget = require("ui/widget/spinwidget")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local _ = require("gettext")
local T = require("ffi/util").template

local Powerd = Device:getPowerDevice()
local FILE = DataStorage:getSettingsDir() .. "/scheduleddisplay.lua"
local UNCHANGED = "unchanged"
local MAX = 24
local STEP = 5
local RAMP_MIN, RAMP_MAX, RAMP_STEP = 5, 60, 5
local RAMP_INTERVAL = 0.1

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(v) return math.floor(v + .5) end
local function now() local t=os.date("*t"); return t.hour*60+t.min end
local function clock(m) return string.format("%02d:%02d", math.floor(m/60),m%60) end
local function norm(v,max) return round(clamp(v,0,max)/max*100) end
local function native(v,max) if v==UNCHANGED or v==nil then return nil end return round(clamp(v,0,100)/100*max) end
local function hasWarmth() return Device:hasNaturalLight() end
local function hasNight() return Device.screen and type(Device.screen.toggleNightMode)=="function" end
local function sort(s) table.sort(s,function(a,b)return a.time<b.time end) end
local function find(s,t) for i,e in ipairs(s) do if e.time==t then return i end end end
local function effective(s,t)
    if #s==0 then return {} end
    local i=#s
    for n=#s,1,-1 do if s[n].time<=t then i=n;break end end
    local r={}; for off=0,#s-1 do
        local e=s[((i-1-off)%#s)+1]
        if r.brightness==nil and e.brightness~=UNCHANGED then r.brightness=e.brightness end
        if r.warmth==nil and e.warmth~=UNCHANGED then r.warmth=e.warmth end
        if r.night_mode==nil and e.night_mode~=UNCHANGED then r.night_mode=e.night_mode end
    end
    return r
end

local ScheduledDisplay = WidgetContainer:extend{name="scheduleddisplay",is_doc_only=false}

function ScheduledDisplay:init()
    self.settings=LuaSettings:open(FILE)
    self.enabled=self.settings:readSetting("enabled") or false
    self.schedule=self.settings:readSetting("schedule")
    self.smooth=self.settings:readSetting("smooth"); if self.smooth==nil then self.smooth=true end
    self.duration=self.settings:readSetting("smooth_duration") or 5
    self.notify=self.settings:readSetting("notify") or false
    if type(self.schedule)~="table" or #self.schedule==0 then self.schedule=self:defaultSchedule() end
    sort(self.schedule); self:save()
    self.ui.menu:registerToMainMenu(self)
    UIManager.event_hook:registerWidget("InputEvent",self)
    self:reschedule()
end

function ScheduledDisplay:defaultSchedule()
    local fl=Powerd.fl_max or 24; local w=Powerd.fl_warmth_max or 24
    return {
        {time=420,brightness=norm(18,fl),warmth=hasWarmth() and norm(6,w) or UNCHANGED,night_mode="off"},
        {time=1080,brightness=norm(12,fl),warmth=hasWarmth() and norm(18,w) or UNCHANGED,night_mode=UNCHANGED},
        {time=1380,brightness=norm(6,fl),warmth=UNCHANGED,night_mode="on"},
    }
end
function ScheduledDisplay:save()
    self.settings:saveSetting("enabled",self.enabled); self.settings:saveSetting("schedule",self.schedule)
    self.settings:saveSetting("smooth",self.smooth); self.settings:saveSetting("smooth_duration",self.duration)
    self.settings:saveSetting("notify",self.notify); self.settings:flush()
end
function ScheduledDisplay:cancelRamp()
    if self.ramp then UIManager:unschedule(self.ramp) end
    self.ramp=nil; self.expected_b=nil; self.expected_w=nil; self.ramp_token=(self.ramp_token or 0)+1
end
function ScheduledDisplay:apply(allow_smooth)
    local s=effective(self.schedule,now()); local tb=Device:hasFrontlight() and native(s.brightness,Powerd.fl_max) or nil
    local tw=hasWarmth() and native(s.warmth,Powerd.fl_warmth_max) or nil
    if not self.enabled and allow_smooth then return end
    self:cancelRamp()
    if hasNight() and s.night_mode~=nil and s.night_mode~=UNCHANGED then self.ui:handleEvent(Event:new("SetNightMode",s.night_mode=="on")) end
    local cb=Device:hasFrontlight() and Powerd:frontlightIntensity() or nil
    local cw=hasWarmth() and Powerd:toNativeWarmth(Powerd:frontlightWarmth()) or nil
    local nb=tb~=nil and cb~=tb; local nw=tw~=nil and cw~=tw
    if not nb and not nw then return end
    if not allow_smooth or not self.smooth then
        if nb then Powerd:setIntensity(tb,true) end
        if nw then Powerd:setWarmth(Powerd:fromNativeWarmth(tw)) end
        return
    end
    local from_b,to_b=cb,tb; local from_w,to_w=cw,tw
    local token=(self.ramp_token or 0)+1; self.ramp_token=token
    local start=UIManager:getElapsedTimeSinceBoot()
    self.ramp=function()
        if token~=self.ramp_token or not self.enabled then return end
        local p=clamp((UIManager:getElapsedTimeSinceBoot()-start)/self.duration,0,1)
        local e=.5-.5*math.cos(math.pi*p)
        if nb then local v=round(from_b+(to_b-from_b)*e); self.expected_b=v; Powerd:setIntensity(v,true) end
        if nw then local v=round(from_w+(to_w-from_w)*e); self.expected_w=v; Powerd:setWarmth(Powerd:fromNativeWarmth(v)) end
        if p>=1 then
            if nb then Powerd:setIntensity(to_b,true) end; if nw then Powerd:setWarmth(Powerd:fromNativeWarmth(to_w)) end
            self.ramp=nil;self.expected_b=nil;self.expected_w=nil
        else UIManager:scheduleIn(RAMP_INTERVAL,self.ramp,self) end
    end
    self.ramp()
end
function ScheduledDisplay:reschedule()
    if self.task then UIManager:unschedule(self.task);self.task=nil end
    if not self.enabled or #self.schedule==0 then return end
    local n=now(); local next_t=nil
    for _,e in ipairs(self.schedule) do if e.time>n then next_t=e.time;break end end
    if not next_t then next_t=self.schedule[1].time end
    local d=next_t-n;if d<=0 then d=d+1440 end
    self.task=function() self.task=nil;self:apply(true);if self.notify then UIManager:show(InfoMessage:new{text=_("自动显示调节：已应用当前时间点。"),timeout=2}) end;self:reschedule() end
    UIManager:scheduleIn(d*60-os.date("*t").sec,self.task,self)
end
function ScheduledDisplay:_summary(e)
    local p={}
    if Device:hasFrontlight() and e.brightness~=UNCHANGED then
        table.insert(p,T(_("亮度%1"),native(e.brightness,Powerd.fl_max)))
    end
    if hasWarmth() and e.warmth~=UNCHANGED then
        table.insert(p,T(_("色温%1"),native(e.warmth,Powerd.fl_warmth_max)))
    end
    if hasNight() and e.night_mode=="on" then
        table.insert(p,_("反色开"))
    elseif hasNight() and e.night_mode=="off" then
        table.insert(p,_("反色关"))
    end
    return #p>0 and table.concat(p,"·") or _("不调整")
end

function ScheduledDisplay:_buildScheduleItems()
    local items={{
        text=_("添加时间点"),
        enabled_func=function() return #self.schedule<MAX end,
        callback=function() self:_add() end,
    }}
    for _,e in ipairs(self.schedule) do
        local entry=e
        table.insert(items,{
            text=clock(entry.time).."  "..self:_summary(entry),
            callback=function() self:_edit(find(self.schedule,entry)) end,
            hold_callback=function() self:_delete(entry) end,
        })
    end
    return items
end

function ScheduledDisplay:_refreshScheduleMenu()
    local items=self:_buildScheduleItems()
    self.schedule_items=self.schedule_items or {}
    for i=#self.schedule_items,1,-1 do self.schedule_items[i]=nil end
    for i,item in ipairs(items) do self.schedule_items[i]=item end
    local menu=UIManager:getTopmostVisibleWidget()
    if menu and menu.item_table==self.schedule_items and type(menu.updateItems)=="function" then
        menu:updateItems()
    end
end


function ScheduledDisplay:_edit(i)
    local e=self.schedule[i]; if not e then return end
    local items={{text=T(_("时间：%1"),clock(e.time)),callback=function()
        self:_time(e.time,function(t)
            local old_i=find(self.schedule,e.time)
            local new_i=find(self.schedule,t)
            if new_i and new_i~=old_i then
                UIManager:show(InfoMessage:new{text=_("该时间点已存在。"),timeout=2})
                return
            end
            e.time=t
            sort(self.schedule)
            self:save()
            self:reschedule()
            self:_refreshScheduleMenu()
        end)
    end,keep_menu_open=true}}
    if Device:hasFrontlight() then
        table.insert(items,{text_func=function()
            return T(_("前光亮度：%1"),e.brightness==UNCHANGED and _("不调整") or native(e.brightness,Powerd.fl_max))
        end,callback=function() self:_number(e,"brightness",Powerd.fl_max) end,keep_menu_open=true})
    end
    if hasWarmth() then
        table.insert(items,{text_func=function()
            return T(_("色温：%1"),e.warmth==UNCHANGED and _("不调整") or native(e.warmth,Powerd.fl_warmth_max))
        end,callback=function() self:_number(e,"warmth",Powerd.fl_warmth_max) end,keep_menu_open=true})
    end
    if hasNight() then
        table.insert(items,{text_func=function()
            local v=e.night_mode==UNCHANGED and _("不调整") or e.night_mode=="on" and _("开启") or _("关闭")
            return T(_("夜间模式（反色）：%1"),v)
        end,callback=function() self:_night(e) end,keep_menu_open=true})
    end
    UIManager:show(Menu:new{title=_("编辑时间点"),item_table=items,show_parent=self.ui})
end


function ScheduledDisplay:_time(initial,cb)
    local h=math.floor(initial/60);local m=initial%60
    UIManager:show(SpinWidget:new{
        title_text=_("小时"),
        value=h,value_min=0,value_max=23,value_step=1,
        ok_always_enabled=true,
        callback=function(a)
            UIManager:show(SpinWidget:new{
                title_text=_("分钟"),
                value=m,value_min=0,value_max=55,value_step=5,
                ok_always_enabled=true,
                callback=function(b) cb(a.value*60+b.value) end,
            })
        end,
    })
end


function ScheduledDisplay:_number(e,key,max)
    local cur=e[key]==UNCHANGED and (key=="brightness" and Powerd:frontlightIntensity() or Powerd:toNativeWarmth(Powerd:frontlightWarmth())) or native(e[key],max)
    UIManager:show(SpinWidget:new{
        title_text=key=="brightness" and _("前光亮度") or _("色温"),
        value=cur or 0,value_min=0,value_max=max,value_step=1,
        extra_text=_("不调整"),
        extra_callback=function()
            e[key]=UNCHANGED
            self:save()
            if self.enabled then self:apply(true);self:reschedule() end
            self:_refreshScheduleMenu()
        end,
        callback=function(s)
            e[key]=norm(s.value,max)
            self:save()
            if self.enabled then self:apply(true);self:reschedule() end
            self:_refreshScheduleMenu()
        end,
    })
end


function ScheduledDisplay:_night(e)
    UIManager:show(RadioButtonWidget:new{
        title_text=_("夜间模式（反色）"),
        radio_buttons={
            {{text=_("不调整"),provider=UNCHANGED,checked=e.night_mode==UNCHANGED}},
            {{text=_("开启"),provider="on",checked=e.night_mode=="on"}},
            {{text=_("关闭"),provider="off",checked=e.night_mode=="off"}},
        },
        callback=function(w)
            e.night_mode=w.provider
            self:save()
            if self.enabled then self:apply(true);self:reschedule() end
            self:_refreshScheduleMenu()
        end,
    })
end


function ScheduledDisplay:_delete(e)
    UIManager:show(ConfirmBox:new{
        text=T(_("确定删除 %1 的自动显示设置吗？"),clock(e.time)),
        ok_text=_("删除"),cancel_text=_("取消"),
        ok_callback=function()
            for i,x in ipairs(self.schedule) do
                if x==e then table.remove(self.schedule,i);break end
            end
            if #self.schedule==0 then
                self.enabled=false
                self:cancelRamp()
            end
            self:save()
            self:reschedule()
            self:_refreshScheduleMenu()
        end,
    })
end


function ScheduledDisplay:_add()
    if #self.schedule>=MAX then
        UIManager:show(InfoMessage:new{text=T(_("最多只能设置 %1 个时间点。"),MAX),timeout=2})
        return
    end
    self:_time(now()-now()%STEP,function(t)
        local i=find(self.schedule,t)
        if i then
            self:_edit(i)
            return
        end
        local e={time=t,brightness=UNCHANGED,warmth=UNCHANGED,night_mode=UNCHANGED}
        table.insert(self.schedule,e)
        sort(self.schedule)
        self:save()
        self:_refreshScheduleMenu()
        self:_edit(find(self.schedule,t))
    end)
end


function ScheduledDisplay:_setEnabled(v,parent)
    self.enabled=v;self:save();if v then self:apply(true);self:reschedule()else self:cancelRamp();if self.task then UIManager:unschedule(self.task);self.task=nil end end;if parent then parent:updateItems()end
end
function ScheduledDisplay:hasAutoWarmthConflict()
    if not G_reader_settings then return false end
    local active=G_reader_settings:readSetting("autowarmth_activate") or 0
    if active==0 then return false end
    return G_reader_settings:nilOrTrue("autowarmth_control_warmth") or G_reader_settings:nilOrTrue("autowarmth_control_nightmode") or G_reader_settings:isTrue("autowarmth_fl_off_during_day")
end
function ScheduledDisplay:getMenu()
    self.schedule_items=self:_buildScheduleItems()
    local m={{
        text_func=function() return self.enabled and _("自动调节：已启用") or _("自动调节：已停用") end,
        checked_func=function() return self.enabled end,
        callback=function() self:_setEnabled(not self.enabled) end,
        keep_menu_open=true,
    },{
        text=_("时间表"),
        sub_item_table=self.schedule_items,
    },{
        text_func=function() return self.smooth and _("亮度与色温变化：平滑") or _("亮度与色温变化：立即") end,
        checked_func=function() return self.smooth end,
        callback=function()
            self.smooth=not self.smooth
            self:save()
            self:reschedule()
        end,
        keep_menu_open=true,
    },{
        text_func=function() return T(_("变化时间：%1 秒"),self.duration) end,
        enabled_func=function() return self.smooth end,
        callback=function()
            UIManager:show(SpinWidget:new{
                title_text=_("平滑变化时间"),
                value=self.duration,
                value_min=RAMP_MIN,value_max=RAMP_MAX,value_step=RAMP_STEP,
                value_hold_step=RAMP_STEP,
                default_value=5,
                default_text=_("默认值 5 秒"),
                callback=function(s)
                    self.duration=s.value
                    self:save()
                    self:reschedule()
                end,
            })
        end,
        keep_menu_open=true,
    },{
        text_func=function() return self.notify and _("自动切换提示：已开启") or _("自动切换提示：已关闭") end,
        checked_func=function() return self.notify end,
        callback=function()
            self.notify=not self.notify
            self:save()
        end,
        keep_menu_open=true,
    }}
    if self:hasAutoWarmthConflict() then
        table.insert(m,1,{
            text=_("提示：AutoWarmth 可能正在控制显示参数"),
            callback=function()
                UIManager:show(InfoMessage:new{text=_("检测到 AutoWarmth 已启用。自动显示调节不会关闭或修改它，请避免两个时间表同时控制同一参数。"),timeout=4})
            end,
            keep_menu_open=true,
        })
    end
    return m
end


function ScheduledDisplay:addToMainMenu(items)
    items.scheduleddisplay={
        text=_("自动显示调节"),
        sorting_hint="screen",
        checked_func=function() return self.enabled end,
        sub_item_table=self:getMenu(),
    }
end


function ScheduledDisplay:onInputEvent()
    if not self.ramp then return end
    local b=Device:hasFrontlight() and self.expected_b~=nil and Powerd:frontlightIntensity()~=self.expected_b
    local w=hasWarmth() and self.expected_w~=nil and Powerd:toNativeWarmth(Powerd:frontlightWarmth())~=self.expected_w
    if b or w then self:cancelRamp() end
end
function ScheduledDisplay:onSuspend()self:cancelRamp();if self.task then UIManager:unschedule(self.task);self.task=nil end end
function ScheduledDisplay:onResume()if self.enabled then self:apply(false);self:reschedule()end end
function ScheduledDisplay:onCloseWidget()self:onSuspend()end
return ScheduledDisplay
