-- [[ FIESTA FARM V2 - OPTIMIZED & SAFE EDITION ]] --

if _G.FiestaFarmLoaded then
    warn("Fiesta Farm is already running! Please use the 'Unload Script' button first.")
    return
end
_G.FiestaFarmLoaded = true

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local ClientLib = ReplicatedStorage:WaitForChild("Library"):WaitForChild("Client")
local Lib = ReplicatedStorage:WaitForChild("Library")

local function need(name)
    local child = ClientLib:FindFirstChild(name)
    if not child then return nil end
    local ok, mod = pcall(require, child)
    return ok and mod or nil
end

local function needAt(parent, name)
    local child = parent and parent:FindFirstChild(name)
    if not child then return nil end
    local ok, mod = pcall(require, child)
    return ok and mod or nil
end

-- Module Loading
local Network        = need("Network")
local FFlags         = need("FFlags")
local PlayerPet      = need("PlayerPet")
local MapCmds        = need("MapCmds")
local InstancingCmds = need("InstancingCmds")
local EventUpgrades  = need("EventUpgradeCmds")
local RaidCmds       = need("RaidCmds")
local FiestaMazeCmds = need("FiestaMazeCmds")
local EnchantCmds    = need("EnchantCmds")
local InventoryCmds  = need("InventoryCmds")

local FiestaUpgrades = needAt(Lib:FindFirstChild("Util"), "FiestaUpgrades")
local UpgradeDir     = needAt(Lib:FindFirstChild("Directory"), "EventUpgrades")
local CurrencyItem   = needAt(Lib:FindFirstChild("Items"), "CurrencyItem")
local RaidTypes      = needAt(Lib:FindFirstChild("Types"), "Raids")
local BreakableTypes = needAt(Lib:FindFirstChild("Types"), "Breakables")
local TeleportTo     = needAt(Lib:FindFirstChild("Functions"), "TeleportCharacterTo")
local ItemsLib       = needAt(Lib, "Items")
local PetsDir        = needAt(Lib:FindFirstChild("Directory"), "Pets")
local Constants      = needAt(Lib:FindFirstChild("Balancing"), "Constants")

local ClientRaid = (function()
    local rc = ClientLib:FindFirstChild("RaidCmds")
    local child = rc and rc:FindFirstChild("ClientRaidInstance")
    return child and (pcall(require, child) and require(child) or nil) or nil
end)()

local Orb = (function()
    local oc = ClientLib:FindFirstChild("OrbCmds")
    local child = oc and oc:FindFirstChild("Orb")
    return child and (pcall(require, child) and require(child) or nil) or nil
end)()

local ParentType = (BreakableTypes and BreakableTypes.ParentType) or { Zone = 1, Instance = 2, Plaza = 3 }
local P_ZONE, P_INSTANCE, P_PLAZA = ParentType.Zone, ParentType.Instance, ParentType.Plaza

if not Network then error("[Fiesta V2] Network module missing!") end

-- Configs & State
local TAP_RATE = 30
local PET_SPEED_MULT = 100
local MAX_TARGETS_PER_TICK = 15 -- Anti-kick optimization

local CFG = {
    autoTap = false, sendPets = true, petSpeed = false, autoOrbs = false,
    autoJoin = false, instanceId = "FiestaLobby", autoMaze = false,
    autoUpgrade = false, wanted = {}
}

local Threads = {}
local Hooks = {
    originalCalcSpeed = nil,
    origPickupDistance = nil,
    origEnchantPower = nil
}

-- Thread Manager (Memory Leak Prevention)
local function startThread(name, func)
    if Threads[name] then task.cancel(Threads[name]) end
    Threads[name] = task.spawn(func)
end

local function stopThread(name)
    if Threads[name] then 
        task.cancel(Threads[name])
        Threads[name] = nil 
    end
end

-- =========================================================================
-- Targeting & Breakables
-- =========================================================================
local breakFolder
local function breakableModels()
    if not (breakFolder and breakFolder.Parent) then
        local things = workspace:FindFirstChild("__THINGS")
        breakFolder = things and things:FindFirstChild("Breakables")
    end
    return breakFolder and breakFolder:GetChildren() or {}
end

local function currentZoneId()
    return MapCmds and (pcall(MapCmds.GetCurrentZone) and MapCmds.GetCurrentZone() or nil) or nil
end

local function currentInstanceId()
    return InstancingCmds and (pcall(InstancingCmds.GetInstanceID) and InstancingCmds.GetInstanceID() or nil) or nil
end

local function myPosition()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position or nil
end

local function canDamage(model, zoneId, instanceId)
    local pType = model:GetAttribute("ParentType")
    local pId = model:GetAttribute("ParentID")

    if pType == P_INSTANCE then return instanceId ~= nil and pId == instanceId end
    if pType == P_ZONE then
        if model:GetAttribute("VIPBreakable") or instanceId then return false end
        return zoneId == nil or pId == zoneId
    end
    if pType == P_PLAZA then return false end
    return pId == nil or zoneId == nil or pId == zoneId or pId == instanceId
end

local function collectTargets()
    local zoneId, instanceId = currentZoneId(), currentInstanceId()
    local pos = myPosition()
    local out = {}

    for _, model in ipairs(breakableModels()) do
        local uid = model:GetAttribute("BreakableUID")
        if uid and model:IsA("Model") and canDamage(model, zoneId, instanceId) then
            local dist = pos and pcall(model.GetPivot, model) and (model:GetPivot().Position - pos).Magnitude or 0
            table.insert(out, { uid = uid, model = model, dist = dist })
        end
    end

    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- =========================================================================
-- Automation Core
-- =========================================================================
local function tap(uid)
    if Network.UnreliableFire then
        pcall(Network.UnreliableFire, "Breakables_PlayerDealDamage", uid)
    else
        pcall(Network.Fire, "Breakables_PlayerDealDamage", uid)
    end
end

local function assignPets(model)
    if not (PlayerPet and CFG.sendPets and model) then return end
    local ok, pets = pcall(PlayerPet.GetByPlayer, LocalPlayer)
    if ok and type(pets) == "table" then
        for _, pet in pairs(pets) do pcall(function() pet:SetTarget(model) end) end
    end
end

local function startAutoTap()
    startThread("tap", function()
        local petTick = 0
        while true do
            pcall(function()
                local targets = collectTargets()
                local hitCount = math.min(#targets, MAX_TARGETS_PER_TICK)

                for i = 1, hitCount do tap(targets[i].uid) end

                petTick += 1
                if petTick >= 15 and hitCount > 0 then
                    petTick = 0
                    assignPets(targets[1].model)
                end
            end)
            task.wait(1 / TAP_RATE)
        end
    end)
end

-- Hook Manager (Restorable)
local function setPetSpeed(enabled)
    if not PlayerPet or not PlayerPet.CalculateSpeedMultiplier then return end
    if enabled then
        if not Hooks.originalCalcSpeed then
            Hooks.originalCalcSpeed = PlayerPet.CalculateSpeedMultiplier
            PlayerPet.CalculateSpeedMultiplier = function(self, ...)
                local ok, base = pcall(Hooks.originalCalcSpeed, self, ...)
                return (ok and type(base) == "number" and base or 1) * PET_SPEED_MULT
            end
        end
        startThread("petSpeedPush", function()
            while true do
                pcall(function()
                    for _, pet in pairs(PlayerPet.GetByPlayer(LocalPlayer)) do
                        local mult = pet:CalculateSpeedMultiplier()
                        pet.speedMult = mult
                        pet.cpet:Broadcast("petSpeedMult", mult)
                    end
                end)
                task.wait(0.5)
            end
        end)
    else
        stopThread("petSpeedPush")
        if Hooks.originalCalcSpeed then
            PlayerPet.CalculateSpeedMultiplier = Hooks.originalCalcSpeed
            Hooks.originalCalcSpeed = nil
        end
    end
end

local function setAutoOrbs(enabled)
    if enabled then
        if Orb and not Hooks.origPickupDistance then
            Hooks.origPickupDistance = Orb.DefaultPickupDistance
            pcall(function() Orb.DefaultPickupDistance = 100000 end)
        end
        if EnchantCmds and not Hooks.origEnchantPower then
            Hooks.origEnchantPower = EnchantCmds.GetPower
            EnchantCmds.GetPower = function(name, ...)
                if name == "Super Magnet" then
                    local ok, base = pcall(Hooks.origEnchantPower, name, ...)
                    return math.max((ok and type(base) == "number" and base or 0), 1)
                end
                return Hooks.origEnchantPower(name, ...)
            end
        end
    else
        if Hooks.origPickupDistance then pcall(function() Orb.DefaultPickupDistance = Hooks.origPickupDistance end); Hooks.origPickupDistance = nil end
        if Hooks.origEnchantPower then pcall(function() EnchantCmds.GetPower = Hooks.origEnchantPower end); Hooks.origEnchantPower = nil end
    end
end

-- UI Setup
local Weave = loadstring(game:HttpGet("https://raw.githubusercontent.com/SvenaEE/Testlibary-/refs/heads/main/Weave-Release"))()

local Window = Weave:CreateWindow({
    Name = "Fiesta Farm V2",
    LoadingSubtitle = "Optimized for PS99",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
    ToggleKey = Enum.KeyCode.RightShift,
})

local MainTab = Window:CreateTab("Farm", "skull", { "Tapping", "Misc" })

local TapSec = MainTab:CreateSection({ Name = "Auto Tap", Side = "left", Subtab = "Tapping" })
TapSec:CreateToggle({
    Name = "Auto Tap",
    CurrentValue = false,
    Callback = function(v) CFG.autoTap = v; if v then startAutoTap() else stopThread("tap") end end,
})
TapSec:CreateToggle({ Name = "Send pets to targets", CurrentValue = true, Callback = function(v) CFG.sendPets = v end })
TapSec:CreateToggle({
    Name = "Infinite Pet Speed",
    CurrentValue = false,
    Callback = function(v) CFG.petSpeed = v; setPetSpeed(v) end,
})
TapSec:CreateToggle({
    Name = "Auto Collect Orbs (Super Magnet)",
    CurrentValue = false,
    Callback = function(v) CFG.autoOrbs = v; setAutoOrbs(v) end,
})

local MiscSec = MainTab:CreateSection({ Name = "Script Controls", Side = "right", Subtab = "Misc" })
MiscSec:CreateParagraph({ Title = "Safety Check", Content = "Max Targets per tick limited to " .. MAX_TARGETS_PER_TICK .. " to prevent network kicks." })
MiscSec:CreateButton({
    Name = "Unload Script (Panic Button)",
    Callback = function()
        -- Stop all loops safely
        for name in pairs(Threads) do stopThread(name) end
        
        -- Restore game functions
        setPetSpeed(false)
        setAutoOrbs(false)
        
        _G.FiestaFarmLoaded = false
        Weave:Destroy()
    end,
})

Weave:Notify({ Title = "Fiesta Farm V2", Content = "Successfully loaded and optimized!", Duration = 5 })
