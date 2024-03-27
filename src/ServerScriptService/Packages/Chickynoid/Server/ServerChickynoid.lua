--!native
--!strict

local path = game.ReplicatedFirst.Packages.Chickynoid
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteEvent = ReplicatedStorage:WaitForChild("ChickynoidReplication")
assert(RemoteEvent:IsA("RemoteEvent"))

local UnreliableRemoteEvent = ReplicatedStorage:WaitForChild("ChickynoidUnreliableReplication")
assert(UnreliableRemoteEvent:IsA("UnreliableRemoteEvent"))

local Enums = require(path.Shared.Enums)
local EventType = Enums.EventType
local FastSignal = require(path.Shared.Vendor.FastSignal)

local Simulation = require(path.Shared.Simulation.Simulation)
local TrajectoryModule = require(path.Shared.Simulation.TrajectoryModule)
local DeltaTable = require(path.Shared.Vendor.DeltaTable)
local CommandLayout = require(path.Shared.Simulation.CommandLayout)

local ServerMods = require(script.Parent.ServerMods)
local CharacterData = require(path.Shared.Simulation.CharacterData)

local ServerChickynoid = {}
ServerChickynoid.__index = ServerChickynoid

local PlayerRecord = {}
PlayerRecord.__index = PlayerRecord

ServerChickynoid.PlayerRecord = PlayerRecord

type SimState = Simulation.State
type BinaryTable = CommandLayout.BinaryTable
type SimStateRecord = Simulation.StateRecord
type CharacterData = CharacterData.Class
type Command = CommandLayout.Command
type Simulation = Simulation.Class
type FastSignal = FastSignal.Class

export type Class = typeof(setmetatable(
    {} :: {
        playerRecord: PlayerRecord,
        simulation: Simulation,
        unprocessedCommands: { Command },

        commandSerial: number,
        lastConfirmedCommand: number?,
        lastProcessedCommand: Command?,
        elapsedTime: number,
        playerElapsedTime: number,
        processedTimeSinceLastSnapshot: number,
        errorState: number,
        speedCheatThreshhold: number,
        maxCommandsPerSecond: number,
        smoothFactor: number,
        serverFrames: number,
        hitBoxCreated: FastSignal,
        storedStates: { SimState },
        unreliableCommandSerials: number,
        lastConfirmedPlayerStateFrame: number?,
        lastSeenState: SimState?,
        prevCharacterData: { CharacterData },

        pushPart: BasePart?,
        hitBox: BasePart?,

        debug: {
            processedCommands: number,
            fakeCommandsThisSecond: number,
            antiwarpPerSecond: number,
            timeOfNextSecond: number,
            ping: number,
        },
    },
    ServerChickynoid
))

export type PlayerRecord = typeof(setmetatable(
    {} :: {
        userId: number,
        player: Player?,
        dummy: boolean,
        name: string?,
        chickynoid: ServerChickynoid?,
        previousCharacterData: CharacterData?,
        frame: number,
        slot: number,
        allowedToSpawn: boolean,
        respawnDelay: number,
        respawnTime: number,
        characterMod: string,
        lastConfirmedSnapshotServerFrame: number?,
        reset: boolean?,

        visHistoryList: {
            [number]: {
                [number]: PlayerRecord,
            },
        },

        visibilityList: {
            [number]: PlayerRecord,
        }?,

        pendingWorldState: boolean,
        loaded: boolean,

        OnBeforePlayerSpawn: FastSignal,
        OnPlayerSpawn: FastSignal,
        BotThink: (number) -> ()?,
    },
    PlayerRecord
))

export type IEvent = {
    t: number,
    [any]: any,
}

export type IServerConfig = {
    serverSimulationTime: number,
    serverHz: number,
    fpsMode: number,
}

export type ServerChickynoid = Class

---------------------------------------------------------------------------------------------------------------------------------
-- PLAYER RECORD
---------------------------------------------------------------------------------------------------------------------------------

function PlayerRecord.new(userId: number, player: Player?): PlayerRecord
    local playerRecord = {
        userId = userId,
        player = player,
        dummy = false,
        chickynoid = nil,
        previousCharacterData = nil,
        frame = 0,
        slot = 0,
        allowedToSpawn = true,
        respawnDelay = 2,
        respawnTime = tick() + 2,
        characterMod = "HumanoidChickynoid",
        lastConfirmedSnapshotServerFrame = nil,

        visHistoryList = {},

        pendingWorldState = true,
        loaded = false,

        OnBeforePlayerSpawn = FastSignal.new(),
        OnPlayerSpawn = FastSignal.new(),
    }

    setmetatable(playerRecord, PlayerRecord)

    --[[
    local assignedSlot = self:AssignSlot(playerRecord)
    self:DebugSlots()

    if (assignedSlot == false) then
        if (player ~= nil) then
            player:Kick("Server full, no free chickynoid slots")
        end

        self.loadingPlayerRecords[userId] = nil
        return nil
    end
    ]]
    --

    if player ~= nil then
        playerRecord.dummy = false
        playerRecord.name = player.Name
    else
        -- Is a bot
        playerRecord.dummy = true
    end

    return playerRecord
end

-- selene: allow(shadowing)
function PlayerRecord.SendEventToClient(self: PlayerRecord, event: IEvent): ()
    if self.loaded == false then
        print("warning, player not loaded yet")
    end
    if self.player then
        RemoteEvent:FireClient(self.player, event)
    end
end

-- selene: allow(shadowing)
function PlayerRecord.SendUnreliableEventToClient(self: PlayerRecord, event: IEvent): ()
    if self.loaded == false then
        print("warning, player not loaded yet")
    end

    if self.player then
        UnreliableRemoteEvent:FireClient(self.player, event)
    end
end

-- selene: allow(shadowing)
function PlayerRecord.SendEventToClients(self: PlayerRecord, playerRecords: { PlayerRecord }, event: IEvent): ()
    if self.player then
        for i, record in next, playerRecords do
            if record.loaded == false or record.dummy == true then
                continue
            end

            RemoteEvent:FireClient(record.player, event)
        end
    end
end

-- selene: allow(shadowing)
function PlayerRecord.SendEventToOtherClients(self: PlayerRecord, playerRecords: { PlayerRecord }, event: IEvent): ()
    for i, record in next, playerRecords do
        if record.loaded == false or record.dummy == true then
            continue
        end

        if self == record then
            continue
        end

        RemoteEvent:FireClient(record.player, event)
    end
end

-- selene: allow(shadowing)
function PlayerRecord.SendCollisionData(self: PlayerRecord, collisionRootFolder: Folder, playerSize: Vector3): ()
    local event = {}
    event.t = Enums.EventType.CollisionData
    event.playerSize = playerSize
    event.data = collisionRootFolder
    self:SendEventToClient(event)
end

-- selene: allow(shadowing)
function PlayerRecord.Despawn(self: PlayerRecord): ()
    if self.chickynoid then
        --ServerModule.OnPlayerDespawn:Fire(self)

        print("Despawned!")
        self.chickynoid:Destroy()
        self.chickynoid = nil
        self.respawnTime = tick() + self.respawnDelay

        local event = { t = EventType.ChickynoidRemoving }
        self:SendEventToClient(event)
    end
end

function PlayerRecord.SetCharacterMod(self: PlayerRecord, characterModName: string): ()
    self.characterMod = characterModName
    --ServerModule:SetWorldStateDirty()
end

-- selene: allow(shadowing)
function PlayerRecord.Spawn(self: PlayerRecord): ServerChickynoid?
    if self.loaded == false then
        warn("Spawn() called before player loaded")
        return
    end

    local list = {}
    self:Despawn()

    local chickynoid = ServerChickynoid.new(self)
    self.chickynoid = chickynoid

    for _, obj in pairs(workspace:GetDescendants()) do
        if obj:IsA("SpawnLocation") and obj.Enabled == true then
            table.insert(list, obj)
        end
    end

    if #list > 0 then
        local spawn = list[math.random(1, #list)]
        chickynoid:SetPosition(Vector3.new(spawn.Position.x, spawn.Position.y + 5, spawn.Position.z), true)
    else
        chickynoid:SetPosition(Vector3.new(0, 10, 0), true)
    end

    self.OnBeforePlayerSpawn:Fire()
    --ServerModule.OnBeforePlayerSpawn:Fire(self, playerRecord)

    chickynoid:SpawnChickynoid()
    self.OnPlayerSpawn:Fire()

    return self.chickynoid
end

---------------------------------------------------------------------------------------------------------------------------------
-- SERVER CHICKYNOID
---------------------------------------------------------------------------------------------------------------------------------

--[=[
	Constructs a new [ServerChickynoid] and attaches it to the specified player.
	@return ServerChickynoid
]=]
function ServerChickynoid.new(playerRecord: PlayerRecord): ServerChickynoid
    local self = setmetatable({
        playerRecord = playerRecord,
        simulation = Simulation.new(playerRecord.userId),

        unprocessedCommands = {},
        commandSerial = 0,
        lastConfirmedCommand = nil,
        elapsedTime = 0,
        playerElapsedTime = 0,

        processedTimeSinceLastSnapshot = 0,
        errorState = Enums.NetworkProblemState.None,

        speedCheatThreshhold = 150, -- milliseconds
        maxCommandsPerSecond = 400, -- things have gone wrong if this is hit, but it's good server protection against possible uncapped fps
        smoothFactor = 0.9999, --Smaller is smoother

        serverFrames = 0,

        hitBoxCreated = FastSignal.new(),
        storedStates = {}, --table of the last few states we've send the client, because we use unreliables, we need to switch to ome of these to delta comrpess against once its confirmed

        unreliableCommandSerials = 0, --This number only ever goes up, and discards anything out of order
        lastConfirmedPlayerStateFrame = nil, --Client tells us they've seen this playerstate, so we delta compress against it

        prevCharacterData = {}, -- Rolling history key'd to serverFrame

        debug = {
            processedCommands = 0,
            fakeCommandsThisSecond = 0,
            antiwarpPerSecond = 0,
            timeOfNextSecond = 0,
            ping = 0,
        },
    }, ServerChickynoid)
    -- TODO: The simulation shouldn't create a debug model like this.
    -- For now, just delete it server-side.

    if self.simulation.debugModel then
        self.simulation.debugModel:Destroy()
        self.simulation.debugModel = nil
    end

    --Apply the characterMod
    if playerRecord.characterMod then
        local loadedModule = ServerMods:GetMod("characters", playerRecord.characterMod)
        if loadedModule then
            loadedModule:Setup(self.simulation)
        end
    end

    return self
end

function ServerChickynoid.Destroy(self: ServerChickynoid): ()
    if self.pushPart then
        self.pushPart:Destroy()
        self.pushPart = nil
    end

    if self.hitBox then
        self.hitBox:Destroy()
        self.hitBox = nil
    end
end

function ServerChickynoid.HandleEvent(self: ServerChickynoid, config: IServerConfig, event: { BinaryTable }): ()
    self:HandleClientUnreliableEvent(config, event, false)
end

--[=[
    Sets the position of the character and replicates it to clients.
]=]
function ServerChickynoid.SetPosition(self: ServerChickynoid, position: Vector3, teleport: boolean?): ()
    self.simulation.state.pos = position
    self.simulation.characterData:SetTargetPosition(position, teleport)
end

--[=[
    Returns the position of the character.
]=]
function ServerChickynoid.GetPosition(self: ServerChickynoid): Vector3
    return self.simulation.state.pos
end

function ServerChickynoid.GenerateFakeCommand(self: ServerChickynoid, config: IServerConfig, deltaTime: number): ()
    if self.lastProcessedCommand == nil then
        return
    end

    local command = DeltaTable:DeepCopy(self.lastProcessedCommand)
    command.deltaTime = deltaTime

    local event = {}
    event.t = EventType.Command
    event.command = command
    self:HandleClientUnreliableEvent(config, event, true)

    self.debug.fakeCommandsThisSecond += 1
end

--[=[
	Steps the simulation forward by one frame. This loop handles the simulation
	and replication timings.
]=]
function ServerChickynoid.Think(self: ServerChickynoid, deltaTime: number): ()
    --  Anticheat methods
    --  We keep X ms of commands unprocessed, so that if players stop sending upstream, we have some commands to keep going with
    --  We only allow the player to get +150ms ahead of the servers estimated sim time (Speed cheat), if they're over this, we discard commands
    --  The server will generate a fake command if you underrun (do not have any commands during time between snapshots)
    --  todo: We only allow 15 commands per server tick (ratio of 5:1) if the user somehow has more than 15 commands that are legitimately needing processing, we discard them all

    self.elapsedTime += deltaTime

    --Sort commands by their serial
    table.sort(self.unprocessedCommands, function(a: Command, b: Command)
        return a.serial < b.serial
    end)

    local maxCommandsPerFrame = math.ceil(self.maxCommandsPerSecond * deltaTime)

    local processCounter = 0
    local processed = {}

    for i, command in self.unprocessedCommands do
        processCounter += 1

        --print("server", command.l, command.serverTime)
        TrajectoryModule:PositionWorld(command.serverTime, command.deltaTime)
        self.debug.processedCommands += 1

        --Check for reset
        self:CheckForReset(command)

        --Step simulation!
        self.simulation:ProcessCommand(command)
        processed[command] = true

        if command.localFrame and tonumber(command.localFrame) ~= nil then
            self.lastConfirmedCommand = command.localFrame
            self.lastProcessedCommand = command
        end

        self.processedTimeSinceLastSnapshot += command.deltaTime

        if processCounter > maxCommandsPerFrame and false then
            --dump the remaining commands
            self.errorState = Enums.NetworkProblemState.TooManyCommands
            self.unprocessedCommands = {}
            break
        end
    end

    local newList = {}

    for _, command in pairs(self.unprocessedCommands) do
        if not processed[command] then
            table.insert(newList, command)
        end
    end

    self.unprocessedCommands = newList

    --debug stuff, too many commands a second stuff
    if tick() > self.debug.timeOfNextSecond then
        self.debug.timeOfNextSecond = tick() + 1
        self.debug.antiwarpPerSecond = self.debug.fakeCommandsThisSecond
        self.debug.fakeCommandsThisSecond = 0

        if self.debug.antiwarpPerSecond > 0 then
            print("Lag: ", self.debug.antiwarpPerSecond)
        end
    end
end

--[=[
	Callback for handling movement commands from the client

	@param event table -- The event sent by the client.
	@private
]=]

function ServerChickynoid.HandleClientUnreliableEvent(
    self: ServerChickynoid,
    config: IServerConfig,
    event: { BinaryTable },
    fakeCommand: boolean?
): ()
    if event[2] ~= nil then
        local prevCommand = CommandLayout:DecodeCommand(event[2])
        self:ProcessCommand(config, prevCommand, fakeCommand, true)
    end

    if event[1] ~= nil then
        local command = CommandLayout:DecodeCommand(event[1])
        self:ProcessCommand(config, command, fakeCommand, false)
    end
end

function ServerChickynoid.CheckForReset(self: ServerChickynoid, command: Command): ()
    if command.reset == true then
        self.playerRecord.reset = true
    end
end

function ServerChickynoid.ProcessCommand(
    self: ServerChickynoid,
    config: IServerConfig,
    command: Command,
    fakeCommand: boolean?,
    resent: boolean?
): ()
    if command and type(command) == "table" then
        if
            command.localFrame == nil
            or type(command.localFrame) ~= "number"
            or command.localFrame ~= command.localFrame
        then
            return
        end

        if command.localFrame <= self.unreliableCommandSerials then
            return
        end

        if command.localFrame - self.unreliableCommandSerials > 1 then
            --warn("Skipped a packet", command.l - self.unreliableCommandSerials)

            if resent then
                self.errorState = Enums.NetworkProblemState.DroppedPacketGood
            else
                self.errorState = Enums.NetworkProblemState.DroppedPacketBad
            end
        end

        self.unreliableCommandSerials = command.localFrame

        --Sanitize
        --todo: clean this into a function per type
        if command.x == nil or typeof(command.x) ~= "number" or command.x ~= command.x then
            return
        end
        if command.y == nil or typeof(command.y) ~= "number" or command.y ~= command.y then
            return
        end
        if command.z == nil or typeof(command.z) ~= "number" or command.z ~= command.z then
            return
        end

        if
            command.serverTime == nil
            or typeof(command.serverTime) ~= "number"
            or command.serverTime ~= command.serverTime
        then
            return
        end

        if
            command.playerStateFrame == nil
            or typeof(command.playerStateFrame) ~= "number"
            or command.playerStateFrame ~= command.playerStateFrame
        then
            return
        end

        if command.snapshotServerFrame ~= nil then
            --0 is nil
            if command.snapshotServerFrame > 0 then
                self.playerRecord.lastConfirmedSnapshotServerFrame = command.snapshotServerFrame
            end
        end

        if
            command.deltaTime == nil
            or typeof(command.deltaTime) ~= "number"
            or command.deltaTime ~= command.deltaTime
        then
            return
        end

        if command.fa and (typeof(command.fa) == "Vector3") then
            local vec = command.fa
            if vec.X == vec.X and vec.Y == vec.Y and vec.Z == vec.Z then
                command.fa = vec
            else
                rawset(command, "fa", nil)
            end
        else
            rawset(command, "fa", nil)
        end

        --sanitize
        if not fakeCommand then
            self:SetLastSeenPlayerStateToServerFrame(command.playerStateFrame)

            if config.fpsMode == Enums.FpsMode.Uncapped then
                --Todo: really slow players need to be penalized harder.
                if command.deltaTime > 0.5 then
                    command.deltaTime = 0.5
                end

                --500fps cap
                if command.deltaTime < 1 / 500 then
                    command.deltaTime = 1 / 500
                    --print("Player over 500fps:", self.playerRecord.name)
                end
            elseif config.fpsMode == Enums.FpsMode.Hybrid then
                --Players under 30fps are simulated at 30fps
                if command.deltaTime > 1 / 30 then
                    command.deltaTime = 1 / 30
                end

                --500fps cap
                if command.deltaTime < 1 / 500 then
                    command.deltaTime = 1 / 500
                    --print("Player over 500fps:", self.playerRecord.name)
                end
            elseif config.fpsMode == Enums.FpsMode.Fixed60 then
                command.deltaTime = 1 / 60
            else
                warn("Unhandled FPS mode")
            end
        end

        if command.deltaTime then
            --On the first command, init
            if self.playerElapsedTime == 0 then
                self.playerElapsedTime = self.elapsedTime
            end

            local delta = self.playerElapsedTime - self.elapsedTime

            --see if they've fallen too far behind
            if delta < -(self.speedCheatThreshhold / 1000) then
                self.playerElapsedTime = self.elapsedTime
                self.errorState = Enums.NetworkProblemState.TooFarBehind
            end

            --test if this is wthin speed cheat range?
            --print("delta", self.playerElapsedTime - self.elapsedTime)
            if self.playerElapsedTime > self.elapsedTime + (self.speedCheatThreshhold / 1000) then
                --print("Player too far ahead", self.playerRecord.name)
                --Skipping this command
                self.errorState = Enums.NetworkProblemState.TooFarAhead
            else
                --write it!
                self.playerElapsedTime += command.deltaTime
                command.elapsedTime = self.elapsedTime --Players real time when this was written.

                command.playerElapsedTime = self.playerElapsedTime
                command.fakeCommand = fakeCommand
                command.serial = self.commandSerial
                self.commandSerial += 1

                --This is the only place where commands get written for the rest of the system
                table.insert(self.unprocessedCommands, command)
            end

            --Debug ping
            if command.serverTime ~= nil and fakeCommand == false and self.playerRecord.dummy == false then
                self.debug.ping = math.floor((config.serverSimulationTime - command.serverTime) * 1000)
                self.debug.ping -= ((1 / config.serverHz) * 1000)
            end
        end
    end
end

--We can only delta compress against states that we know for sure the player has seen
function ServerChickynoid.SetLastSeenPlayerStateToServerFrame(self: ServerChickynoid, serverFrame: number): ()
    --we have a queue of these, so find the one the player says they've seen and update to that one
    local record = self.storedStates[serverFrame]
    if record ~= nil then
        self.lastSeenState = DeltaTable:DeepCopy(record)
        self.lastConfirmedPlayerStateFrame = serverFrame

        --delete any older than this
        for timeStamp, record in self.storedStates do
            if timeStamp < serverFrame then
                self.storedStates[timeStamp] = nil
            end
        end
    end
end

--Constructs a playerState based on "now" delta'd against the last playerState the player has confirmed seeing (self.lastConfirmedPlayerState)
--If they have not confirmed anything, return a whole state
function ServerChickynoid.ConstructPlayerStateDelta(
    self: ServerChickynoid,
    serverFrame: number
): (SimStateRecord, number?)
    local currentState = self.simulation:WriteState()

    if self.lastSeenState == nil then
        self.storedStates[serverFrame] = DeltaTable:DeepCopy(currentState)
        return currentState, nil
    end

    --we have one!
    local stateDelta = DeltaTable:MakeDeltaTable(self.lastSeenState, currentState)
    self.storedStates[serverFrame] = DeltaTable:DeepCopy(currentState)

    return stateDelta, self.lastConfirmedPlayerStateFrame
end

--[=[
    Picks a location to spawn the character and replicates it to the client.
    @private
]=]
function ServerChickynoid.SpawnChickynoid(self: ServerChickynoid): ()
    --If you need to change anything about the chickynoid initial state like pos or rotation, use OnBeforePlayerSpawn
    if self.playerRecord.dummy == false then
        local event = {}
        event.t = EventType.ChickynoidAdded
        event.state = self.simulation:WriteState()
        event.characterMod = self.playerRecord.characterMod
        self.playerRecord:SendEventToClient(event)
    end
    --@@print("Spawned character and sent event for player:", self.playerRecord.name)
end

function ServerChickynoid.PostThink(self: ServerChickynoid, worldRoot: Instance, deltaTime: number): ()
    self:UpdateServerCollisionBox(worldRoot)
    self.simulation.characterData:SmoothPosition(deltaTime, self.smoothFactor)
end

function ServerChickynoid.UpdateServerCollisionBox(self: ServerChickynoid, worldRoot: Instance): ()
    --Update their hitbox - this is used for raycasts on the server against the player
    local hitbox = self.hitBox

    if self.hitBox == nil then
        --This box is also used to stop physics props from intersecting the player. Doesn't always work!
        --But if a player does get stuck, they should just be able to move away from it
        local box = Instance.new("Part")
        box.Size = Vector3.new(3, 5, 3)
        box.Parent = worldRoot
        box.Position = self.simulation.state.pos
        box.Anchored = true
        box.CanTouch = true
        box.CanCollide = true
        box.CanQuery = true
        box:SetAttribute("player", self.playerRecord.userId)
        self.hitBox = box
        self.hitBoxCreated:Fire(self.hitBox)

        local debugBox = Instance.new("BoxHandleAdornment")
        debugBox.Color3 = Color3.fromHSV((self.playerRecord.userId / 100) % 1, 1, 1)
        debugBox.AlwaysOnTop = true
        debugBox.ZIndex = 1
        debugBox.Size = box.Size
        debugBox.Adornee = box
        debugBox.Parent = box

        --for streaming enabled games...
        if self.playerRecord.player then
            self.playerRecord.player.ReplicationFocus = box
        end

        hitbox = box
    end

    if hitbox then
        hitbox.CFrame = CFrame.new(self.simulation.state.pos)
        hitbox.AssemblyLinearVelocity = self.simulation.state.vel
    end
end

function ServerChickynoid.RobloxPhysicsStep(self: ServerChickynoid, worldRoot: Instance, dt: number): ()
    self:UpdateServerCollisionBox(worldRoot)
end

return ServerChickynoid
