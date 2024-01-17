--!native
--!strict

--[=[
    @class ClientModule
    @client

    Client namespace for the Chickynoid package.
]=]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteEvent = ReplicatedStorage:WaitForChild("ChickynoidReplication")
assert(RemoteEvent:IsA("RemoteEvent"))

local UnreliableRemoteEvent = ReplicatedStorage:WaitForChild("ChickynoidUnreliableReplication")
assert(UnreliableRemoteEvent:IsA("UnreliableRemoteEvent"))

local path = script.Parent.Parent

local ClientChickynoid = require(script.Parent.ClientChickynoid)
local CollisionModule = require(path.Shared.Simulation.CollisionModule)
local CharacterModel = require(script.Parent.CharacterModel)
local CharacterData = require(path.Shared.Simulation.CharacterData)
local ClientWeaponModule = require(path.Client.WeaponsClient)
local FastSignal = require(path.Shared.Vendor.FastSignal)
local ClientMods = require(path.Client.ClientMods)
local Animations = require(path.Shared.Simulation.Animations)
local DeltaTable = require(path.Shared.Vendor.DeltaTable)

local Enums = require(path.Shared.Enums)
local MathUtils = require(path.Shared.Simulation.MathUtils)

local FpsGraph = require(path.Client.FpsGraph)
local NetGraph = require(path.Client.NetGraph)

local EventType = Enums.EventType
local ClientModule = {}

type CharacterData = CharacterData.Class
type CharacterDataRecord = CharacterData.DataRecord

type ClientChickynoid = ClientChickynoid.Class
type CharacterModel = CharacterModel.Class
type LazyTable = DeltaTable.LazyTable
type Self = typeof(ClientModule)

type WorldPlayer = {
    name: string,
    userId: number,
    characterMod: string,
}

ClientModule.localChickynoid = nil :: ClientChickynoid?

ClientModule.snapshots = {} :: {
    [number]: LazyTable,
}

ClientModule.estimatedServerTime = 0 --This is the time estimated from the snapshots
ClientModule.estimatedServerTimeOffset = 0
ClientModule.snapshotServerFrame = 0 --Server frame of the last snapshot we got
ClientModule.mostRecentSnapshotComparedTo = nil :: LazyTable? --When we've successfully compared against a previous snapshot, mark what it was (so we don't delete it!)

ClientModule.validServerTime = false
ClientModule.startTime = tick()

ClientModule.characters = {} :: {
    [number]: {
        userId: number,
        characterModel: CharacterModel?,
        frame: number?,
        position: Vector3?,
        characterData: CharacterData?,
        characterDataRecord: CharacterDataRecord?,
        localPlayer: boolean?,
    },
}

ClientModule.localFrame = 0

ClientModule.worldState = nil :: {
    flags: {
        [string]: boolean,
    },

    players: {
        [string]: WorldPlayer,
    },

    fpsMode: number,
    serverHz: number,

    animations: {
        [string]: {
            name: string,
            length: number,
            loop: boolean,
            priority: number,
            speed: number,
            weight: number,
            enabled: boolean,
        },
    },
}?

ClientModule.fpsMax = 144 --Think carefully about changing this! Every extra frame clients make, puts load on the server
ClientModule.fpsIsCapped = true --Dynamically sets to true if your fps is fpsMax + 5
ClientModule.fpsMin = 25 --If you're slower than this, your step will be broken up

ClientModule.cappedElapsedTime = 0 --
ClientModule.timeSinceLastThink = 0
ClientModule.timeUntilRetryReset = tick() + 15 -- 15 seconds grace on connection
ClientModule.frameCounter = 0
ClientModule.frameSimCounter = 0
ClientModule.frameCounterTime = 0
ClientModule.stateCounter = 0 --Num states coming in

ClientModule.accumulatedTime = 0

ClientModule.debugBoxes = {}
ClientModule.debugMarkPlayers = nil

--Netgraph settings
ClientModule.showFpsGraph = false
ClientModule.showNetGraph = false
ClientModule.showDebugMovement = true

ClientModule.ping = 0
ClientModule.pings = {}

ClientModule.useSubFrameInterpolation = false
ClientModule.prevLocalCharacterData = nil :: LazyTable?
ClientModule.timeOfLastData = tick()

--The local character
ClientModule.characterModel = nil :: CharacterModel?

--Server provided collision data
ClientModule.playerSize = Vector3.new(2, 5, 5)
ClientModule.collisionRoot = workspace

--Milliseconds of *extra* buffer time to account for ping flux
ClientModule.interpolationBuffer = 20

--Signals
ClientModule.OnNetworkEvent = FastSignal.new()
ClientModule.OnCharacterModelCreated = FastSignal.new()
ClientModule.OnCharacterModelDestroyed = FastSignal.new()

--Callbacks
ClientModule.characterModelCallbacks = {}
ClientModule.partialSnapshot = nil :: LazyTable?

ClientModule.partialSnapshotFrame = 0
ClientModule.fixedPhysicsSteps = false
ClientModule.gameRunning = false

ClientModule.flags = {
    HANDLE_CAMERA = true,
    USE_PRIMARY_PART = false,
    USE_ALTERNATE_TIMING = true,
}

ClientModule.weaponsClient = ClientWeaponModule
ClientModule.previousPos = nil :: Vector3?

function ClientModule.Setup(self: Self)
    local eventHandler = {} :: {
        [number]: (event: LazyTable) -> (),
    }

    eventHandler[EventType.DebugBox] = function(event)
        ClientModule:DebugBox(event.pos, event.text)
    end

    --EventType.ChickynoidAdded
    eventHandler[EventType.ChickynoidAdded] = function(event)
        local position = event.position
        print("Chickynoid spawned at", position)

        if self.localChickynoid == nil then
            self.localChickynoid = ClientChickynoid.new(position, event.characterMod)
        end

        --Force the state
        assert(self.localChickynoid).simulation:ReadState(event.state)
        self.prevLocalCharacterData = nil
    end

    eventHandler[EventType.ChickynoidRemoving] = function(_event)
        print("Local chickynoid removing")

        if self.localChickynoid ~= nil then
            self.localChickynoid:Destroy()
            self.localChickynoid = nil
        end

        self.prevLocalCharacterData = nil

        if self.characterModel then
            self.characterModel:DestroyModel()
            self.characterModel = nil
        end

        game.Players.LocalPlayer.Character = nil
        self.characters[game.Players.LocalPlayer.UserId] = nil
    end

    -- EventType.State
    eventHandler[EventType.State] = function(event)
        if self.localChickynoid then
            local mispredicted, ping = self.localChickynoid:HandleNewPlayerState(
                event.playerStateDelta,
                event.playerStateDeltaFrame,
                event.lastConfirmedCommand,
                event.serverTime,
                event.serverFrame
            )

            if ping then
                --Keep a rolling history of pings
                table.insert(self.pings, ping)
                if #self.pings > 20 then
                    table.remove(self.pings, 1)
                end

                self.stateCounter += 1

                if self.showNetGraph == true then
                    self:AddPingToNetgraph(mispredicted, event.s, event.e, ping)
                end

                if mispredicted then
                    FpsGraph:SetFpsColor(Color3.new(1, 1, 0))
                else
                    FpsGraph:SetFpsColor(Color3.new(0, 1, 0))
                end
            end
        end
    end

    -- EventType.WorldState
    eventHandler[EventType.WorldState] = function(event)
        print("Got worldstate")
        self.worldState = event.worldState

        Animations:SetAnimationsFromWorldState(event.worldState.animations)
    end

    -- EventType.Snapshot
    eventHandler[EventType.Snapshot] = function(serialized)
        local event = self:DeserializeSnapshot(serialized)

        if event == nil then
            return
        end

        if self.partialSnapshot ~= nil and event.f < self.partialSnapshotFrame then
            --Discard, part of an abandoned snapshot
            warn("Discarding old snapshot piece.")
            return
        end

        if self.partialSnapshot ~= nil and event.f ~= self.partialSnapshotFrame then
            warn("Didnt get all the pieces of a snapshot, discarding and starting anew")
            self.partialSnapshot = nil
        end

        if self.partialSnapshot == nil then
            self.partialSnapshot = {}
            self.partialSnapshotFrame = event.f
        end

        assert(self.partialSnapshot)

        if event.f == self.partialSnapshotFrame then
            --Store it

            self.partialSnapshot[event.s] = event

            local foundAll = true
            for j = 1, event.m do
                if self.partialSnapshot[j] == nil then
                    foundAll = false
                    break
                end
            end

            if foundAll == true then
                self:SetupTime(event.serverTime)

                --Concatenate all the player records in here
                local newRecords = {}
                for _, snap in self.partialSnapshot do
                    for key, rec in snap.charData do
                        newRecords[key] = rec
                    end
                end
                event.charData = newRecords

                --Record our snapshotServerFrame - this is used to let the server know what we have correctly seen
                self.snapshotServerFrame = event.f

                --Record the snapshot
                table.insert(self.snapshots, event)
                self.previousSnapshot = event

                --Remove old ones, but keep the most recent one we compared to
                while #self.snapshots > 40 do
                    table.remove(self.snapshots, 1)
                end
                --Clear the partial
                self.partialSnapshot = nil
            end
        end
    end

    eventHandler[EventType.CollisionData] = function(event)
        self.playerSize = event.playerSize
        self.collisionRoot = event.data
        CollisionModule:MakeWorld(self.collisionRoot, self.playerSize)
    end

    eventHandler[EventType.PlayerDisconnected] = function(event)
        local characterRecord = self.characters[event.userId]
        if characterRecord and characterRecord.characterModel then
            characterRecord.characterModel:DestroyModel()
        end
        --Final Cleanup
        CharacterModel:PlayerDisconnected(event.userId)
    end

    RemoteEvent.OnClientEvent:Connect(function(event)
        self.timeOfLastData = tick()

        local func = eventHandler[event.t]
        if func ~= nil then
            func(event)
        else
            ClientWeaponModule:HandleEvent(self, event)
            self.OnNetworkEvent:Fire(self, event)
        end
    end)

    UnreliableRemoteEvent.OnClientEvent:Connect(function(event)
        self.timeOfLastData = tick()

        local func = eventHandler[event.t]
        if func ~= nil then
            func(event)
        else
            ClientWeaponModule:HandleEvent(self, event)
            self.OnNetworkEvent:Fire(self, event)
        end
    end)

    local function Step(deltaTime)
        if self.gameRunning == false then
            return
        end

        if self.showFpsGraph == false then
            FpsGraph:Hide()
        end
        if self.showNetGraph == false then
            NetGraph:Hide()
        end

        self:DoFpsCount(deltaTime)

        --Do a framerate cap to 144? fps
        self.cappedElapsedTime += deltaTime
        self.timeSinceLastThink += deltaTime
        local fraction = 1 / self.fpsMax

        --Do we process a frame?
        if self.cappedElapsedTime < fraction and self.fpsIsCapped == true then
            return --If not enough time for a whole frame has elapsed
        end
        self.cappedElapsedTime = math.fmod(self.cappedElapsedTime, fraction)

        --Netgraph
        if self.showFpsGraph == true then
            FpsGraph:Scroll()
            local fps = 1 / self.timeSinceLastThink
            FpsGraph:AddBar(fps / 2, FpsGraph.fpsColor, 0)
        end

        --Think
        self:ProcessFrame(self.timeSinceLastThink)

        --Do Client Mods
        local modules = ClientMods:GetMods("clientmods")
        for _, value in pairs(modules) do
            value:Step(self, self.timeSinceLastThink)
        end

        self.timeSinceLastThink = 0
    end

    local bindToRenderStepLatch = false

    --BindToRenderStep is the correct place to step your own custom simulations. The dt is the same one used by particle systems and cameras.
    --1) The deltaTime is sampled really early in the frame and has the least flux (way less than heartbeat)
    --2) Functionally, this is similar to PreRender, but PreRender runs AFTER the camera has updated, but we need to run before it
    --	 	(hence Enum.RenderPriority.Input)
    --3) Oh No. BindToRenderStep is not called in the background, so we use heartbeat to call Step if BindToRenderStep is not available
    RunService:BindToRenderStep("chickynoidCharacterUpdate", Enum.RenderPriority.Input.Value, function(dt)
        if self.flags.USE_ALTERNATE_TIMING == true then
            if dt > 0.2 then
                dt = 0.2
            end
            Step(dt)
            bindToRenderStepLatch = false
        end
    end)

    RunService.Heartbeat:Connect(function(dt)
        if self.flags.USE_ALTERNATE_TIMING == true then
            if bindToRenderStepLatch == true then
                Step(dt)
            end
            bindToRenderStepLatch = true
        else
            Step(dt)
        end
    end)

    --Load the mods
    local mods = ClientMods:GetMods("clientmods")
    for id, mod in mods do
        mod:Setup(self)
        print("Loaded", id)
    end

    --WeaponModule
    ClientWeaponModule:Setup(self)

    --Wait for the game to be loaded
    task.spawn(function()
        while game:IsLoaded() == false do
            wait()
        end

        print("Sending loaded event")
        self.gameRunning = true

        --Notify the server
        local event = {}
        event.id = "loaded"
        RemoteEvent:FireServer(event)
    end)
end

function ClientModule.GetClientChickynoid(self: Self)
    return self.localChickynoid
end

function ClientModule.GetCollisionRoot(self: Self)
    return self.collisionRoot
end

function ClientModule.DoFpsCount(self: Self, deltaTime: number)
    self.frameCounter += 1
    self.frameCounterTime += deltaTime

    if self.frameCounterTime > 1 then
        while self.frameCounterTime > 1 do
            self.frameCounterTime -= 1
        end
        --print("FPS: real ", self.frameCounter, "( physics: ",self.frameSimCounter ,")")

        if self.frameCounter > self.fpsMax + 5 then
            if self.showFpsGraph == true then
                FpsGraph:SetWarning("(Cap your fps to " .. self.fpsMax .. ")")
            end
            self.fpsIsCapped = true
        else
            if self.showFpsGraph == true then
                FpsGraph:SetWarning("")
            end
            self.fpsIsCapped = false
        end
        if self.showFpsGraph == true then
            if self.frameCounter == self.frameSimCounter then
                FpsGraph:SetFpsText("Fps: " .. self.frameCounter .. " CmdRate: " .. self.stateCounter)
            else
                FpsGraph:SetFpsText("Fps: " .. self.frameCounter .. " Sim: " .. self.frameSimCounter)
            end
        end

        self.frameCounter = 0
        self.frameSimCounter = 0
        self.stateCounter = 0
    end
end

--Use this instead of raw tick()
function ClientModule.LocalTick(self: Self)
    return tick() - self.startTime
end

function ClientModule.ProcessFrame(self: Self, deltaTime: number)
    if self.worldState == nil then
        --Waiting for worldstate
        return
    end
    --Have we at least tried to figure out the server time?
    if self.validServerTime == false then
        return
    end

    --stats
    self.frameSimCounter += 1

    --Do a new frame!!
    self.localFrame += 1

    --Start building the world view, based on us having enough snapshots to do so
    self.estimatedServerTime = self:LocalTick() - self.estimatedServerTimeOffset

    --Calc the SERVER point in time to render out
    --Because we need to be between two snapshots, the minimum search time is "timeBetweenFrames"
    --But because there might be network flux, we add some extra buffer too
    local timeBetweenServerFrames = (1 / self.worldState.serverHz)
    local searchPad = math.clamp(self.interpolationBuffer, 0, 500) * 0.001
    local pointInTimeToRender = self.estimatedServerTime - (timeBetweenServerFrames + searchPad)

    local subFrameFraction = 0

    local bulkMoveToList = { parts = {}, cframes = {} }

    --Step the chickynoid
    if self.localChickynoid then
        local fixedPhysics: number?
        if self.worldState.fpsMode == Enums.FpsMode.Hybrid then
            if deltaTime >= 1 / 30 then
                fixedPhysics = 30
            end
        elseif self.worldState.fpsMode == Enums.FpsMode.Fixed60 then
            fixedPhysics = 60
        elseif self.worldState.fpsMode == Enums.FpsMode.Uncapped then
            fixedPhysics = nil
        else
            warn("Unhandled FPS Mode")
        end

        if fixedPhysics ~= nil then
            --Fixed physics steps
            local frac = 1 / fixedPhysics

            self.accumulatedTime += deltaTime
            local count = 0

            while self.accumulatedTime > 0 do
                self.accumulatedTime -= frac

                if self.useSubFrameInterpolation == true then
                    --Todo: could do a small (rarely used) optimization here and only copy the 2nd to last one..
                    local chickynoid = self.localChickynoid

                    if chickynoid then
                        --Capture the state of the client before the current simulation
                        self.prevLocalCharacterData = chickynoid.simulation.characterData:Serialize()
                    end
                end

                --Step!

                local command = self:GenerateCommandBase(pointInTimeToRender, frac)

                if self.localChickynoid then
                    self.localChickynoid:Heartbeat(command, pointInTimeToRender, frac)
                end

                ClientWeaponModule:ProcessCommand(command)
                count += 1
            end

            if self.useSubFrameInterpolation == true then
                --if this happens, we have over-simulated
                if self.accumulatedTime < 0 then
                    --we need to do a sub-frame positioning
                    local subFrame = math.abs(self.accumulatedTime) --How far into the next frame are we (we've already simulated 100% of this)
                    subFrame /= frac --0..1

                    if subFrame < 0 or subFrame > 1 then
                        warn("Subframe calculation wrong", subFrame)
                    end

                    subFrameFraction = 1 - subFrame
                end
            end

            if self.showFpsGraph == true then
                if count > 0 then
                    local pixels = 1000 / fixedPhysics
                    FpsGraph:AddPoint((count * pixels), Color3.new(0, 1, 1), 3)
                    FpsGraph:AddBar(math.abs(self.accumulatedTime * 1000), Color3.new(1, 1, 0), 2)
                else
                    FpsGraph:AddBar(math.abs(self.accumulatedTime * 1000), Color3.new(1, 1, 0), 2)
                end
            end
        else
            --For this to work, the server has to accept deltaTime from the client
            local command = self:GenerateCommandBase(pointInTimeToRender, deltaTime)
            self.localChickynoid:Heartbeat(command, pointInTimeToRender, deltaTime)
            ClientWeaponModule:ProcessCommand(command)
        end

        if self.characterModel == nil and self.localChickynoid then
            --Spawn the character in
            print("Creating local model for UserId", game.Players.LocalPlayer.UserId)
            local mod = self:GetPlayerDataByUserId(game.Players.LocalPlayer.UserId)

            if mod then
                local charModel = CharacterModel.new(game.Players.LocalPlayer.UserId, mod.characterMod)
                self.characterModel = charModel

                for _, characterModelCallback in ipairs(self.characterModelCallbacks) do
                    charModel:SetCharacterModel(characterModelCallback)
                end

                charModel:CreateModel()
                self.OnCharacterModelCreated:Fire(charModel)

                local record = {}
                record.userId = game.Players.LocalPlayer.UserId
                record.characterModel = charModel
                record.localPlayer = true

                self.characters[record.userId] = record
            end
        end

        if self.characterModel ~= nil then
            --Blend out the mispredict value
            self.localChickynoid.mispredict =
                MathUtils:VelocityFriction(self.localChickynoid.mispredict, 0.1, deltaTime)
            self.characterModel.mispredict = self.localChickynoid.mispredict

            local localRecord = self.characters[game.Players.LocalPlayer.UserId]

            if self.fixedPhysicsSteps == true then
                if
                    self.useSubFrameInterpolation == false
                    or subFrameFraction == 0
                    or self.prevLocalCharacterData == nil
                then
                    self.characterModel:Think(
                        deltaTime,
                        self.localChickynoid.simulation.characterData.serialized,
                        bulkMoveToList
                    )
                    localRecord.characterData = self.localChickynoid.simulation.characterData
                else
                    --Calculate a sub-frame interpolation
                    local data = CharacterData:Interpolate(
                        self.prevLocalCharacterData,
                        self.localChickynoid.simulation.characterData.serialized,
                        subFrameFraction
                    )
                    self.characterModel:Think(deltaTime, data)
                    -- localRecord.characterData = data -- !! FIXME: This assignment is invalid.
                end
            else
                self.characterModel:Think(
                    deltaTime,
                    self.localChickynoid.simulation.characterData.serialized,
                    bulkMoveToList
                )
                localRecord.characterData = self.localChickynoid.simulation.characterData
            end

            --store local data
            localRecord.frame = self.localFrame

            if localRecord.characterData then
                localRecord.position = localRecord.characterData:GetPosition()
            end

            if self.showFpsGraph == true then
                if self.showDebugMovement == true then
                    local pos = localRecord.position
                    if pos and self.previousPos ~= nil then
                        local delta = pos - self.previousPos
                        FpsGraph:AddPoint(delta.Magnitude * 200, Color3.new(0, 0, 1), 4)
                    end
                    self.previousPos = pos
                end
            end

            -- Bind the camera
            if self.flags.HANDLE_CAMERA ~= false then
                local camera = workspace.CurrentCamera
                local model = self.characterModel.model

                if model then
                    local humanoid = model:FindFirstChildOfClass("Humanoid")

                    if humanoid and camera.CameraSubject ~= humanoid then
                        camera.CameraSubject = humanoid
                        camera.CameraType = Enum.CameraType.Custom
                    end
                end
            end

            --Bind the local character, which activates all the thumbsticks etc
            game.Players.LocalPlayer.Character = self.characterModel.model
        end
    end

    local last = nil
    local prev = self.snapshots[1]

    for _, value in pairs(self.snapshots) do
        if value.serverTime > pointInTimeToRender then
            last = value
            break
        end

        prev = value
    end

    local debugData = {}

    if prev and last and prev ~= last then
        --So pointInTimeToRender is between prev.t and last.t
        local frac = (pointInTimeToRender - prev.serverTime) / timeBetweenServerFrames

        debugData.frac = frac
        debugData.prev = prev.t
        debugData.last = last.t

        for userId, lastData in last.charData do
            local prevData = prev.charData[userId]

            if prevData == nil then
                continue
            end

            local dataRecord: CharacterDataRecord = CharacterData:Interpolate(prevData, lastData, frac)
            local character = self.characters[userId]

            --Add the character
            if character == nil then
                local mod = self:GetPlayerDataByUserId(userId)

                
                if mod then
                    local record = {}
                    record.userId = userId    
                    record.characterModel = CharacterModel.new(userId, mod.characterMod)
                    record.characterModel:CreateModel()

                    self.OnCharacterModelCreated:Fire(record.characterModel)
                    character = record

                    self.characters[userId] = record
                end
            end

            character.frame = self.localFrame
            character.position = dataRecord.pos
            character.characterDataRecord = dataRecord

            --Update it
            if character.characterModel then
                character.characterModel:Think(deltaTime, dataRecord, bulkMoveToList)
            end
        end

        --Remove any characters who were not in this snapshot
        for key, value in self.characters do
            if key == game.Players.LocalPlayer.UserId then
                continue
            end

            if value.frame ~= self.localFrame then
                self.OnCharacterModelDestroyed:Fire(value.characterModel)

                if value.characterModel then
                    value.characterModel:DestroyModel()
                    value.characterModel = nil
                end

                self.characters[key] = nil
            end
        end
    end

    --bulkMoveTo
    if bulkMoveToList then
        workspace:BulkMoveTo(bulkMoveToList.parts, bulkMoveToList.cframes, Enum.BulkMoveMode.FireCFrameChanged)
    end

    --render in the rockets
    -- local timeToRenderRocketsAt = self.estimatedServerTime
    local timeToRenderRocketsAt = pointInTimeToRender --laggier but more correct
    ClientWeaponModule:Think(timeToRenderRocketsAt, deltaTime)

    if self.debugMarkPlayers ~= nil then
        self:DrawBoxOnAllPlayers(self.debugMarkPlayers)
        self.debugMarkPlayers = nil
    end
end

function ClientModule.GetCharacters(self: Self)
    return self.characters
end

-- This tries to figure out a correct delta for the server time
-- Better to update this infrequently as it will cause a "pop" in prediction
-- Thought: Replace with roblox solution or converging solution?
function ClientModule.SetupTime(self: Self, serverActualTime: number)
    local oldDelta = self.estimatedServerTimeOffset
    local newDelta = self:LocalTick() - serverActualTime
    self.validServerTime = true

    local delta = oldDelta - newDelta
    if math.abs(delta * 1000) > 50 then --50ms out? try again
        self.estimatedServerTimeOffset = newDelta
    end
end

-- Register a callback that will determine a character model
function ClientModule.SetCharacterModel(self: Self, callback: (userId: number) -> Model?)
    table.insert(self.characterModelCallbacks, callback)
end

function ClientModule.GetPlayerDataBySlotId(self: Self, slotId: number): WorldPlayer?
    local slotString = tostring(slotId)

    if self.worldState == nil then
        return nil
    end

    --worldState.players is indexed by a *STRING* not a int
    return self.worldState.players[slotString]
end

function ClientModule:GetPlayerDataByUserId(userId: number): WorldPlayer? -- TODO: Type properly.
    if self.worldState == nil then
        return nil
    end

    for key, value in pairs(self.worldState.players) do
        if value.userId == userId then
            return value
        end
    end

    return nil
end

function ClientModule.DeserializeSnapshot(self: Self, event): LazyTable?
    local offset = 0
    local bitBuffer = event.b

    local recordCount = buffer.readu8(bitBuffer, offset)
    offset += 1

    --Find what this was delta compressed against
    local previousSnapshot = nil

    for key, value in self.snapshots do
        if value.f == event.cf then
            previousSnapshot = value
            break
        end
    end

    if previousSnapshot == nil and event.cf ~= nil then
        warn("Prev snapshot not found", event.cf)
        print("num snapshots", #self.snapshots)
        return nil
    end

    self.mostRecentSnapshotComparedTo = previousSnapshot

    event.charData = {}

    for _ = 1, recordCount do
        local record = CharacterData.new()

        --CharacterData.CopyFrom(self.previous)

        local slotId = buffer.readu8(bitBuffer, offset)
        offset += 1

        local user = self:GetPlayerDataBySlotId(slotId)
        if user then
            if previousSnapshot ~= nil then
                local previousRecord = previousSnapshot.charData[user.userId]
                if previousRecord then
                    record:CopySerialized(previousRecord)
                end
            end
            offset = record:DeserializeFromBitBuffer(bitBuffer, offset)

            event.charData[user.userId] = record.serialized
        else
            warn("UserId for slot " .. slotId .. " not found!")
            --So things line up
            offset = record:DeserializeFromBitBuffer(bitBuffer, offset)
        end
    end

    return event
end

function ClientModule:GetGui()
    local gui = game.Players.LocalPlayer:FindFirstChild("PlayerGui")
    return gui
end

function ClientModule:DebugMarkAllPlayers(text)
    self.debugMarkPlayers = text
end

function ClientModule.DrawBoxOnAllPlayers(self: Self, text)
    if self.worldState == nil then
        return
    end
    if self.worldState.flags.DEBUG_ANTILAG ~= true then
        return
    end

    local models = self:GetCharacters()
    for _, record in pairs(models) do
        if record.localPlayer == true then
            continue
        end

        if not record.position then
            continue
        end

        local instance = Instance.new("Part")
        instance.Size = Vector3.new(3, 5, 3)
        instance.Transparency = 0.5
        instance.Color = Color3.new(0, 1, 0)
        instance.Anchored = true
        instance.CanCollide = false
        instance.CanTouch = false
        instance.CanQuery = false
        instance.Position = record.position
        instance.Parent = workspace

        self:AdornText(instance, Vector3.new(0, 3, 0), text, Color3.new(0.5, 1, 0.5))

        self.debugBoxes[instance] = tick() + 5
    end

    for key, value in pairs(self.debugBoxes) do
        if tick() > value then
            key:Destroy()
            self.debugBoxes[key] = nil
        end
    end
end

function ClientModule.DebugBox(self: Self, pos: Vector3, text: string)
    local instance = Instance.new("Part")
    instance.Size = Vector3.new(3, 5, 3)
    instance.Transparency = 1
    instance.Color = Color3.new(1, 0, 0)
    instance.Anchored = true
    instance.CanCollide = false
    instance.CanTouch = false
    instance.CanQuery = false
    instance.Position = pos
    instance.Parent = workspace

    local adornment = Instance.new("SelectionBox")
    adornment.Adornee = instance
    adornment.Parent = instance

    self.debugBoxes[instance] = tick() + 5
    self:AdornText(instance, Vector3.new(0, 6, 0), text, Color3.new(0, 0.501960, 1))
end

function ClientModule.AdornText(self: Self, part: BasePart, offset: Vector3, text: string, color: Color3)
    local attachment = Instance.new("Attachment")
    attachment.Parent = part
    attachment.Position = offset

    local billboard = Instance.new("BillboardGui")
    billboard.AlwaysOnTop = true
    billboard.Size = UDim2.new(0, 50, 0, 20)
    billboard.Adornee = attachment
    billboard.Parent = attachment

    local textLabel = Instance.new("TextLabel")
    textLabel.TextScaled = true
    textLabel.TextColor3 = color
    textLabel.BackgroundTransparency = 1
    textLabel.Size = UDim2.new(1, 0, 1, 0)
    textLabel.Text = text
    textLabel.Parent = billboard
    textLabel.AutoLocalize = false
end

function ClientModule.AddPingToNetgraph(
    self: Self,
    mispredicted: boolean,
    serverHealthFps: number,
    networkProblem: number,
    ping: number
)
    --Ping graph
    local total = 0

    for _, ping in pairs(self.pings) do
        total += ping
    end

    total /= #self.pings
    NetGraph:Scroll()

    local color1 = Color3.new(1, 1, 1)
    local color2 = Color3.new(1, 1, 0)

    if mispredicted == false then
        NetGraph:AddPoint(ping * 0.25, color1, 4)
        NetGraph:AddPoint(total * 0.25, color2, 3)
    else
        NetGraph:AddPoint(ping * 0.25, color1, 4)
        local tint = Color3.new(0.5, 1, 0.5)
        NetGraph:AddPoint(total * 0.25, tint, 3)
        NetGraph:AddBar(10 * 0.25, tint, 1)
    end

    --Server fps
    if serverHealthFps >= 60 then
        NetGraph:AddPoint(serverHealthFps, Color3.new(0.101961, 1, 0), 2)
    elseif serverHealthFps >= 50 then
        NetGraph:AddPoint(serverHealthFps, Color3.new(1, 0.666667, 0), 2)
    else
        NetGraph:AddPoint(serverHealthFps, Color3.new(1, 0, 0), 2)
    end

    --Blue bar
    if networkProblem == Enums.NetworkProblemState.TooFarBehind then
        NetGraph:AddBar(100, Color3.new(0, 0, 1), 0)
    end
    --Yellow bar
    if networkProblem == Enums.NetworkProblemState.TooFarAhead then
        NetGraph:AddBar(100, Color3.new(1, 0.615686, 0), 0)
    end
    --Orange bar
    if networkProblem == Enums.NetworkProblemState.TooManyCommands then
        NetGraph:AddBar(100, Color3.new(1, 0.666667, 0), 0)
    end
    --teal bar
    if networkProblem == Enums.NetworkProblemState.CommandUnderrun then
        NetGraph:AddBar(100, Color3.new(0, 1, 1), 0)
    end

    --Yellow bar
    if networkProblem == Enums.NetworkProblemState.DroppedPacketGood then
        NetGraph:AddBar(100, Color3.new(0.898039, 1, 0), 0)
    end
    --Red Bar
    if networkProblem == Enums.NetworkProblemState.DroppedPacketBad then
        NetGraph:AddBar(100, Color3.new(1, 0, 0), 0)
    end

    NetGraph:SetFpsText("Ping: " .. math.floor(total) .. "ms")
    NetGraph:SetOtherFpsText("ServerFps: " .. serverHealthFps)
end

function ClientModule.IsConnectionBad(self: Self)
    if #self.pings > 10 and self.ping > 2000 then
        return true
    end

    return false
end

function ClientModule.GenerateCommandBase(self: Self, serverTime: number, deltaTime: number)
    local chickynoid = assert(self.localChickynoid)

    local command = {
        deltaTime = deltaTime, -- How much time this command simulated
        serverTime = serverTime, -- For rollback - a locally interpolated value
        snapshotServerFrame = self.snapshotServerFrame, -- Confirm to the server the last snapshot we saw
        playerStateFrame = chickynoid.lastSeenPlayerStateFrame, -- Confirm to server the last playerState we saw

        x = 0,
        y = 0,
        z = 0,

        f = 0,
        j = 0,

        shiftLock = 0,
        localFrame = 0,
        fa = Vector3.zero,
    }

    local modules = ClientMods:GetMods("clientmods")

    for key, mod in modules do
        if mod.GenerateCommand then
            command = mod:GenerateCommand(command, serverTime, deltaTime)
        end
    end

    return command
end

return ClientModule
