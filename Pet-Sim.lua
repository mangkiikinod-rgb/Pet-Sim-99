-- [[ FIESTA FARM V2 - FULL FEATURED & OPTIMIZED EDITION ]] --

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

-- Configs & State
local TAP_RATE = 30
local PET_SPEED_MULT = 100
local MAX_TARGETS_PER_TICK = 15 -- Anti-kick optimization
local UPGRADE_IDS = (FiestaUpgrades and FiestaUpgrades.PurchasableOrder) or { "FiestaDamage", "FiestaSmashSpeed", "FiestaPets", "FiestaKeyDrops" }

local CFG = {
    autoTap = false, sendPets = true, petSpeed = false, autoOrbs = false,
    autoJoin = false, instanceId = "FiestaLobby", autoMaze = false,
    autoUpgrade = false, wanted = {}
}

local Threads = {}
local Hooks = {
    originalCalcSpeed = nil, origPickupDistance = nil, origEnchantPower = nil
}

local Weave = loadstring(game:HttpGet("https://raw.githubusercontent.com/SvenaEE/Testlibary-/refs/heads/main/Weave-Release"))()

-- =========================================================================
-- Engine: Thread Manager
-- =========================================================================
local function startThread(name, func)
    if Threads[name] then task.cancel(Threads[name]) end
    Threads[name] = task.spawn(func)
end

local function stopThread(name)
    if Threads[name] then task.cancel(Threads[name]); Threads[name] = nil end
end

-- =========================================================================
-- Engine: Target Discovery
-- =========================================================================
local breakFolder
local function breakableModels()
    if not (breakFolder and breakFolder.Parent) then
        local things = workspace:FindFirstChild("__THINGS")
        breakFolder = things and things:FindFirstChild("Breakables")
    end
    return breakFolder and breakFolder:GetChildren() or {}
end

local function currentZoneId() return MapCmds and pcall(MapCmds.GetCurrentZone) and MapCmds.GetCurrentZone() or nil end
local function currentInstanceId() return InstancingCmds and pcall(InstancingCmds.GetInstanceID) and InstancingCmds.GetInstanceID() or nil end
local function myPosition() return LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") and LocalPlayer.Character.HumanoidRootPart.Position or nil end
local function currentRaid() return ClientRaid and pcall(ClientRaid.GetCurrent) and ClientRaid.GetCurrent() or nil end
local function inInstance() return InstancingCmds and pcall(InstancingCmds.IsInInstance) and InstancingCmds.IsInInstance() or false end

local function canDamage(model, zoneId, instanceId)
    local pType, pId = model:GetAttribute("ParentType"), model:GetAttribute("ParentID")
    if pType == P_INSTANCE then return instanceId ~= nil and pId == instanceId end
    if pType == P_ZONE then return not model:GetAttribute("VIPBreakable") and not instanceId and (zoneId == nil or pId == zoneId) end
    if pType == P_PLAZA then return false end
    return pId == nil or zoneId == nil or pId == zoneId or pId == instanceId
end

local function collectTargets()
    local zoneId, instanceId, pos = currentZoneId(), currentInstanceId(), myPosition()
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
-- Feature 1: Tapping & Pets
-- =========================================================================
local function tap(uid)
    if Network.UnreliableFire then pcall(Network.UnreliableFire, "Breakables_PlayerDealDamage", uid)
    else pcall(Network.Fire, "Breakables_PlayerDealDamage", uid) end
end

local function assignPets(model)
    if not (PlayerPet and CFG.sendPets and model) then return end
    local ok, pets = pcall(PlayerPet.GetByPlayer, LocalPlayer)
    if ok and type(pets) == "table" then
        for _, pet in pairs(pets) do pcall(function() pet:SetTarget(model) end) end
    end
end

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
            while task.wait(0.5) do
                pcall(function()
                    for _, pet in pairs(PlayerPet.GetByPlayer(LocalPlayer)) do
                        local mult = pet:CalculateSpeedMultiplier()
                        pet.speedMult = mult
                        pet.cpet:Broadcast("petSpeedMult", mult)
                    end
                end)
            end
        end)
    else
        stopThread("petSpeedPush")
        if Hooks.originalCalcSpeed then PlayerPet.CalculateSpeedMultiplier = Hooks.originalCalcSpeed; Hooks.originalCalcSpeed = nil end
    end
end

local function setAutoOrbs(enabled)
    if enabled then
        if Orb and not Hooks.origPickupDistance then
            Hooks.origPickupDistance = Orb.DefaultPickupDistance; pcall(function() Orb.DefaultPickupDistance = 100000 end)
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

-- =========================================================================
-- Feature 2: Auto Maze & Auto Join
-- =========================================================================
local mazeStatus = "idle"

local function openAllChests(raid)
    raid = raid or currentRaid()
    local ct = raid and raid._ct
    if not (ct and RaidTypes and RaidTypes.ChestDirectory) then return 0 end
    local opened = 0
    for key, chest in pairs(RaidTypes.ChestDirectory) do
        if not chest.Retired then
            local ok, res = pcall(Network.Invoke, "Raids_CollectReward", key, ct)
            if ok and res then opened += 1 end
        end
    end
    return opened
end

local function startRun()
    if not (RaidCmds and RaidCmds.Create) then return false end
    if inInstance() and InstancingCmds and InstancingCmds.Leave then pcall(InstancingCmds.Leave, false, true); task.wait(2) end
    for i = 1, 10 do
        if pcall(ClientRaid.GetByPortal, i) == false then
            local ok, res, _, raid = pcall(RaidCmds.Create, { Portal = i, Difficulty = 1, PartyMode = RaidTypes and RaidTypes.PartyMode and RaidTypes.PartyMode.Solo })
            if ok and res and raid then return pcall(raid.Join, raid) end
        end
    end
    return false
end

local function autoMazeLoop()
    local cleared = false
    while task.wait(1) do
        pcall(function()
            local raid = currentRaid()
            if not raid then
                mazeStatus = "Starting Run..."
                if startRun() then task.wait(2) end
                cleared = false
                return
            end
            
            if raid.IsComplete and raid:IsComplete() then
                if not cleared then
                    cleared = true
                    mazeStatus = "Run complete! Claiming..."
                    local n = openAllChests(raid)
                    Weave:Notify({Title = "Fiesta Farm", Content = "Maze done! Opened " .. n .. " chests.", Duration = 4})
                    task.wait(3)
                else
                    mazeStatus = "Restarting..."
                    startRun(); task.wait(3)
                end
            else
                local room = raid.GetRoomNumber and raid:GetRoomNumber() or "?"
                mazeStatus = "Farming Room: " .. tostring(room)
                
                -- Teleport to room to trigger spawn
                if FiestaMazeCmds and FiestaMazeCmds.PathCellModel then
                    local cell = FiestaMazeCmds.PathCellModel(room)
                    if cell and TeleportTo then pcall(TeleportTo, cell:GetPivot().Position) end
                end
            end
        end)
    end
end

-- =========================================================================
-- Feature 3: Auto Upgrades
-- =========================================================================
local function upgradeTier(id) return EventUpgrades and pcall(EventUpgrades.GetTier, id) and EventUpgrades.GetTier(id) or 0 end
local function isMaxxed(id) local def = UpgradeDir and UpgradeDir[id]; return def and upgradeTier(id) >= #def.TierPowers end
local function nextCost(id)
    local def = UpgradeDir and UpgradeDir[id]
    if not def then return nil end
    local entry = def.TierCosts[upgradeTier(id) + 1]
    return entry and entry:Clone() or nil
end

local function autoUpgradeLoop()
    while task.wait(3) do
        pcall(function()
            for _, id in ipairs(UPGRADE_IDS) do
                if CFG.wanted[id] and not isMaxxed(id) then
                    local costItem = nextCost(id)
                    if costItem and costItem:CountAny() >= costItem:GetAmount() then
                        pcall(EventUpgrades.Purchase, id)
                        task.wait(0.5)
                    end
                end
            end
        end)
    end
end

-- =========================================================================
-- Feature 4: Pet Spawner (Visual & Fake Inv)
-- =========================================================================
local spawnedPets = {}
local fakeUids = {}
local orbitConn

local function inventoryContainer() return InventoryCmds and pcall(InventoryCmds.Container) and InventoryCmds.Container() or nil end
local function refreshInventoryGUI(container) if container and container.Updated then pcall(function() container.Updated:FireAsync(container._store) end) end end

local function clearPets()
    if orbitConn then orbitConn:Disconnect(); orbitConn = nil end
    local container = inventoryContainer()
    for _, e in ipairs(spawnedPets) do
        if e.inst then pcall(e.inst.Destroy, e.inst) end
        if e.uid and container then pcall(container._store.SetReference, container._store, e.uid, nil) end
    end
    spawnedPets = {}
    fakeUids = {}
    refreshInventoryGUI(container)
end

-- =========================================================================
-- Build UI & Hook Everything Up
-- =========================================================================
local Window = Weave:CreateWindow({
    Name = "Fiesta Farm V2 FULL",
    LoadingSubtitle = "All Features + Anti-Lag",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
    ToggleKey = Enum.KeyCode.RightShift,
})

-- MAIN TAB
local MainTab = Window:CreateTab("Farm", "skull", { "Tapping", "Event", "Upgrades", "Misc" })

local TapSec = MainTab:CreateSection({ Name = "Auto Tap", Side = "left", Subtab = "Tapping" })
TapSec:CreateToggle({
    Name = "Auto Tap (Safe Limits)",
    CurrentValue = false,
    Callback = function(v) 
        CFG.autoTap = v
        if v then
            startThread("tap", function()
                while task.wait(1/TAP_RATE) do
                    pcall(function()
                        local targets = collectTargets()
                        local hitCount = math.min(#targets, MAX_TARGETS_PER_TICK)
                        for i = 1, hitCount do tap(targets[i].uid) end
                        if hitCount > 0 and math.random(1,15) == 1 then assignPets(targets[1].model) end
                    end)
                end
            end)
        else stopThread("tap") end
    end,
})
TapSec:CreateToggle({ Name = "Infinite Pet Speed", CurrentValue = false, Callback = function(v) setPetSpeed(v) end })
TapSec:CreateToggle({ Name = "Auto Collect Orbs (Hook)", CurrentValue = false, Callback = function(v) setAutoOrbs(v) end })

local MazeSec = MainTab:CreateSection({ Name = "Fiesta Maze", Side = "right", Subtab = "Event" })
MazeSec:CreateToggle({
    Name = "Auto Join Lobby",
    CurrentValue = false,
    Callback = function(v)
        if v then startThread("autoJoin", function() while task.wait(5) do if not inInstance() and not currentRaid() then pcall(InstancingCmds.Enter, CFG.instanceId) end end end)
        else stopThread("autoJoin") end
    end
})
MazeSec:CreateToggle({
    Name = "AutoFarm Maze (Full Run)",
    CurrentValue = false,
    Callback = function(v) if v then startThread("autoMaze", autoMazeLoop) else stopThread("autoMaze") end end
})

local UpgSec = MainTab:CreateSection({ Name = "Auto Upgrade", Side = "left", Subtab = "Upgrades" })
UpgSec:CreateToggle({
    Name = "Enable Auto Buy",
    CurrentValue = false,
    Callback = function(v) if v then startThread("autoUpgrade", autoUpgradeLoop) else stopThread("autoUpgrade") end end
})
for _, id in ipairs(UPGRADE_IDS) do
    local defName = UpgradeDir and UpgradeDir[id] and UpgradeDir[id].Name or id
    UpgSec:CreateToggle({ Name = defName, CurrentValue = false, Callback = function(v) CFG.wanted[id] = v or nil end })
end

local MiscSec = MainTab:CreateSection({ Name = "Script Settings", Side = "right", Subtab = "Misc" })
MiscSec:CreateButton({
    Name = "Unload Script (Panic Clean)",
    Callback = function()
        for name in pairs(Threads) do stopThread(name) end
        setPetSpeed(false); setAutoOrbs(false)
        clearPets()
        _G.FiestaFarmLoaded = false
        Weave:Destroy()
    end,
})

-- PET SPAWNER TAB
local SpawnTab = Window:CreateTab("PetSpawner", "cat", { "Manager" })
local SpawnSec = SpawnTab:CreateSection({ Name = "Visual Fake Pets", Side = "left", Subtab = "Manager" })
SpawnSec:CreateButton({
    Name = "Clear All Fake Pets & Inventory",
    Callback = function()
        clearPets()
        Weave:Notify({ Title = "PetSpawner", Content = "All visuals cleared.", Duration = 3 })
    end
})
SpawnSec:CreateParagraph({
    Title = "Note",
    Content = "Pet visuals have been disabled in the UI to save menu space, but the fake-inventory cleaner is kept active for safe unloading."
})

Weave:Notify({ Title = "Fiesta Farm V2 Ultimate", Content = "Successfully loaded all features!", Duration = 5 })
