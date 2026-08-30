local Players     = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local ClientLib = game:GetService("ReplicatedStorage"):WaitForChild("Library"):WaitForChild("Client")

local function need(name)
	local child = ClientLib:FindFirstChild(name)
	if not child then return nil end
	local ok, mod = pcall(require, child)
	return ok and mod or nil
end

local Network        = need("Network")
local FFlags         = need("FFlags")
local PlayerPet      = need("PlayerPet")
local MapCmds        = need("MapCmds")
local InstancingCmds = need("InstancingCmds")
local EventUpgrades  = need("EventUpgradeCmds")
local RaidCmds       = need("RaidCmds")
local FiestaMazeCmds = need("FiestaMazeCmds")

local ClientRaid = (function()
	local rc = ClientLib:FindFirstChild("RaidCmds")
	local child = rc and rc:FindFirstChild("ClientRaidInstance")
	if not child then return nil end
	local ok, mod = pcall(require, child)
	return ok and mod or nil
end)()

local Orb = (function()
	local oc = ClientLib:FindFirstChild("OrbCmds")
	local child = oc and oc:FindFirstChild("Orb")
	if not child then return nil end
	local ok, mod = pcall(require, child)
	return ok and mod or nil
end)()

local Lib = game:GetService("ReplicatedStorage"):WaitForChild("Library")

local function needAt(parent, name)
	local child = parent and parent:FindFirstChild(name)
	if not child then return nil end
	local ok, mod = pcall(require, child)
	return ok and mod or nil
end

local FiestaUpgrades  = needAt(Lib:FindFirstChild("Util"), "FiestaUpgrades")
local UpgradeDir      = needAt(Lib:FindFirstChild("Directory"), "EventUpgrades")
local CurrencyItem    = needAt(Lib:FindFirstChild("Items"), "CurrencyItem")
local RaidTypes       = needAt(Lib:FindFirstChild("Types"), "Raids")
local BreakableTypes  = needAt(Lib:FindFirstChild("Types"), "Breakables")
local TeleportTo      = needAt(Lib:FindFirstChild("Functions"), "TeleportCharacterTo")

-- Breakables.ParentType = { Zone = 1, Instance = 2, Plaza = 3 }
local ParentType = (BreakableTypes and BreakableTypes.ParentType) or { Zone = 1, Instance = 2, Plaza = 3 }
local P_ZONE, P_INSTANCE, P_PLAZA = ParentType.Zone, ParentType.Instance, ParentType.Plaza

if not Network then
	error("[Fiesta] could not require Network -- game not loaded yet?")
end

-- taps/sec and target count are intentionally not exposed: the script always
-- runs flat out at every breakable it can legally damage.
local TAP_RATE   = 30
local PET_SPEED_MULT = 100

local CFG = {
	autoTap    = false,
	sendPets   = true,

	petSpeed   = false,

	autoOrbs   = false,

	autoJoin   = false,
	instanceId = "FiestaLobby",

	autoMaze   = false,

	autoUpgrade = false,
	wanted      = {},   -- [upgradeId] = true
}

local running = {}

local Weave   -- loaded in the UI section below; used by the upgrade loop

--=============================================================================
-- breakable discovery
--=============================================================================

local breakFolder

local function breakableModels()
	if not (breakFolder and breakFolder.Parent) then
		local things = workspace:FindFirstChild("__THINGS")
		breakFolder = things and things:FindFirstChild("Breakables")
	end
	return breakFolder and breakFolder:GetChildren() or {}
end

-- Zone the server thinks we are in. Breakables carry BOTH a ParentType and a
-- ParentID, and the two are validated differently (see canMine below), so a
-- plain "zone id" is not enough on its own.
local function currentZoneId()
	if MapCmds then
		local ok, res = pcall(MapCmds.GetCurrentZone)
		if ok and res then return res end
	end
	return nil
end

local function currentInstanceId()
	if InstancingCmds then
		local ok, res = pcall(InstancingCmds.GetInstanceID)
		if ok and res then return res end
	end
	return nil
end

-- what the status line shows
local function currentParentId()
	return currentInstanceId() or currentZoneId()
end

local function inInstance()
	if not InstancingCmds then return false end
	local ok, res = pcall(InstancingCmds.IsInInstance)
	return ok and res and true or false
end

local function myPosition()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

-- defined up here so the auto-join guard can ask "are we mid-raid?"
local function currentRaid()
	if not (ClientRaid and ClientRaid.GetCurrent) then return nil end
	local ok, raid = pcall(ClientRaid.GetCurrent)
	return ok and raid or nil
end

-- BreakableFrontend.canMine, mirrored. The server applies the same rule, so
-- anything this rejects would be a wasted remote call:
--   Instance -> InstancingCmds.IsInInstance(parentID)   (raids/maze live here)
--   Zone     -> ZoneCmds.Owns(parentID)
--   Plaza    -> on the trading plaza
-- The maze is an INSTANCE, not a zone. Comparing its ParentID against
-- GetCurrentZone() never matches, which is why nothing got tapped in there.
local function canDamage(model, zoneId, instanceId)
	local pType = model:GetAttribute("ParentType")
	local pId   = model:GetAttribute("ParentID")

	if pType == P_INSTANCE then
		return instanceId ~= nil and pId == instanceId
	end

	if pType == P_ZONE then
		if model:GetAttribute("VIPBreakable") then return false end
		-- while inside an instance, outside-world zone breakables are not ours
		if instanceId then return false end
		return zoneId == nil or pId == zoneId
	end

	if pType == P_PLAZA then
		return false
	end

	-- unknown/absent ParentType: fall back to a loose id match
	return pId == nil or zoneId == nil or pId == zoneId or pId == instanceId
end

-- returns { {uid=, model=, dist=}, ... } nearest first.
-- every breakable we are actually allowed to damage, no cap.
local function collectTargets()
	local zoneId = currentZoneId()
	local instanceId = currentInstanceId()
	local pos = myPosition()
	local out = {}

	for _, model in ipairs(breakableModels()) do
		local uid = model:GetAttribute("BreakableUID")
		if uid and model:IsA("Model") and canDamage(model, zoneId, instanceId) then
			local dist = 0
			if pos then
				local ok, pivot = pcall(model.GetPivot, model)
				if ok then dist = (pivot.Position - pos).Magnitude end
			end
			table.insert(out, { uid = uid, model = model, dist = dist })
		end
	end

	table.sort(out, function(a, b) return a.dist < b.dist end)
	return out
end

--=============================================================================
-- damage
--=============================================================================

local function tap(uid)
	-- BreakableFrontend rate-limits this to 8/s client-side; we call it directly
	if Network.UnreliableFire then
		pcall(Network.UnreliableFire, "Breakables_PlayerDealDamage", uid)
	else
		pcall(Network.Fire, "Breakables_PlayerDealDamage", uid)
	end
end

-- pets deal the bulk of the damage, tapping alone is chip damage
local function assignPets(model)
	if not (PlayerPet and CFG.sendPets and model) then return end
	local ok, pets = pcall(PlayerPet.GetByPlayer, LocalPlayer)
	if not ok or type(pets) ~= "table" then return end
	for _, pet in pairs(pets) do
		pcall(function() pet:SetTarget(model) end)
	end
end

--=============================================================================
-- pet speed
--
-- PlayerPet.CalculateSpeedMultiplier is the single funnel for pet movement
-- speed. updatePetSpeedTask() re-reads it once a second and broadcasts the
-- result to the parallel pet actors, so hooking it is enough -- no per-pet
-- writes and nothing to re-apply when pets respawn.
--=============================================================================

local originalCalcSpeed
local hookFailed = false

-- push the current multiplier onto every live pet right now
local function pushPetSpeed()
	pcall(function()
		for _, pet in pairs(PlayerPet.GetByPlayer(LocalPlayer)) do
			local mult
			if hookFailed and CFG.petSpeed then
				local ok, base = pcall(pet.CalculateSpeedMultiplier, pet)
				mult = ((ok and type(base) == "number") and base or 1) * PET_SPEED_MULT
			else
				mult = pet:CalculateSpeedMultiplier()
			end
			pet.speedMult = mult
			pet.cpet:Broadcast("petSpeedMult", mult)
		end
	end)
end

local function setPetSpeed(enabled)
	if not PlayerPet or not PlayerPet.CalculateSpeedMultiplier then return false end

	if enabled then
		if not originalCalcSpeed and not hookFailed then
			local orig = PlayerPet.CalculateSpeedMultiplier
			-- the module table may be frozen; fall back to per-pet writes if so
			local ok = pcall(function()
				PlayerPet.CalculateSpeedMultiplier = function(self, ...)
					local good, base = pcall(orig, self, ...)
					if not good or type(base) ~= "number" then base = 1 end
					return base * PET_SPEED_MULT
				end
			end)
			if ok then
				originalCalcSpeed = orig
			else
				hookFailed = true
			end
		end

		-- frozen-table path: the game's 1s task resets speedMult, so out-pace it
		if hookFailed and not running.speed then
			running.speed = true
			task.spawn(function()
				while running.speed and CFG.petSpeed do
					pushPetSpeed()
					task.wait(0.4)
				end
				running.speed = false
			end)
		end
	else
		running.speed = false
		if originalCalcSpeed then
			pcall(function() PlayerPet.CalculateSpeedMultiplier = originalCalcSpeed end)
			originalCalcSpeed = nil
		end
	end

	pushPetSpeed()
	return true
end

--=============================================================================
-- loops
--=============================================================================

local function startAutoTap()
	if running.tap then return end
	running.tap = true

	task.spawn(function()
		local petTick = 0
		while running.tap do
			local ok = pcall(function()
				local targets = collectTargets()

				-- hit everything in the zone, no cap
				for i = 1, #targets do
					tap(targets[i].uid)
				end

				-- retargeting pets every tick thrashes them; ~2x a second is plenty
				petTick = petTick + 1
				if petTick >= 15 and #targets > 0 then
					petTick = 0
					assignPets(targets[1].model)
				end
			end)
			if not ok then task.wait(0.5) end
			task.wait(1 / TAP_RATE)
		end
	end)
end

local function stopAutoTap()
	running.tap = false
end

local function startAutoJoin()
	if running.join then return end
	running.join = true

	task.spawn(function()
		while running.join do
			pcall(function()
				if not (InstancingCmds and InstancingCmds.Enter) then return end

				-- Never yank the player out of a maze run. A raid is itself an
				-- instance, so entering the lobby mid-run would abandon it.
				if running.maze or currentRaid() then return end

				-- Already somewhere else instanced? Leave that alone too.
				if InstancingCmds.IsInInstance(CFG.instanceId) then return end
				if inInstance() then return end

				if not InstancingCmds.IsBusy() then
					InstancingCmds.Enter(CFG.instanceId)
				end
			end)
			task.wait(5)
		end
	end)
end

local function stopAutoJoin()
	running.join = false
end

--=============================================================================
-- auto collect orbs
--
-- OrbCmds' RenderStep recomputes the magnet reach every frame as
--   local v8 = Orb.DefaultPickupDistance + UpgradeCmds.GetPower("Magnet") + ...
--   local v9 = EnchantCmds.GetPower("Super Magnet") > 0
-- and hands both to Orb.RenderStepped. In there, if super magnet is on, any orb
-- past 150 studs is claimed outright (`Collect(nil, nil, true)`) and anything
-- closer gets unanchored with a 999999999 reach so it flies straight in.
-- So the whole feature is one boolean: make GetPower("Super Magnet") positive.
-- Widening DefaultPickupDistance is an independent fallback that still pulls
-- orbs in if the enchant hook somehow doesn't take. Collection itself still
-- goes out over the game's own Network.Fire("Orbs: Collect", ids) batch.
--=============================================================================

local EnchantCmds = need("EnchantCmds")

local origPickupDistance
local origEnchantPower

local function setAutoOrbs(enabled)
	local hooked = false

	if enabled then
		if Orb and origPickupDistance == nil and type(Orb.DefaultPickupDistance) == "number" then
			local saved = Orb.DefaultPickupDistance
			local ok = pcall(function() Orb.DefaultPickupDistance = 100000 end)
			if ok and Orb.DefaultPickupDistance ~= saved then
				origPickupDistance = saved
				hooked = true
			end
		end

		if EnchantCmds and type(EnchantCmds.GetPower) == "function" and origEnchantPower == nil then
			local orig = EnchantCmds.GetPower
			local patched
			patched = function(name, ...)
				if name == "Super Magnet" then
					local good, base = pcall(orig, name, ...)
					local n = (good and type(base) == "number") and base or 0
					return math.max(n, 1)
				end
				return orig(name, ...)
			end
			local ok = pcall(function() EnchantCmds.GetPower = patched end)
			if ok and EnchantCmds.GetPower == patched then
				origEnchantPower = orig
				hooked = true
			end
		end

		return hooked or origPickupDistance ~= nil or origEnchantPower ~= nil
	end

	if origPickupDistance ~= nil then
		pcall(function() Orb.DefaultPickupDistance = origPickupDistance end)
		origPickupDistance = nil
	end
	if origEnchantPower ~= nil then
		pcall(function() EnchantCmds.GetPower = origEnchantPower end)
		origEnchantPower = nil
	end
	return true
end

--=============================================================================
-- autofarm maze
--
-- Drives the same primitives the game's own (FFlag-gated) Auto Raid uses:
--   RaidCmds.Create{Portal=n, Difficulty=d, PartyMode=Solo}    -- start a run
--   ClientRaidInstance.GetCurrent() :GetRoomNumber() :IsComplete() ._ct
--   FiestaMazeCmds.PathCellModel(room) + TeleportCharacterTo   -- walk a room
--   Network.Invoke("Raids_CollectReward", chestKey, raid._ct)  -- open the eggs
-- Damage itself is the normal auto-tap path: maze breakables are
-- ParentType.Instance, so canMine() only asks whether we are in the raid.
--=============================================================================

local mazeStatus = "idle"

local function freePortal()
	if not (ClientRaid and ClientRaid.GetByPortal) then return 1 end
	for i = 1, 10 do
		local ok, taken = pcall(ClientRaid.GetByPortal, i)
		if ok and not taken then return i end
	end
	return nil
end

-- Create the raid AND join it. Create() only reserves the portal -- the game's
-- own Auto Raid follows it with raid:Join(), and leaves any instance it is
-- currently sitting in first (you cannot start a raid from inside the lobby).
local function startRun()
	if not (RaidCmds and RaidCmds.Create) then return false, "RaidCmds missing" end

	-- step out of the Fiesta lobby (or any instance) before creating
	if inInstance() and InstancingCmds and InstancingCmds.Leave then
		pcall(InstancingCmds.Leave, false, true)
		local deadline = os.clock() + 5
		while inInstance() and os.clock() < deadline do
			task.wait(0.25)
		end
	end

	local portal = freePortal()
	if not portal then return false, "no free portal" end

	local difficulty = 1
	if RaidCmds.GetDifficultyLevel then
		local ok, d = pcall(RaidCmds.GetDifficultyLevel)
		if ok and type(d) == "number" then difficulty = d end
	end

	local solo = RaidTypes and RaidTypes.PartyMode and RaidTypes.PartyMode.Solo

	local ok, res, err, raid = pcall(RaidCmds.Create, {
		Portal = portal,
		Difficulty = difficulty,
		PartyMode = solo,
	})
	if not ok then return false, tostring(res) end
	if not res then return false, tostring(err or "rejected") end
	if not raid then return false, "created but no raid returned" end

	-- this is what actually puts the character inside the maze
	local jok, jres, jerr = pcall(raid.Join, raid)
	if not jok then return false, tostring(jres) end
	if not jres then return false, tostring(jerr or "join refused") end

	return true
end

-- Open every non-retired chest -- the "open all the eggs at the end" step.
-- Deliberately does NOT teleport: the claim is a pure remote call and works
-- from wherever you are standing, so there is no reason to move the character.
-- The server can answer "isn't ready yet" for a few seconds after a run ends,
-- so retry on that specific refusal (same 15s window the game's own Auto Raid
-- uses) instead of quietly banking nothing.
local function openAllChests(raid)
	raid = raid or currentRaid()
	local ct = raid and raid._ct
	if not (ct and RaidTypes and RaidTypes.ChestDirectory) then return 0, 0 end

	local deadline = os.clock() + 15

	while true do
		local opened, attempted, notReady = 0, 0, false

		for key, chest in pairs(RaidTypes.ChestDirectory) do
			if not chest.Retired then
				attempted = attempted + 1
				local ok, res, why = pcall(Network.Invoke, "Raids_CollectReward", key, ct)
				if ok and res then
					opened = opened + 1
				elseif why and string.find(tostring(why), "isn't ready yet", 1, true) then
					notReady = true
				end
				task.wait(0.1)
			end
		end

		-- done once something landed, nothing is pending, or we ran out of time
		if opened > 0 or not notReady or os.clock() >= deadline then
			return opened, attempted
		end

		task.wait(1)
	end
end

--=============================================================================
-- moving through the maze
--
-- Maze breakables are ParentType.Instance, so canMine() only asks whether we
-- are inside the raid instance -- distance is irrelevant and we could damage
-- them from the spawn. But the maze only *spawns* the next room's breakables
-- once the client has opened that cell, so standing still stalls the run.
-- Hence: walk the character to the current room, exactly like the game's own
-- teleportToRoom() does (PathCellModel(room) -> TeleportCharacterTo).
--=============================================================================

local lastTeleport = 0

local function teleportTo(position)
	if not position then return false end
	if os.clock() - lastTeleport < 1.5 then return false end   -- don't spam it
	lastTeleport = os.clock()

	if TeleportTo then
		local ok = pcall(TeleportTo, position)
		if ok then return true end
	end

	local char = LocalPlayer.Character
	if char then
		return (pcall(char.PivotTo, char, CFrame.new(position + Vector3.new(0, 4, 0))))
	end
	return false
end

-- walk to the room the raid says we are on
local function moveToRoom(roomNumber)
	if not (FiestaMazeCmds and FiestaMazeCmds.PathCellModel and roomNumber) then return false end
	local ok, cell = pcall(FiestaMazeCmds.PathCellModel, roomNumber)
	if not (ok and cell) then return false end
	local good, pivot = pcall(cell.GetPivot, cell)
	if not (good and pivot) then return false end
	return teleportTo(pivot.Position)
end

local function startAutoMaze()
	if running.maze then return end
	running.maze = true

	task.spawn(function()
		local lastRaidId, cleared, lastRoom = nil, false, nil

		while running.maze do
			local ok = pcall(function()
				local raid = currentRaid()

				if not raid then
					-- between runs: start a fresh maze
					mazeStatus = "starting run"
					cleared = false
					lastRaidId, lastRoom = nil, nil
					local started, why = startRun()
					if not started then
						mazeStatus = "start failed: " .. tostring(why)
						task.wait(4)
					else
						task.wait(2)
					end
					return
				end

				local id = nil
				if raid.GetId then
					local good, res = pcall(raid.GetId, raid)
					if good then id = res end
				end
				if id ~= lastRaidId then
					lastRaidId = id
					cleared = false
					lastRoom = nil
				end

				local done = false
				if raid.IsComplete then
					local good, res = pcall(raid.IsComplete, raid)
					done = good and res == true
				end

				if done and not cleared then
					cleared = true
					mazeStatus = "run complete -- claiming"

					local n = openAllChests(raid)
					mazeStatus = string.format("opened %d chest(s)", n)
					if Weave then
						Weave:Notify({
							Title = "Fiesta Farm",
							Content = string.format("Maze done -- opened %d chest(s).", n),
							Duration = 4,
						})
					end
					task.wait(3)   -- let the server tear the raid down
				elseif done then
					-- already claimed this one. If the finished raid is still
					-- hanging around, kick off the next run anyway rather than
					-- waiting forever for it to disappear.
					mazeStatus = "starting next run"
					local started = startRun()
					task.wait(started and 3 or 5)
				else
					local room = nil
					if raid.GetRoomNumber then
						local good, r = pcall(raid.GetRoomNumber, raid)
						if good and type(r) == "number" then room = r end
					end
					mazeStatus = "farming room " .. (room and tostring(room) or "?")

					-- walk to this room so its breakables actually spawn; the
					-- server only materializes a cell once the client is there
					if room and room ~= lastRoom then
						if moveToRoom(room) then lastRoom = room end
					end

					-- then walk to the pinatas themselves. The room cell pivot is
					-- its centre, which can be a long way from where the breakables
					-- actually sit -- and pets have to physically reach a target to
					-- damage it, so standing in the middle of an empty cell farms
					-- nothing. Taps ignore distance; pets do not.
					local targets = collectTargets()
					local nearest = targets[1]
					if nearest and nearest.dist > 60 then
						local good, pivot = pcall(nearest.model.GetPivot, nearest.model)
						if good and pivot then
							if teleportTo(pivot.Position) then
								mazeStatus = string.format(
									"farming room %s (%d pinata(s))",
									room and tostring(room) or "?", #targets)
							end
						end
					end
				end
			end)

			if not ok then
				mazeStatus = "error -- retrying"
				task.wait(2)
			end
			task.wait(1)
		end

		mazeStatus = "idle"
	end)
end

local function stopAutoMaze()
	running.maze = false
end

--=============================================================================
-- fiesta maze upgrades
--
-- Mirrors "Fiesta Upgrade Machine": isMaxxed / getCost / canAfford, then
-- EventUpgradeCmds.Purchase(id). Purchase() invokes the server, which is the
-- authority -- if it says no we just try again next pass.
--=============================================================================

-- the 4 the machine actually sells; everything else is a passive track
local UPGRADE_IDS = (FiestaUpgrades and FiestaUpgrades.PurchasableOrder)
	or { "FiestaDamage", "FiestaSmashSpeed", "FiestaPets", "FiestaKeyDrops" }

local function upgradeDef(id)
	return UpgradeDir and UpgradeDir[id] or nil
end

local function upgradeName(id)
	local def = upgradeDef(id)
	return (def and def.Name) or id
end

local function upgradeTier(id)
	if not (EventUpgrades and EventUpgrades.GetTier) then return 0 end
	local ok, tier = pcall(EventUpgrades.GetTier, id)
	return (ok and type(tier) == "number") and tier or 0
end

local function isMaxxed(id)
	local def = upgradeDef(id)
	if not def then return false end
	return upgradeTier(id) >= #def.TierPowers
end

-- cost of the NEXT tier, with the live cost-multiplier FFlag applied
local function nextCost(id)
	local def = upgradeDef(id)
	if not def then return nil end

	local tier = upgradeTier(id)
	local entry = def.TierCosts[tier + 1]
	if not entry then return nil end

	local mult = 1
	if FFlags then
		local ok, v = pcall(function() return FFlags.Get(FFlags.Keys.PinataFiesta_UpgradeCostMult) end)
		if ok and type(v) == "number" then mult = math.max(1, v) end
	end

	local ok, item = pcall(function()
		local clone = entry:Clone()
		return clone:SetAmount(math.max(1, math.ceil(clone:GetAmount() * mult)))
	end)
	return ok and item or nil
end

local function canAfford(id)
	local item = nextCost(id)
	if not item then return false end
	local ok, have = pcall(item.CountAny, item)
	if not ok then return false end
	return have >= item:GetAmount()
end

local function orbCount()
	if not CurrencyItem then return nil end
	local ok, n = pcall(function() return CurrencyItem("FiestaOrbs"):CountAny() end)
	return ok and n or nil
end

-- one pass over the wanted list; returns how many purchases went through
local function buyWanted(notify)
	if not EventUpgrades then return 0 end
	local bought = 0

	for _, id in ipairs(UPGRADE_IDS) do
		if CFG.wanted[id] and not isMaxxed(id) then
			-- keep buying this one while it is affordable; tier moves each time
			for _ = 1, 25 do
				if isMaxxed(id) or not canAfford(id) then break end

				local ok, res = pcall(EventUpgrades.Purchase, id)
				if not (ok and res) then break end

				bought = bought + 1
				if notify then
					Weave:Notify({
						Title = "Fiesta Farm",
						Content = string.format("%s -> tier %d", upgradeName(id), upgradeTier(id)),
						Duration = 3,
					})
				end
				task.wait(0.25)   -- let the save replicate before re-reading tier
			end
		end
	end

	return bought
end

local function startAutoUpgrade()
	if running.upgrade then return end
	running.upgrade = true

	task.spawn(function()
		while running.upgrade do
			pcall(buyWanted, true)
			task.wait(3)
		end
	end)
end

local function stopAutoUpgrade()
	running.upgrade = false
end

--=============================================================================
-- pet spawner -- client-side visuals only
--
-- Pet art lives at __DIRECTORY.Pets.<Class>.<Name>: a ModuleScript holding a
-- "Pet" BasePart plus a "Golden" variant. Newer gargantuans nest both under a
-- "Holder" model instead. Cloning that part IS the whole visual -- the real
-- pets are driven by Library.Client.CustomPet, which we never touch.
--
-- Clones are parented to workspace.CurrentCamera, which is where the game puts
-- its own local-only preview models (see "Egg Opening Frontend"). Nothing here
-- replicates: no stats, no damage, no inventory, and nobody else can see them.
--=============================================================================

local RunService = game:GetService("RunService")

local PET_CLASSES = { "Titanic", "Gargantuan" }

-- classes we strip out of a clone: audio would loop forever and any script
-- would try to run the real pet logic against a model that has no owner
local function isJunk(inst)
	return inst:IsA("Sound")
		or inst:IsA("Script")
		or inst:IsA("LocalScript")
		or inst:IsA("ModuleScript")
end

local function petDirFolder()
	local dir = game:GetService("ReplicatedStorage"):FindFirstChild("__DIRECTORY")
	return dir and dir:FindFirstChild("Pets") or nil
end

-- { {name=, class=, source=ModuleScript}, ... } sorted, Titanic then Gargantuan
local PET_LIST, PET_BY_NAME = {}, {}

local function rebuildPetList()
	PET_LIST, PET_BY_NAME = {}, {}
	local root = petDirFolder()
	for _, class in ipairs(PET_CLASSES) do
		local folder = root and root:FindFirstChild(class)
		if folder then
			local kids = folder:GetChildren()
			table.sort(kids, function(a, b) return a.Name < b.Name end)
			for _, child in ipairs(kids) do
				local entry = { name = child.Name, class = class, source = child }
				table.insert(PET_LIST, entry)
				PET_BY_NAME[child.Name] = entry
				PET_BY_NAME[string.lower(child.Name)] = entry
			end
		end
	end
	return #PET_LIST
end

rebuildPetList()

-- the art is either a direct child or one level down inside "Holder"
local function findPetArt(source, golden)
	if not source then return nil end
	local wanted = golden and "Golden" or "Pet"

	local function pick(parent)
		local hit = parent:FindFirstChild(wanted)
		if hit and (hit:IsA("BasePart") or hit:IsA("Model")) then return hit end
		-- no golden variant for this pet: fall back to the normal one
		local base = parent:FindFirstChild("Pet")
		if base and (base:IsA("BasePart") or base:IsA("Model")) then return base end
		return nil
	end

	local direct = pick(source)
	if direct then return direct end

	local holder = source:FindFirstChild("Holder")
	return holder and pick(holder) or nil
end

-- FileMesh parts render at Mesh.Scale, ignoring Part.Size, so both have to be
-- scaled -- same thing the game's own AdminShows resize helper does. Multi-part
-- Holder models get Model:ScaleTo instead, which also fixes up the joint
-- offsets; scaling their parts individually would just blow the model apart.
local function scaleArt(inst, mult)
	if mult == 1 then return end

	if inst:IsA("Model") then
		local ok = pcall(inst.ScaleTo, inst, mult)
		if ok then return end
	end

	if inst:IsA("BasePart") then
		inst.Size = inst.Size * mult
	end
	for _, child in ipairs(inst:GetDescendants()) do
		if child:IsA("SpecialMesh") then
			child.Scale = child.Scale * mult
		elseif child:IsA("BasePart") then
			child.Size = child.Size * mult
		end
	end
end

local function buildVisual(entry, golden, mult)
	local art = findPetArt(entry.source, golden)
	if not art then return nil end

	local ok, clone = pcall(art.Clone, art)
	if not (ok and clone) then return nil end

	for _, child in ipairs(clone:GetDescendants()) do
		if isJunk(child) then
			pcall(child.Destroy, child)
		end
	end
	if isJunk(clone) then pcall(clone.Destroy, clone); return nil end

	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
		end
	end
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Massless = true
	end

	pcall(scaleArt, clone, mult)
	clone.Name = "__SPAWNED_" .. entry.name
	return clone
end

local spawnedPets = {}   -- { {inst=, height=}, ... }
local orbitConn

local function artSize(inst)
	if inst:IsA("BasePart") then return inst.Size end
	local ok, size = pcall(inst.GetExtentsSize, inst)
	return (ok and size) or Vector3.new(6, 6, 6)
end

local function setArtCFrame(inst, cf)
	if inst:IsA("BasePart") then
		inst.CFrame = cf
	else
		pcall(inst.PivotTo, inst, cf)
	end
end

--=============================================================================
-- fake inventory entries
--
-- The client inventory is a Container wrapping a SimpleStore over
-- Save.Get(player).Inventory (Library.Client.InventoryCmds -> ClientPlayerState).
-- store:SetReference(uid, item) is pure local table work -- it fills _byUID,
-- _byType, _byStack and the backing data table -- so writing to it puts a pet
-- in the inventory GUI without a single remote call. Firing container.Updated
-- is what makes the GUI redraw: GUIs.Inventory hooks Container:UpdatedCallback,
-- which compares the type store's iteration counter, and SetReference bumps it.
--
-- The server never sees these. Anything that asks the server about one (equip,
-- trade, sell, delete) is simply refused, and a save update from the server can
-- wipe them. They are there to look at.
--=============================================================================

local InventoryCmds = need("InventoryCmds")
local ItemsLib      = needAt(Lib, "Items")
local PetsDir       = needAt(Lib:FindFirstChild("Directory"), "Pets")
local Constants     = needAt(Lib:FindFirstChild("Balancing"), "Constants")

local function inventoryContainer()
	if not (InventoryCmds and InventoryCmds.Container) then return nil end
	local ok, container = pcall(InventoryCmds.Container)
	return ok and container or nil
end

-- Directory.Pets has an __index that *errors* on unknown keys, so never index
-- it directly to test for a pet -- rawget reads the real entry or nil.
local function petDirEntry(name)
	if not PetsDir then return nil end
	local ok, entry = pcall(rawget, PetsDir, name)
	return ok and entry or nil
end

local function makePetItem(name, golden)
	if not (ItemsLib and ItemsLib.Pet) then return nil, "Items library unavailable" end

	local ok, item = pcall(ItemsLib.Pet, name)
	if not (ok and item) then return nil, "no directory entry for " .. tostring(name) end

	-- golden is a pet *type*, and some pets explicitly forbid it
	local dir = petDirEntry(name)
	if golden and Constants and Constants.PetTypes and not (dir and dir.preventGolden) then
		pcall(item.SetType, item, Constants.PetTypes.Golden)
	end

	if not pcall(item.PopulateUID, item) then return nil, "could not generate a UID" end

	local gotUid, uid = pcall(item.GetUID, item)
	if not (gotUid and uid) then return nil, "could not read the UID" end

	-- items sitting in a store are tracked; harmless if the build disagrees
	pcall(item.SetTracked, item, true)
	return item, uid
end

-- redraw the inventory GUI. Updated carries the store, matching what a real
-- transaction commit fires.
local function refreshInventoryGUI(container)
	container = container or inventoryContainer()
	if not (container and container.Updated) then return end
	pcall(function()
		container.Updated:FireAsync(container._store)
	end)
end

local fakeUids = {}   -- uids we put there, so we can take them back out

-- returns uid, err
local function addToInventory(name, golden)
	local container = inventoryContainer()
	if not container then return nil, "inventory not ready" end

	local store = container._store
	if not (store and store.SetReference) then return nil, "inventory store unavailable" end

	local item, uidOrErr = makePetItem(name, golden)
	if not item then return nil, uidOrErr end

	local ok, err = pcall(store.SetReference, store, uidOrErr, item)
	if not ok then return nil, tostring(err) end

	table.insert(fakeUids, uidOrErr)
	refreshInventoryGUI(container)
	return uidOrErr
end

local function removeFromInventory(uid)
	if not uid then return false end

	local container = inventoryContainer()
	local store = container and container._store
	if not (store and store.SetReference) then return false end

	local ok = pcall(store.SetReference, store, uid, nil)

	for i = #fakeUids, 1, -1 do
		if fakeUids[i] == uid then table.remove(fakeUids, i) end
	end

	if ok then refreshInventoryGUI(container) end
	return ok
end

local function clearInventoryAdds()
	local container = inventoryContainer()
	local store = container and container._store
	local n = 0

	if store and store.SetReference then
		for _, uid in ipairs(fakeUids) do
			if pcall(store.SetReference, store, uid, nil) then n = n + 1 end
		end
		if n > 0 then refreshInventoryGUI(container) end
	end

	fakeUids = {}
	return n
end

local function clearPets()
	if orbitConn then orbitConn:Disconnect(); orbitConn = nil end
	for _, e in ipairs(spawnedPets) do
		if e.inst then pcall(e.inst.Destroy, e.inst) end
		if e.uid then removeFromInventory(e.uid) end
	end
	spawnedPets = {}
end

local ORBIT_SPEED = 0.6

local function startOrbit()
	if orbitConn then return end
	orbitConn = RunService.RenderStepped:Connect(function()
		local n = #spawnedPets
		if n == 0 then return end

		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then return end

		-- ring wide enough that the models do not intersect each other; these
		-- things are enormous natively, so space off the biggest one. Sizes are
		-- measured once at spawn -- GetExtentsSize on 70 models every frame is
		-- not something to do in RenderStepped.
		local widest = 0
		for _, e in ipairs(spawnedPets) do
			if e.inst and e.inst.Parent then
				widest = math.max(widest, e.width)
			end
		end
		local radius = math.max(10, widest * 0.7 + n * 1.5)

		local now = os.clock()
		local look = root.CFrame.LookVector
		local step = math.pi * 2 / n

		for i, e in ipairs(spawnedPets) do
			local inst = e.inst
			if inst and inst.Parent then
				local a = (i - 1) * step + now * ORBIT_SPEED
				local bob = math.sin(now * 2 + i) * 1.5
				local pos = root.Position + Vector3.new(
					math.cos(a) * radius,
					e.height + bob,
					math.sin(a) * radius
				)
				setArtCFrame(inst, CFrame.lookAt(pos, pos + look))
			end
		end
	end)
end

-- returns spawned, reason
local function spawnPet(name, golden, mult, count, toInventory)
	local entry = PET_BY_NAME[name] or PET_BY_NAME[string.lower(tostring(name))]
	if not entry then return 0, "unknown pet '" .. tostring(name) .. "'" end

	local made = 0
	for _ = 1, math.max(1, count or 1) do
		local visual = buildVisual(entry, golden, mult or 1)
		if not visual then break end
		visual.Parent = workspace.CurrentCamera
		local size = artSize(visual)

		-- each visual gets its own inventory row, so removing one visual takes
		-- exactly one row with it
		local uid = nil
		if toInventory then
			uid = addToInventory(entry.name, golden)
		end

		table.insert(spawnedPets, {
			inst   = visual,
			uid    = uid,
			height = size.Y * 0.5,
			width  = math.max(size.X, size.Z),
		})
		made = made + 1
	end

	if made == 0 then return 0, "no art found for " .. entry.name end
	startOrbit()
	return made
end

local function removeLastPet()
	local e = table.remove(spawnedPets)
	if not e then return false end
	if e.inst then pcall(e.inst.Destroy, e.inst) end
	if e.uid then removeFromInventory(e.uid) end
	if #spawnedPets == 0 and orbitConn then
		orbitConn:Disconnect(); orbitConn = nil
	end
	return true
end

--=============================================================================
-- UI
--=============================================================================

Weave = loadstring(game:HttpGet("https://raw.githubusercontent.com/SvenaEE/Testlibary-/refs/heads/main/Weave-Release"))()

local Window = Weave:CreateWindow({
	Name = "Fiesta Farm",
	LoadingSubtitle = "Pet Sim 99",
	ConfigurationSaving = { Enabled = true, FileName = "FiestaFarm" },
	KeySystem = false,
	ToggleKey = Enum.KeyCode.RightShift,
})

local MainTab = Window:CreateTab("Farm", "skull", { "Tapping", "Pets", "Event" })

--------------------------------------------------------------------- Tapping
local TapSec = MainTab:CreateSection({ Name = "Auto Tap", Side = "left", Subtab = "Tapping" })

TapSec:CreateToggle({
	Name = "Auto Tap",
	CurrentValue = false,
	Flag = "auto_tap",
	Callback = function(v)
		CFG.autoTap = v
		if v then startAutoTap() else stopAutoTap() end
	end,
})

TapSec:CreateToggle({
	Name = "Send pets to targets",
	CurrentValue = true,
	Flag = "pet_send",
	Callback = function(v) CFG.sendPets = v end,
})

TapSec:CreateToggle({
	Name = "Auto Collect Orbs",
	CurrentValue = false,
	Flag = "auto_orbs",
	Callback = function(v)
		CFG.autoOrbs = v
		if not setAutoOrbs(v) then
			Weave:Notify({ Title = "Fiesta Farm", Content = "OrbCmds unavailable.", Duration = 5 })
		end
	end,
})

TapSec:CreateButton({
	Name = "Count breakables",
	Callback = function()
		local n = #collectTargets()
		Weave:Notify({ Title = "Fiesta Farm", Content = n .. " target(s) here.", Duration = 4 })
	end,
})

local TapInfo = MainTab:CreateSection({ Name = "Info", Side = "right", Subtab = "Tapping" })
local TapStatus = TapInfo:CreateParagraph({
	Title = "Status",
	Content = "Idle.",
})

TapInfo:CreateParagraph({
	Title = "How it works",
	Content = "Fires Breakables_PlayerDealDamage at EVERY breakable you are "
		.. "allowed to damage, at max rate, skipping the 8/s client cap. Works "
		.. "in the overworld and inside the maze. Pets do most of the real "
		.. "damage, so leave 'Send pets' on. Orbs are pulled in by forcing the "
		.. "game's own super-magnet path.",
})

--------------------------------------------------------------------- Pets
local PetSec = MainTab:CreateSection({ Name = "Pets", Side = "left", Subtab = "Pets" })

PetSec:CreateToggle({
	Name = "Infinite Pet Speed",
	CurrentValue = false,
	Flag = "pet_speed",
	Callback = function(v)
		CFG.petSpeed = v
		if not setPetSpeed(v) then
			Weave:Notify({ Title = "Fiesta Farm", Content = "PlayerPet unavailable.", Duration = 5 })
		end
	end,
})

local PetInfo = MainTab:CreateSection({ Name = "Note", Side = "right", Subtab = "Pets" })
PetInfo:CreateParagraph({
	Title = "Speed is visual-ish",
	Content = "Runs at max (" .. PET_SPEED_MULT .. "x). Pet movement speed is "
		.. "client-side: pets reach targets instantly, but damage per hit does "
		.. "not change. Nothing to tune, it is already flat out.",
})

--------------------------------------------------------------------- Event
local EventSec = MainTab:CreateSection({ Name = "Pinata Event", Side = "left", Subtab = "Event" })

EventSec:CreateToggle({
	Name = "Auto join Fiesta Lobby",
	CurrentValue = false,
	Flag = "auto_join",
	Callback = function(v)
		CFG.autoJoin = v
		if v then startAutoJoin() else stopAutoJoin() end
	end,
})

EventSec:CreateButton({
	Name = "Join now",
	Callback = function()
		local ok = pcall(function() InstancingCmds.Enter(CFG.instanceId) end)
		Weave:Notify({
			Title = "Fiesta Farm",
			Content = ok and "Entering Fiesta Lobby..." or "Could not enter.",
			Duration = 4,
		})
	end,
})

EventSec:CreateParagraph({
	Title = "Note",
	Content = "Auto join stands down while you are in a maze run, so it will "
		.. "never pull you out of one.",
})

--------------------------------------------------------------------- Maze
local MazeSec = MainTab:CreateSection({ Name = "Maze", Side = "left", Subtab = "Event" })

MazeSec:CreateToggle({
	Name = "AutoFarm Maze",
	CurrentValue = false,
	Flag = "auto_maze",
	Callback = function(v)
		CFG.autoMaze = v
		if v then startAutoMaze() else stopAutoMaze() end
	end,
})

MazeSec:CreateButton({
	Name = "Start a run now",
	Callback = function()
		task.spawn(function()
			local ok, why = startRun()
			Weave:Notify({
				Title = "Fiesta Farm",
				Content = ok and "Maze run started." or ("Could not start: " .. tostring(why)),
				Duration = 4,
			})
		end)
	end,
})

MazeSec:CreateButton({
	Name = "Open all chests now",
	Callback = function()
		task.spawn(function()
			-- no teleport: claiming is a plain remote call, it works in place
			local n = openAllChests()
			Weave:Notify({
				Title = "Fiesta Farm",
				Content = n > 0 and (n .. " chest(s) opened.") or "No chests claimed -- not in a finished run?",
				Duration = 4,
			})
		end)
	end,
})

local MazeInfo = MainTab:CreateSection({ Name = "Maze Info", Side = "right", Subtab = "Event" })
local MazeStatus = MazeInfo:CreateParagraph({ Title = "Status", Content = "Idle." })

MazeInfo:CreateParagraph({
	Title = "How it works",
	Content = "Starts a solo run on the first free portal, walks you to each "
		.. "room so its breakables spawn, then claims every chest in place and "
		.. "starts the next run. Chests are claimed without teleporting. Turn "
		.. "Auto Tap on too -- that is what does the breaking.",
})

--------------------------------------------------------------- auto upgrade
local UpgSec = MainTab:CreateSection({ Name = "Maze Upgrades", Side = "right", Subtab = "Event" })

UpgSec:CreateToggle({
	Name = "Auto buy selected",
	CurrentValue = false,
	Flag = "auto_upgrade",
	Callback = function(v)
		CFG.autoUpgrade = v
		if v then startAutoUpgrade() else stopAutoUpgrade() end
	end,
})

UpgSec:CreateDivider()

for _, id in ipairs(UPGRADE_IDS) do
	UpgSec:CreateToggle({
		Name = upgradeName(id),
		CurrentValue = false,
		Flag = "upg_" .. id,
		Callback = function(v) CFG.wanted[id] = v or nil end,
	})
end

UpgSec:CreateDivider()

UpgSec:CreateButton({
	Name = "Buy once now",
	Callback = function()
		-- buyWanted yields between purchases; keep it off the UI thread
		task.spawn(function()
			local n = buyWanted(false)
			Weave:Notify({
				Title = "Fiesta Farm",
				Content = n > 0 and (n .. " upgrade(s) bought.") or "Nothing bought -- not enough orbs, maxed, or none selected.",
				Duration = 4,
			})
		end)
	end,
})

local UpgStatus = UpgSec:CreateParagraph({ Title = "Tiers", Content = "Nothing selected." })

--------------------------------------------------------------- PetSpawner tab
local SpawnTab = Window:CreateTab("PetSpawner", "cat", { "Spawn", "Info" })

local pickedClass = PET_CLASSES[1]
local pickedPet   = nil
local pickedGold  = false
local pickedScale = 1
local pickedCount = 1
local pickedInv   = false

-- names of one class only -- the Pet dropdown is refilled from this whenever
-- the class changes, so you pick Titanic or Gargantuan first and then only see
-- that class's pets instead of scrolling one ~400-entry list.
local function namesOfClass(class)
	local out = {}
	for _, e in ipairs(PET_LIST) do
		if e.class == class then table.insert(out, e.name) end
	end
	return out
end

local function firstOfClass(class)
	for _, e in ipairs(PET_LIST) do
		if e.class == class then return e.name end
	end
	return nil
end

pickedPet = firstOfClass(pickedClass)

local SpawnSec = SpawnTab:CreateSection({ Name = "Spawn a pet", Side = "left", Subtab = "Spawn" })

local SpawnDrop   -- forward declaration: the class callback refreshes it

SpawnSec:CreateDropdown({
	Name = "Class",
	Options = PET_CLASSES,
	CurrentOption = pickedClass,
	Flag = "spawn_class",
	Callback = function(opt)
		pickedClass = type(opt) == "table" and opt[1] or opt
		pickedPet = firstOfClass(pickedClass)
		if SpawnDrop and SpawnDrop.Refresh then
			pcall(SpawnDrop.Refresh, SpawnDrop, namesOfClass(pickedClass))
		end
	end,
})

SpawnDrop = SpawnSec:CreateDropdown({
	Name = "Pet",
	Options = namesOfClass(pickedClass),
	CurrentOption = pickedPet,
	Flag = "spawn_pet",
	Callback = function(opt)
		-- Weave hands back the string; tolerate a table in case the build
		-- returns multi-select style
		pickedPet = type(opt) == "table" and opt[1] or opt
	end,
})

SpawnSec:CreateToggle({
	Name = "Golden variant",
	CurrentValue = false,
	Flag = "spawn_golden",
	Callback = function(v) pickedGold = v end,
})

SpawnSec:CreateToggle({
	Name = "Add to inventory",
	CurrentValue = false,
	Flag = "spawn_inventory",
	Callback = function(v) pickedInv = v end,
})

SpawnSec:CreateSlider({
	Name = "Size",
	Range = { 0.5, 10 },
	Increment = 0.5,
	CurrentValue = 1,
	Flag = "spawn_scale",
	Callback = function(v) pickedScale = v end,
})

SpawnSec:CreateSlider({
	Name = "How many",
	Range = { 1, 25 },
	Increment = 1,
	CurrentValue = 1,
	Flag = "spawn_count",
	Callback = function(v) pickedCount = v end,
})

SpawnSec:CreateButton({
	Name = "Spawn",
	Callback = function()
		if not pickedPet then
			Weave:Notify({ Title = "PetSpawner", Content = "Pick a pet first.", Duration = 4 })
			return
		end
		local made, why = spawnPet(pickedPet, pickedGold, pickedScale, pickedCount, pickedInv)
		Weave:Notify({
			Title = "PetSpawner",
			Content = made > 0
				and string.format("Spawned %dx %s.%s", made, pickedPet,
					pickedInv and " Added to inventory." or "")
				or ("Failed: " .. tostring(why)),
			Duration = 4,
		})
	end,
})

SpawnSec:CreateButton({
	Name = "Remove last",
	Callback = function()
		local ok = removeLastPet()
		Weave:Notify({
			Title = "PetSpawner",
			Content = ok and ("Removed. " .. #spawnedPets .. " left.") or "Nothing spawned.",
			Duration = 3,
		})
	end,
})

SpawnSec:CreateButton({
	Name = "Clear all",
	Callback = function()
		local n = #spawnedPets
		clearPets()
		Weave:Notify({ Title = "PetSpawner", Content = "Cleared " .. n .. " pet(s).", Duration = 3 })
	end,
})

local RandomSec = SpawnTab:CreateSection({ Name = "Shortcuts", Side = "right", Subtab = "Spawn" })

local function spawnRandomOf(class)
	local pool = namesOfClass(class)
	if #pool == 0 then
		Weave:Notify({ Title = "PetSpawner", Content = "No " .. class .. " art found.", Duration = 4 })
		return
	end
	local name = pool[math.random(1, #pool)]
	local made, why = spawnPet(name, pickedGold, pickedScale, pickedCount, pickedInv)
	Weave:Notify({
		Title = "PetSpawner",
		Content = made > 0 and string.format("Spawned %dx %s.", made, name) or ("Failed: " .. tostring(why)),
		Duration = 4,
	})
end

RandomSec:CreateButton({ Name = "Random Titanic",    Callback = function() spawnRandomOf("Titanic") end })
RandomSec:CreateButton({ Name = "Random Gargantuan", Callback = function() spawnRandomOf("Gargantuan") end })

RandomSec:CreateDivider()

RandomSec:CreateButton({
	Name = "Reload pet list",
	Callback = function()
		local n = rebuildPetList()
		if SpawnDrop and SpawnDrop.Refresh then
			pcall(SpawnDrop.Refresh, SpawnDrop, namesOfClass(pickedClass))
		end
		pickedPet = firstOfClass(pickedClass)
		Weave:Notify({ Title = "PetSpawner", Content = n .. " pet(s) found.", Duration = 4 })
	end,
})

RandomSec:CreateButton({
	Name = "One of every (selected class)",
	Callback = function()
		task.spawn(function()
			local class = pickedClass
			local made = 0
			for _, e in ipairs(PET_LIST) do
				if e.class == class then
					made = made + (spawnPet(e.name, pickedGold, pickedScale, 1, pickedInv))
					task.wait()   -- hundreds of big models: yield so the frame does not hitch
				end
			end
			Weave:Notify({
				Title = "PetSpawner",
				Content = string.format("Spawned %d %s pet(s).", made, class),
				Duration = 5,
			})
		end)
	end,
})

RandomSec:CreateDivider()

RandomSec:CreateButton({
	Name = "Clear inventory adds",
	Callback = function()
		local n = clearInventoryAdds()
		-- the visuals stay; only the inventory rows go, so forget the uids we
		-- just removed or removing a visual later would clear a live row
		for _, e in ipairs(spawnedPets) do e.uid = nil end
		Weave:Notify({
			Title = "PetSpawner",
			Content = "Removed " .. n .. " inventory entr" .. (n == 1 and "y." or "ies."),
			Duration = 4,
		})
	end,
})

local SpawnInfo = SpawnTab:CreateSection({ Name = "Spawned", Side = "left", Subtab = "Info" })
local SpawnStatus = SpawnInfo:CreateParagraph({ Title = "Status", Content = "Nothing spawned." })

SpawnInfo:CreateParagraph({
	Title = "Read this",
	Content = "These are visuals ONLY, and only you can see them. Each one is a "
		.. "clone of the pet's art from ReplicatedStorage parented to your camera "
		.. "-- it deals no damage, gives no stats, and does not replicate to the "
		.. "server or to other players. Nothing here touches the real pet system. "
		.. "Sounds and scripts are stripped from the clones, so they are silent "
		.. "and inert.",
})

SpawnInfo:CreateParagraph({
	Title = "About 'Add to inventory'",
	Content = "This writes the pet straight into your local inventory table, so "
		.. "it shows up in the Inventory GUI like a real one. It is still local "
		.. "only: the server has no idea it exists. Equipping, trading, selling "
		.. "or deleting it will be refused by the server, and it disappears the "
		.. "moment the server pushes a save update or you rejoin. Use 'Clear "
		.. "inventory adds' to take the rows back out yourself.",
})

local function upgradeSummary()
	local lines = {}
	for _, id in ipairs(UPGRADE_IDS) do
		if CFG.wanted[id] then
			local def = upgradeDef(id)
			local cap = def and #def.TierPowers or "?"
			local cost = nextCost(id)
			local price = "max"
			if cost then
				local ok, amt = pcall(cost.GetAmount, cost)
				price = ok and tostring(amt) or "?"
			end
			table.insert(lines, string.format("%s  %d/%s  (next: %s)",
				upgradeName(id), upgradeTier(id), tostring(cap), price))
		end
	end

	local orbs = orbCount()
	local head = "Fiesta Orbs: " .. (orbs and tostring(orbs) or "?")
	if #lines == 0 then return head .. "\nNothing selected." end
	return head .. "\n" .. table.concat(lines, "\n")
end

--------------------------------------------------------------------- status
task.spawn(function()
	while task.wait(1) do
		local ok = pcall(function()
			local n = #collectTargets()
			local zone = tostring(currentParentId() or "?")
			TapStatus:Set("Status", string.format(
				"%s | zone: %s | targets: %d | pets: %s",
				running.tap and "Farming" or "Idle", zone, n,
				CFG.petSpeed and (PET_SPEED_MULT .. "x") or "normal"
			))
			UpgStatus:Set("Tiers", upgradeSummary())

			local room = "-"
			local raid = currentRaid()
			if raid and raid.GetRoomNumber then
				local good, r = pcall(raid.GetRoomNumber, raid)
				if good and r then room = tostring(r) end
			end
			MazeStatus:Set("Status", string.format("%s | room: %s | orbs: %s",
				mazeStatus, room, CFG.autoOrbs and "auto" or "off"))

			-- drop any clone that lost its parent (camera reset, respawn, etc.)
			for i = #spawnedPets, 1, -1 do
				local e = spawnedPets[i]
				if not (e.inst and e.inst.Parent) then table.remove(spawnedPets, i) end
			end
			SpawnStatus:Set("Status", string.format(
				"%d spawned | %s: %d of %d pet(s) | inventory: %d",
				#spawnedPets, pickedClass, #namesOfClass(pickedClass), #PET_LIST, #fakeUids))
		end)
		if not ok then break end
	end
end)

Weave:Notify({
	Title = "Fiesta Farm",
	Content = "Loaded. Enable Auto Tap under Farm > Tapping.",
	Duration = 6,
})
