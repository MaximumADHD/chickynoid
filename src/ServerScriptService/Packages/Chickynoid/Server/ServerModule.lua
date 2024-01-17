--!native
--!strict

--[=[
    @class ChickynoidServer
    @server

    Server namespace for the Chickynoid package.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local path = game.ReplicatedFirst.Packages.Chickynoid

local RemoteEvent = Instance.new("RemoteEvent")
RemoteEvent.Name = "ChickynoidReplication"
RemoteEvent.Parent = ReplicatedStorage

local UnreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
UnreliableRemoteEvent.Name = "ChickynoidUnreliableReplication"
UnreliableRemoteEvent.Parent = ReplicatedStorage

local Enums = require(path.Shared.Enums)
local EventType = Enums.EventType
local ServerChickynoid = require(script.Parent.ServerChickynoid)
local CharacterData = require(path.Shared.Simulation.CharacterData)
local PlayerRecord = ServerChickynoid.PlayerRecord

local DeltaTable = require(path.Shared.Vendor.DeltaTable)
local CollisionModule = require(path.Shared.Simulation.CollisionModule)
local Antilag = require(script.Parent.Antilag)
local FastSignal = require(path.Shared.Vendor.FastSignal)
local ServerMods = require(script.Parent.ServerMods)
local Animations = require(path.Shared.Simulation.Animations)

local ServerSnapshotGen = require(script.Parent.ServerSnapshotGen)
local ServerModule = {}

ServerModule.playerRecords = {}
ServerModule.loadingPlayerRecords = {}
ServerModule.serverStepTimer = 0
ServerModule.serverLastSnapshotFrame = -1 --Frame we last sent snapshots on
ServerModule.serverTotalFrames = 0
ServerModule.serverSimulationTime = 0
ServerModule.framesPerSecondCounter = 0 --Purely for stats
ServerModule.framesPerSecondTimer = 0 --Purely for stats
ServerModule.framesPerSecond = 0 --Purely for stats
ServerModule.accumulatedTime = 0 --fps

ServerModule.startTime = tick()
ServerModule.slots = {}
ServerModule.collisionRootFolder = nil :: Folder?
ServerModule.absoluteMaxSizeOfBuffer = 4096
ServerModule.playerSize = Vector3.new(2, 5, 2)

type FastSignal = FastSignal.Class
type CharacterData = CharacterData.Class
type ServerChickynoid = ServerChickynoid.Class
type PlayerRecord = ServerChickynoid.PlayerRecord

--[=[
	@interface ServerConfig
	@within ChickynoidServer
	.maxPlayers number -- Theoretical max, use a byte for player id
	.fpsMode FpsMode
	.serverHz number
	Server config for Chickynoid.
]=]
ServerModule.config = {
    maxPlayers = 255,
	fpsMode = Enums.FpsMode.Uncapped,
	serverHz = 20,
	antiWarp = false,
	serverSimulationTime = ServerModule.serverSimulationTime,
}

--API
ServerModule.OnPlayerSpawn = FastSignal.new()
ServerModule.OnPlayerDespawn = FastSignal.new()
ServerModule.OnBeforePlayerSpawn = FastSignal.new()
ServerModule.OnPlayerConnected = FastSignal.new()	--Technically this is OnPlayerLoaded

ServerModule.flags = {}
ServerModule.flags.DEBUG_ANTILAG = false
ServerModule.flags.DEBUG_BOT_BANDWIDTH = false
 
--[=[
	Creates connections so that Chickynoid can run on the server.
]=]
function ServerModule.Setup(): ()
    ServerModule.worldRoot = ServerModule.GetDoNotReplicate()

    Players.PlayerAdded:Connect(ServerModule.PlayerConnected)

    --If there are any players already connected, push them through the connection function
    for _, player in pairs(game.Players:GetPlayers()) do
        ServerModule.PlayerConnected(player)
    end

    Players.PlayerRemoving:Connect(ServerModule.PlayerDisconnected)
    RunService.Heartbeat:Connect(ServerModule.RobloxHeartbeat)
    RunService.Stepped:Connect(ServerModule.RobloxPhysicsStep)

    UnreliableRemoteEvent.OnServerEvent:Connect(function(player: Player, event: any)
        local playerRecord = ServerModule.GetPlayerByUserId(player.UserId)

        if playerRecord then
            if playerRecord.chickynoid and type(event) == "table" then
                playerRecord.chickynoid:HandleEvent(ServerModule.config, event)
            end
        end
	end)
	
	RemoteEvent.OnServerEvent:Connect(function(player: Player, event: any)
		--Handle events from loading players
		local playerRecord = ServerModule.loadingPlayerRecords[player.UserId]
		
		if playerRecord then
			if (event.id == "loaded") then
				ServerModule.HandlePlayerLoaded(playerRecord)
			end
			return
		end
		
	end)
	
	Animations:ServerSetup()
    Antilag.Setup(ServerModule)

    --Load the mods
    local modules = ServerMods:GetMods("servermods")

    for _, mod in pairs(modules) do
        mod:Setup(ServerModule)
		-- print("Loaded", _)
    end
end

function ServerModule.HandlePlayerLoaded(playerRecord: PlayerRecord)
	if (playerRecord.loaded == false) then
		playerRecord.loaded = true

		--Move them from loadingPlayerRecords to playerRecords
		ServerModule.playerRecords[playerRecord.userId] = playerRecord		
		ServerModule.loadingPlayerRecords[playerRecord.userId] = nil

		local collisionRootFolder = assert(ServerModule.collisionRootFolder, "!! No collision root folder")
		playerRecord:SendCollisionData(collisionRootFolder, ServerModule.playerSize)
	
		ServerModule.OnPlayerConnected:Fire(ServerModule, playerRecord)
		ServerModule.SetWorldStateDirty()
	end
end

function ServerModule.PlayerConnected(player: Player): ()
    local playerRecord = ServerModule.AddConnection(player.UserId, player)
	
	if (playerRecord and playerRecord.player) then
	    --Spawn the gui
	    for _, child in pairs(game.StarterGui:GetChildren()) do
	        local clone = child:Clone() :: ScreenGui
	        if clone:IsA("ScreenGui") then
	            clone.ResetOnSpawn = false
	        end
	        clone.Parent = playerRecord.player.PlayerGui
		end
	end
end

function ServerModule.AssignSlot(playerRecord: PlayerRecord): boolean
	--Only place this is assigned
    for j = 1, ServerModule.config.maxPlayers do
        if ServerModule.slots[j] == nil then
            ServerModule.slots[j] = playerRecord
            playerRecord.slot = j
            return true
        end
    end

    warn("Slot not found!")
    return false
end

function ServerModule.AddConnection(userId: number, player: Player?): PlayerRecord?
    if ServerModule.playerRecords[userId] or ServerModule.loadingPlayerRecords[userId] then
        warn("Player was already connected.", userId)
        ServerModule.PlayerDisconnected(userId)
    end

    -- Create the players server connection record
	local playerRecord = PlayerRecord.new(userId, player)
	ServerModule.loadingPlayerRecords[userId] = playerRecord
	
	local assignedSlot = ServerModule.AssignSlot(playerRecord)
    ServerModule.DebugSlots()

	playerRecord.OnBeforePlayerSpawn:Connect(function()
		ServerModule.OnPlayerSpawn:Fire(playerRecord)
	end)

    if (assignedSlot == false) then
		if (player ~= nil) then
			player:Kick("Server full, no free chickynoid slots")
		end

		ServerModule.loadingPlayerRecords[userId] = nil
		return nil
	end

    return playerRecord
end

function ServerModule.SendEventToClients(event: any): ()
    RemoteEvent:FireAllClients(event)
end

function ServerModule.SetWorldStateDirty(): ()
	for _, data in next, ServerModule.playerRecords do
		data.pendingWorldState = true
	end
end

function ServerModule.SendWorldState(playerRecord: PlayerRecord): ()
	if not playerRecord.loaded or not playerRecord.pendingWorldState then
		return
	end
	
    local event = {}
    event.t = Enums.EventType.WorldState
    event.worldState = {}
    event.worldState.flags = ServerModule.flags
    event.worldState.players = {}

    for _, data in next, ServerModule.playerRecords do
        local info = {}
        info.name = data.name
		info.userId = data.userId
		info.characterMod = data.characterMod
        event.worldState.players[tostring(data.slot)] = info
    end

    event.worldState.serverHz = ServerModule.config.serverHz
    event.worldState.fpsMode = ServerModule.config.fpsMode
	event.worldState.animations = Animations.animations
	
	playerRecord:SendEventToClient(event)
	playerRecord.pendingWorldState = false
end

function ServerModule.PlayerDisconnected(userId: number): ()
	local loadingPlayerRecord = ServerModule.loadingPlayerRecords[userId]

	if loadingPlayerRecord then
		if loadingPlayerRecord.player then
			print("Player ".. loadingPlayerRecord.player.Name .. " disconnected")
		end

		ServerModule.loadingPlayerRecords[userId] = nil
	end
	
	local playerRecord = ServerModule.playerRecords[userId]
    
	if playerRecord then
		if playerRecord.player then
        	print("Player ".. playerRecord.player.Name .. " disconnected")
		end
		
		playerRecord:Despawn()
		
		--nil this out
		playerRecord.previousCharacterData = nil
		ServerModule.slots[playerRecord.slot] = nil
		playerRecord.slot = 0
		
        ServerModule.playerRecords[userId] = nil
        ServerModule.DebugSlots()
    end

    --Tell everyone
    for _, data in next, ServerModule.playerRecords do
		local event = {}
		event.t = Enums.EventType.PlayerDisconnected
		event.userId = userId
		data:SendEventToClient(event)
	end

	ServerModule.SetWorldStateDirty()
end

function ServerModule.DebugSlots(): ()
    --print a count
    local free = 0
    local used = 0

    for j = 1, ServerModule.config.maxPlayers do
        if not ServerModule.slots[j] then
            free += 1
        else
            used += 1
        end
    end

    print("Players:", used, " (Free:", free, ")")
end

function ServerModule.GetPlayerByUserId(userId: number): PlayerRecord
    return ServerModule.playerRecords[userId]
end

function ServerModule.GetPlayers(): {PlayerRecord}
    return ServerModule.playerRecords
end

function ServerModule.RobloxHeartbeat(deltaTime: number): ()
    if (false) then
	    ServerModule.accumulatedTime += deltaTime
	    local frac = 1 / 60
	    local maxSteps = 0
	    while ServerModule.accumulatedTime > 0 do
	        ServerModule.accumulatedTime -= frac
	        ServerModule.Think(frac)
	        
	        maxSteps+=1
	        if (maxSteps > 2) then
	            ServerModule.accumulatedTime = 0
	            break
	        end
	    end

	      --Discard accumulated time if its a tiny fraction
	    local errorSize = 0.001 --1ms
	    if ServerModule.accumulatedTime > -errorSize then
	        ServerModule.accumulatedTime = 0
	    end
	else
	    --Much simpler - assumes server runs at 60.
	    ServerModule.accumulatedTime = 0
		ServerModule.Think(deltaTime)
	end
end

function ServerModule.RobloxPhysicsStep(deltaTime: number): ()
    for _, playerRecord in ServerModule.GetPlayers() do
        if playerRecord.chickynoid then
			local worldRoot = ServerModule.GetDoNotReplicate()
            playerRecord.chickynoid:RobloxPhysicsStep(worldRoot, deltaTime)
        end
    end
end

function ServerModule.GetDoNotReplicate(): Camera
    local camera = workspace:FindFirstChild("DoNotReplicate")
    if camera == nil then
        camera = Instance.new("Camera")
        camera.Name = "DoNotReplicate"
        camera.Parent = workspace
    end
    return camera
end

function ServerModule.UpdateTiming(deltaTime: number): ()
	--Do fps work
	ServerModule.framesPerSecondCounter += 1
	ServerModule.framesPerSecondTimer += deltaTime
	if ServerModule.framesPerSecondTimer > 1 then
		ServerModule.framesPerSecondTimer = math.fmod(ServerModule.framesPerSecondTimer, 1)
		ServerModule.framesPerSecond = ServerModule.framesPerSecondCounter
		ServerModule.framesPerSecondCounter = 0
	end

	ServerModule.serverSimulationTime = tick() - ServerModule.startTime
end

function ServerModule.Think(deltaTime: number): ()
	ServerModule.UpdateTiming(deltaTime)
	ServerModule.SendWorldStates()
	ServerModule.SpawnPlayers()
	
    CollisionModule:UpdateDynamicParts()

	ServerModule.UpdatePlayerThinks(deltaTime)
	ServerModule.UpdatePlayerPostThinks(deltaTime)
	ServerModule.StepServerMods(deltaTime)
	ServerModule.Do20HzOperations(deltaTime)
end

function ServerModule.StepServerMods(deltaTime: number): ()
	--Step the server mods
	local modules = ServerMods:GetMods("servermods")
	for _, mod in pairs(modules) do
		if (mod.Step) then
			mod:Step(ServerModule, deltaTime)
		end
	end
end


function ServerModule.Do20HzOperations(deltaTime: number): ()
	
	--Calc timings
	ServerModule.serverStepTimer += deltaTime
	ServerModule.serverTotalFrames += 1

	local fraction = (1 / ServerModule.config.serverHz)
	
	--Too soon
	if ServerModule.serverStepTimer < fraction then
		return
	end
		
	while ServerModule.serverStepTimer > fraction do -- -_-'
		ServerModule.serverStepTimer -= fraction
	end
	
	
	ServerModule.WriteCharacterDataForSnapshots()
	
	--Playerstate, for reconciliation of client prediction
	ServerModule.UpdatePlayerStatesToPlayers()
	
	--we write the antilag at 20hz, to match when we replicate snapshots to players
	Antilag.WritePlayerPositions(ServerModule.serverSimulationTime)
	
	--Figures out who can see who, for replication purposes
	ServerModule.DoPlayerVisibilityCalculations()
	
	--Generate the snapshots for all players
	ServerModule.WriteSnapshotsForPlayers()
end


function ServerModule.WriteCharacterDataForSnapshots(): ()
	for userId, playerRecord in next, ServerModule.playerRecords do
		if (playerRecord.chickynoid == nil) then
			continue
		end
		
		--Grab a copy at this serverTotalFrame, because we're going to be referencing this for building snapshots with
		playerRecord.chickynoid.prevCharacterData[ServerModule.serverTotalFrames] = DeltaTable:DeepCopy( playerRecord.chickynoid.simulation.characterData )
		
		--Toss it out if its over a second old
		for timeStamp, rec in playerRecord.chickynoid.prevCharacterData do
			if (timeStamp < ServerModule.serverTotalFrames - 60) then
				playerRecord.chickynoid.prevCharacterData[timeStamp] = nil
			end
		end
	end
end

function ServerModule.UpdatePlayerStatesToPlayers(): ()
	for userId, playerRecord in next, ServerModule.playerRecords do
		--Bots dont generate snapshots, unless we're testing for performance
		if (ServerModule.flags.DEBUG_BOT_BANDWIDTH ~= true) then
			if playerRecord.dummy == true then
				continue
			end
		end			

		if playerRecord.chickynoid ~= nil then
			--see if we need to antiwarp people

			if (ServerModule.config.antiWarp == true) then
				local timeElapsed = playerRecord.chickynoid.processedTimeSinceLastSnapshot

				if (timeElapsed == 0 and playerRecord.chickynoid.lastProcessedCommand ~= nil) then
					--This player didn't move this snapshot
					playerRecord.chickynoid.errorState = Enums.NetworkProblemState.CommandUnderrun

					local timeToPatchOver = 1 / ServerModule.config.serverHz
					playerRecord.chickynoid:GenerateFakeCommand(ServerModule.config, timeToPatchOver)

					--print("Adding fake command ", timeToPatchOver)

					--Move them.
					playerRecord.chickynoid:Think(ServerModule.serverSimulationTime)
				end
				--print("e:" , timeElapsed * 1000)
			end

			playerRecord.chickynoid.processedTimeSinceLastSnapshot = 0

			--Send results of server move
			local event = {}
			event.t = EventType.State
			
			
			--bonus fields
			event.e = playerRecord.chickynoid.errorState
			event.s = ServerModule.framesPerSecond
			
			--required fields
			event.lastConfirmedCommand = playerRecord.chickynoid.lastConfirmedCommand
			event.serverTime = ServerModule.serverSimulationTime
			event.serverFrame = ServerModule.serverTotalFrames
			event.playerStateDelta, event.playerStateDeltaFrame = playerRecord.chickynoid:ConstructPlayerStateDelta(ServerModule.serverTotalFrames)

			playerRecord:SendUnreliableEventToClient(event)
			
			--Clear the error state flag 
			playerRecord.chickynoid.errorState = Enums.NetworkProblemState.None
		end
	end
end

function ServerModule.SendWorldStates(): ()
	--send worldstate
	for _, playerRecord in next, ServerModule.playerRecords do
		if (playerRecord.pendingWorldState == true) then
			ServerModule.SendWorldState(playerRecord)
		end	
	end
end

function ServerModule.SpawnPlayers(): ()
	--Spawn players
	for _, playerRecord in next, ServerModule.playerRecords do
		if (playerRecord.loaded == false) then
			continue
		end
		
		if (playerRecord.chickynoid and playerRecord.reset) then
			playerRecord.reset = false
			playerRecord:Despawn()
		end
				
		if playerRecord.chickynoid == nil and playerRecord.allowedToSpawn == true then
			if tick() > playerRecord.respawnTime then
				playerRecord:Spawn()
			end
		end
	end
end

function ServerModule.UpdatePlayerThinks(deltaTime: number): ()
	debug.profilebegin("UpdatePlayerThinks")
	--1st stage, pump the commands
	for _, playerRecord in ServerModule.GetPlayers() do
		if playerRecord.dummy == true and playerRecord.BotThink then
			playerRecord.BotThink(deltaTime)
		end

		if playerRecord.chickynoid then
			playerRecord.chickynoid:Think(deltaTime)

			if playerRecord.chickynoid.simulation.state.pos.Y < -2000 then
				playerRecord:Despawn()
			end
		end
	end
	debug.profileend()
end

function ServerModule.UpdatePlayerPostThinks(deltaTime: number): ()
	for i, playerRecord in ServerModule.GetPlayers() do
		if playerRecord.chickynoid then
			local worldRoot = ServerModule.GetDoNotReplicate()
			playerRecord.chickynoid:PostThink(worldRoot, deltaTime)
		end
	end
end

function ServerModule.DoPlayerVisibilityCalculations(): ()
	debug.profilebegin("DoPlayerVisibilityCalculations")
	
	--This gets done at 20hz
	local modules = ServerMods:GetMods("servermods")
	
	for key,mod in modules do
		if (mod.UpdateVisibility ~= nil) then
			mod:UpdateVisibility(ServerModule, ServerModule.flags.DEBUG_BOT_BANDWIDTH)
		end
	end
	
	--Store the current visibility table for the current server frame
	for userId, playerRecord in ServerModule.GetPlayers() do
		local visibilityList = playerRecord.visibilityList

		if visibilityList then
			playerRecord.visHistoryList[ServerModule.serverTotalFrames] = visibilityList
		end
		
		--Store two seconds tops
		local cutoff = ServerModule.serverTotalFrames - 120
		if (playerRecord.lastConfirmedSnapshotServerFrame ~= nil) then
			cutoff = math.max(playerRecord.lastConfirmedSnapshotServerFrame, cutoff)
		end
		
		for timeStamp, rec in playerRecord.visHistoryList do
			if (timeStamp < cutoff) then
				playerRecord.visHistoryList[timeStamp] = nil
			end
		end
	end
	
	debug.profileend()
end

 
function ServerModule.WriteSnapshotsForPlayers(): ()
	ServerSnapshotGen:DoWork(ServerModule.playerRecords, ServerModule.serverTotalFrames, ServerModule.serverSimulationTime, ServerModule.flags.DEBUG_BOT_BANDWIDTH)
	ServerModule.serverLastSnapshotFrame = ServerModule.serverTotalFrames
end
	
function ServerModule.RecreateCollisions(rootFolder: Folder): ()
    ServerModule.collisionRootFolder = rootFolder

    for _, playerRecord in next, ServerModule.playerRecords do
        playerRecord:SendCollisionData(rootFolder, ServerModule.playerSize)
    end

    CollisionModule:MakeWorld(rootFolder, ServerModule.playerSize) 
end

return ServerModule
