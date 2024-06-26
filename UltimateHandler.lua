-- The Ultimate Protocol
-- *bitArray* flags, *uint8* ultimate[, *uint8* ultimateCost[, *uint8 ultimateIndex]]
-- flags:
--   1: isFullUpdate - the user is sending cost in addition to percentages in this packet
--   2: requestsFullUpdate - the user does not have all the necessary data and wants to have a full update from everyone (e.g. after reloading the ui)

local LGS = LibStub("LibGroupSocket", true)
if not LGS then return end
LGS.MESSAGE_TYPE_ULTIMATE = 21 -- aka, the code for 'u'
local type, version = LGS.MESSAGE_TYPE_ULTIMATE, 2
local handler, saveData = LGS:RegisterHandler(type, version)
if(not handler) then return end
local SKIP_CREATE = true
local ON_ULTIMATE_CHANGED = "OnUltimateChanged"
local MIN_SEND_TIMEOUT = 2
local MIN_COMBAT_SEND_TIMEOUT = 1
local Log = LGS.Log

handler.resources = {}
local resources = handler.resources
local sendFullUpdate = true
local needFullUpdate = true
local ultimateCost = 255
local lastSendTime = 0
local defaultData = {
    version = 1,
    enabled = true,
}
handler.callbacks = handler.callbacks or 0
handler.debug = 0

local function GetCachedUnitResources(unitTag, skipCreate)
    local unitName = GetUnitName(unitTag)
    local unitResources = resources[unitName]
    if(not unitResources and not skipCreate) then
        resources[unitName] = {
            [POWERTYPE_ULTIMATE] = {current=0, cost=255},
            lastUpdate = 0,
        }
        unitResources = resources[unitName]
    end
    return unitResources
end

function handler:SetDebug(dbg)
    handler.debug = dbg
end

function handler:ResetResources()
    handler.resources = {}
end

function handler:GetLastUpdateTime(unitTag)
    local unitResources = GetCachedUnitResources(unitTag, SKIP_CREATE)
    if(unitResources) then return unitResources.lastUpdate end
    return -1
end

function handler:SetUltimateCost(cost)
    if cost > 0 and cost <= 255 then
        ultimateCost = cost
    end
end

local function OnData(unitTag, data, isSelf)
    if (handler.callbacks == 0) then
        if (handler.debug > 0) then
			Log("handler.callback == 0")
        end
        return
    end --dont do anything if nobody is using this handler
    if (handler.debug == 3) then
        Log("OnData")
    end
    local index, bitIndex = 1, 1
    local isFullUpdate, index, bitIndex = LGS:ReadBit(data, index, bitIndex)
    local requestsFullUpdate, index, bitIndex = LGS:ReadBit(data, index, bitIndex)

    if (handler.debug == 1) then
        Log("OnData %s (%d byte): is full: %s, needs full: %s", GetUnitName(unitTag), #data, tostring(isFullUpdate), tostring(requestsFullUpdate))
    end
    index = index + 1
    if(not isSelf and requestsFullUpdate) then
        sendFullUpdate = true
    end

    local expectedLength = isFullUpdate and 3 or 2
    if(#data < expectedLength) then Log("UltimateHandler received only %d of %d byte", #data, expectedLength) return end

    local unitResources = GetCachedUnitResources(unitTag)
    local ultimate = unitResources[POWERTYPE_ULTIMATE]
    ultimate.current, index = LGS:ReadUint8(data, index)
    if(isFullUpdate) then
        ultimate.cost, index = LGS:ReadUint8(data, index)
    end

    unitResources.lastUpdate = GetTimeStamp()

    --	Log("ultimate: %d, cost: %d", ultimate.current, ultimate.cost)
    LGS.cm:FireCallbacks(ON_ULTIMATE_CHANGED, unitTag, ultimate.current, ultimate.cost, isSelf)
end

local function NumCallbacks()
    local registry = LGS.cm.callbackRegistry[ON_ULTIMATE_CHANGED]
    handler.callbacks = registry and #registry or 0
end

local function GetPowerValues(unitResources, powerType)
    local data = unitResources[powerType]
    local current, maximum = GetUnitPower("player", powerType)
    return data, current, 255 -- use hardcoded value since no ulti has higher cost
end

function handler:Send()
    if (handler.debug == 3) then
        Log("Send")
    end
    if(not saveData.enabled or not IsUnitGrouped("player")) then return end
    if (handler.debug == 3) then
        Log("...")
    end
    local now = GetTimeStamp()
    local timeout = IsUnitInCombat("player") and MIN_COMBAT_SEND_TIMEOUT or MIN_SEND_TIMEOUT
    if(now - lastSendTime < timeout) then
        if (handler.debug == 2) then
            d("now("..now..") - lastSendTime("..lastSendTime..") < timeout("..timeout..")")
	end
        return
    end

    local unitResources = GetCachedUnitResources("player")
    local ultimate, ultimateCurrent, ultimateMaximum = GetPowerValues(unitResources, POWERTYPE_ULTIMATE)
    ultimateCurrent = zo_min(ultimateCurrent, ultimateMaximum)

    sendFullUpdate = sendFullUpdate or ultimate.cost ~= ultimateCost
    if(ultimate.current ~= ultimateCurrent or sendFullUpdate) then
        local data = {}
        local index, bitIndex = 1, 1
        index, bitIndex = LGS:WriteBit(data, index, bitIndex, sendFullUpdate)
        index, bitIndex = LGS:WriteBit(data, index, bitIndex, needFullUpdate)
        index = index + 1
        index = LGS:WriteUint8(data, index, ultimateCurrent)
        if sendFullUpdate then
            index = LGS:WriteUint8(data, index, ultimateCost)
        end
        if (handler.debug == 1) then
            Log("Send %d byte: is full: %s, needs full: %s, ultimate: %s, cost: %s", #data, tostring(sendFullUpdate), tostring(needFullUpdate), tostring(ultimateCurrent), tostring(ultimateCost))
        end
        if(LGS:Send(type, data)) then
			--	Log("Send Complete")
            lastSendTime = now
            ultimate.current = ultimateCurrent
            if sendFullUpdate then
                ultimate.cost = ultimateCost
            end
            sendFullUpdate = false
            needFullUpdate = false
        else
            if (handler.debug == 2) then
                Log("Send failed")
            end
        end
    end
end

function handler:Refresh()
    sendFullUpdate = true
    needFullUpdate = true
end

local function OnUpdate()
    handler:Send()
end

local isActive = false

local function StartSending()
    if(not isActive and saveData.enabled and IsUnitGrouped("player")) then
        if (handler.debug > 0) then
            Log("StartSending .. isActive")
        end
        EVENT_MANAGER:RegisterForUpdate("LibGroupSocketUltimateHandlerUpdate", 1000, OnUpdate)
        isActive = true
    end
    if (handler.debug == 3) then
        Log("StartSending: isActive: %s", tostring(isActive))
    end
end

local function StopSending()
    if(isActive) then
        EVENT_MANAGER:UnregisterForUpdate("LibGroupSocketUltimateHandlerUpdate")
        isActive = false
    end
end

local function OnUnitCreated(_, unitTag)
    if (handler.debug == 2) then
        Log("OnUnitCreated: %s", unitTag)
    end
    if (not isActive and handler.callbacks) then
        sendFullUpdate = true
        StartSending()
    end
end

local function OnUnitDestroyed(_, unitTag)
    if (handler.debug == 2) then
        Log("OnUnitDestroyed: %s isActive: %s unitGrouped %s", unitTag, tostring(isActive), tostring(IsUnitGrouped("player")))
    end
    resources[GetUnitName(unitTag)] = nil
    if(isActive and not IsUnitGrouped("player")) then
        StopSending()
    end
end

function handler:RegisterForUltimateChanges(callback)
    if (handler.debug == 1) then
        Log("RegisterForUltimateChanges %s", tostring(isActive))
    end
    if (not handler.callback) then
        LGS.cm:RegisterCallback(ON_ULTIMATE_CHANGED, callback)
        NumCallbacks()
        LGS.cm:RegisterCallback(type, OnData)
    end
    if (not isActive) then
        StartSending()
    end
end

function handler:UnregisterForUltimateChanges(callback)
    if (handler.debug == 1) then
        Log ("UnregisterForUltimateChanges %s", tostring(isActive))
    end
    if (handler.callback) then
        LGS.cm:UnregisterCallback(type, handler.dataHandler)
	LGS.cm:UnregisterCallback(ON_ULTIMATE_CHANGED, callback)
	NumCallbacks()
    end
    if (isActive) then
        StopSending()
    end
end

function handler:InitializeSettings(optionsData, IsSendingDisabled) -- TODO: localization
    optionsData[#optionsData + 1] = {
        type = "header",
        name = "Ultimate Handler",
    }
	optionsData[#optionsData + 1] = {
		type = "checkbox",
		name = "Enable sending",
		tooltip = "Controls if the handler does send data. It will still receive and process incoming data.",
		getFunc = function() return saveData.enabled end,
		setFunc = function(value)
			saveData.enabled = value
			if(value) then StartSending() else StopSending() end
		end,
		disabled = IsSendingDisabled,
		default = defaultData.enabled
	}
end

-- savedata becomes available twice in case the standalone lib is loaded
local function InitializeSaveData(data)
    saveData = data

    if(not saveData.version) then
        ZO_DeepTableCopy(defaultData, saveData)
    end

    --  if(saveData.version == 1) then
    --      -- update it
    --  end
end

local function Unload()
    LGS.cm:UnregisterCallback("savedata-ready", InitializeSaveData)
    EVENT_MANAGER:UnregisterForEvent("LibGroupSocketUltimateHandler", EVENT_PLAYER_ACTIVATED)
    EVENT_MANAGER:UnregisterForEvent("LibGroupSocketUltimateHandler", EVENT_UNIT_CREATED)
    EVENT_MANAGER:UnregisterForEvent("LibGroupSocketUltimateHandler", EVENT_UNIT_DESTROYED)
    StopSending();
end

local function Load()
    InitializeSaveData(saveData)
    LGS.cm:RegisterCallback("savedata-ready", function(data)
        InitializeSaveData(data.handlers[type])
    end)

    handler.dataHandler = OnData
    handler.Unload = Unload
    EVENT_MANAGER:RegisterForEvent("LibGroupSocketUltimateHandler", EVENT_UNIT_CREATED, OnUnitCreated)
    EVENT_MANAGER:AddFilterForEvent("LibGroupSocketUltimateHandler",EVENT_UNIT_CREATED, REGISTER_FILTER_UNIT_TAG_PREFIX, "group")
    EVENT_MANAGER:RegisterForEvent("LibGroupSocketUltimateHandler", EVENT_UNIT_DESTROYED, OnUnitDestroyed)
    EVENT_MANAGER:AddFilterForEvent("LibGroupSocketUltimateHandler",EVENT_UNIT_DESTROYED, REGISTER_FILTER_UNIT_TAG_PREFIX, "group")

    EVENT_MANAGER:RegisterForEvent("LibGroupSocketUltimateHandler", EVENT_PLAYER_ACTIVATED, function()
        StartSending()
    end)
end

if(handler.Unload) then handler.Unload() end
Load()
