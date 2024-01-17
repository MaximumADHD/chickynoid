--!strict
--!native
local CharacterModel = {}
CharacterModel.__index = CharacterModel

CharacterModel.modelPool = {} :: {
    [number]: {
        model: Model,
        modelOffset: Vector3,
    },
}

--[=[
    @class CharacterModel
    @client

    Represents the client side view of a character model
    the local player and all other players get one of these each
    Todo: think about allowing a serverside version of this to exist for perhaps querying rays against?
    
    Consumes a CharacterData 
]=]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local r15Dummy do
    local dummyDesc = Instance.new("HumanoidDescription")
    dummyDesc.HeadColor = BrickColor.Yellow().Color
    dummyDesc.LeftArmColor = BrickColor.Yellow().Color
    dummyDesc.LeftLegColor = Color3.new()
    dummyDesc.RightArmColor = BrickColor.Yellow().Color
    dummyDesc.RightLegColor = Color3.new()
    dummyDesc.TorsoColor = Color3.fromHex("a3a2a5")

    local animate
    r15Dummy = Players:CreateHumanoidModelFromDescription(dummyDesc, Enum.HumanoidRigType.R15)
    animate = r15Dummy:FindFirstChild("Animate")

    if animate and animate:IsA("Script") then
        animate.Enabled = false
    end
end

local path = game.ReplicatedFirst.Packages.Chickynoid
local FastSignal = require(path.Shared.Vendor.FastSignal)
local ClientMods = require(path.Client.ClientMods)
local Animations = require(path.Shared.Simulation.Animations)

local CharacterData = require(path.Shared.Simulation.CharacterData)
type CharacterDataRecord = CharacterData.DataRecord

CharacterModel.template = nil
CharacterModel.characterModelCallbacks = {}

type FastSignal = FastSignal.Class
type Self = typeof(CharacterModel)

export type Class = typeof(setmetatable(
    {} :: {
        model: Model?,
        animator: Animator?,
        primaryPart: BasePart?,

        tracks: {
            [string]: AnimationTrack,
        },

        modelData: {
            model: Model,
            modelOffset: Vector3,
        }?,

        playingTrack: AnimationTrack?,
        playingTrackNum: number?,
        animCounter: number?,
        modelOffset: Vector3?,
        modelReady: boolean?,
        startingAnimation: string?,
        userId: number,
        characterMod: string,
        mispredict: Vector3,
        onModelCreated: FastSignal,
        onModelDestroyed: FastSignal,
        updated: boolean?,
        destroyed: boolean?,
        coroutineStarted: boolean?,
    },
    CharacterModel
))

function CharacterModel.new(userId: number, characterMod: string): Class
    local self = setmetatable({
        model = nil,
        tracks = {},
        animator = nil,
        modelData = nil,
        playingTrack = nil,
        playingTrackNum = nil,
        animCounter = -1,
        modelOffset = Vector3.new(0, 0.5, 0),
        modelReady = false,
        startingAnimation = "Idle",
        userId = userId,
        characterMod = characterMod,
        mispredict = Vector3.zero,
        onModelCreated = FastSignal.new(),
        onModelDestroyed = FastSignal.new(),
        updated = false,
    }, CharacterModel)

    return self
end

function CharacterModel.CreateModel(self: Class)
    self:DestroyModel()

    --print("CreateModel ", self.userId)
    task.spawn(function()
        self.coroutineStarted = true

        if self.modelPool[self.userId] == nil then
            local srcModel: Model?

            -- Download custom character
            for _, characterModelCallback in ipairs(self.characterModelCallbacks) do
                local result: Model? = characterModelCallback(self.userId)
                if result then
                    srcModel = result:Clone()
                end
            end

            --Check the character mod
            if not srcModel then
                if self.characterMod then
                    local loadedModule: any = ClientMods:GetMod("characters", self.characterMod)

                    if loadedModule and loadedModule.GetCharacterModel then
                        local template: Model = loadedModule:GetCharacterModel(self.userId)

                        if template then
                            srcModel = template:Clone()
                        end
                    end
                end
            end

            if srcModel == nil then
                local userId = self.userId
                srcModel = r15Dummy:Clone()

                local player = Players:GetPlayerByUserId(userId)
                local bodyColors = assert(srcModel):FindFirstChildOfClass("BodyColors")
                local humanoid = srcModel:FindFirstChildOfClass("Humanoid")
                local rootPart = srcModel.PrimaryPart

                if bodyColors then
                    bodyColors.TorsoColor3 = Color3.fromHSV((self.userId / 100) % 1, 1, 1)
                end

                if rootPart then
                    rootPart.Anchored = true
                end
                
                if player then
                    srcModel.Name = player.Name
                end

                srcModel.Parent = Lighting
                srcModel:SetAttribute("UserId", userId)
                
                if humanoid then
                    humanoid.EvaluateStateMachine = false

                    if player then
                        if player == Players.LocalPlayer then
                            humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                        end

                        humanoid.DisplayName = player.DisplayName
                    end
                end

                if userId > 0 then
                    for retry = 1, 5 do
                        local success, desc = pcall(function ()
                            return Players:GetHumanoidDescriptionFromUserId(userId)
                        end)

                        if success and humanoid then
                            desc.DepthScale = 1
                            desc.WidthScale = 1
                            desc.HeightScale = 1
                            desc.BodyTypeScale = 0
                            desc.ProportionScale = 0

                            humanoid:ApplyDescription(desc)
                            break
                        else
                            task.wait(retry / 2)
                        end
                    end
                end
            end

            local humanoid = assert(srcModel):FindFirstChildOfClass("Humanoid")
            local rootPart = assert(srcModel.PrimaryPart, "PrimaryPart not set in character model")
            assert(humanoid, "Humanoid not found in character model")

            --setup the hip
            local hip = (rootPart.Size.Y * 0.5) + humanoid.HipHeight

            local modelData = {
                model = srcModel,
                modelOffset = Vector3.new(0, hip - 2.5, 0),
            }

            self.modelData = modelData
            self.modelPool[self.userId] = modelData
        end

        local modelData = assert(self.modelPool[self.userId])
        self.modelData = modelData

        local model = modelData.model:Clone()
        self.primaryPart = model.PrimaryPart
        self.model = model

        local humanoid = model:FindFirstChildOfClass("Humanoid")
        local animator = model:FindFirstChildWhichIsA("Animator", true)

        animator = animator or Instance.new("Animator", humanoid)
        assert(animator)

        self.tracks = {}
        model.Parent = Lighting

        local function onDescendantAdded(desc: Instance)
            if desc:IsA("Animation") then
                local weight = 1
                local parent = desc.Parent

                if parent and parent:IsA("ValueBase") then
                    local name = parent.Name:gsub("^[a-z]", string.upper)
                    local weightRef = desc:FindFirstChild("Weight")
                    local existing = self.tracks[name]

                    if weightRef and weightRef:IsA("NumberValue") then
                        weight = weightRef.Value
                    end

                    if not existing or (existing:GetAttribute("Weight") or 0) < weight then
                        local track = animator:LoadAnimation(desc)
                        track:SetAttribute("Weight", weight)
                        self.tracks[name] = track
                    end
                end
            end
        end

        for i, desc in model:GetDescendants() do
            onDescendantAdded(desc)
        end

        self.modelReady = true
        self:PlayAnimation(self.startingAnimation, true)

        model.Parent = workspace
        model.DescendantAdded:Connect(onDescendantAdded)

        self.onModelCreated:Fire(self.model)
        self.coroutineStarted = false
    end)
end

function CharacterModel.DestroyModel(self: Class)
    self.destroyed = true

    task.spawn(function()
        --The coroutine for loading the appearance might still be running while we've already asked to destroy ourselves
        --We wait for it to finish, then clean up

        while self.coroutineStarted == true do
            wait()
        end

        if self.model == nil then
            return
        end

        self.onModelDestroyed:Fire()
        self.playingTrack = nil
        self.modelData = nil
        self.animator = nil
        self.tracks = {}
        self.model:Destroy()

        if self.modelData and self.modelData.model then
            self.modelData.model:Destroy()
        end

        self.modelData = nil
        self.modelPool[self.userId] = nil
        self.modelReady = false
    end)
end

function CharacterModel.PlayerDisconnected(self: Self, userId: number)
    local modelData = self.modelPool[userId]

    if modelData and modelData.model then
        modelData.model:Destroy()
    end
end

--you shouldnt ever have to call this directly, change the characterData to trigger this
function CharacterModel.PlayAnimation(self: Class, enum: (number | string)?, force: boolean?)
    local name = if type(enum) == "number" then Animations:GetAnimation(enum) else enum or "Idle"

    if self.modelReady == false then
        --Model not instantiated yet
        self.startingAnimation = name
    elseif self.modelData then
        local tracks = self.tracks
        local track = tracks[name]

        if track then
            if self.playingTrack ~= track or force == true then
                for _, value in pairs(tracks) do
                    if value ~= track then
                        value:Stop(0.1)
                    end
                end

                track:Play(0.1)
                self.playingTrack = track
                self.playingTrackNum = Animations:GetAnimationIndex(name)
            end
        end
    end
end

type BulkMoveToList = {
    parts: { BasePart },
    cframes: { CFrame },
}

function CharacterModel.Think(
    self: Class,
    deltaTime: number,
    dataRecord: CharacterDataRecord,
    bulkMoveToList: BulkMoveToList?
)
    local model = self.model
    local modelData = self.modelData
    local playingTrack = self.playingTrack

    if not (model and modelData) then
        return
    end

    --Flag that something has changed
    if self.animCounter ~= dataRecord.animCounter0 then
        self.animCounter = dataRecord.animCounter0
        self:PlayAnimation(dataRecord.animNum0, true)
    end

    if playingTrack then
        if
            self.playingTrackNum == Animations:GetAnimationIndex("Run")
            or self.playingTrackNum == Animations:GetAnimationIndex("Walk")
        then
            local vel = dataRecord.flatSpeed
            local playbackSpeed = (vel / 16) --Todo: Persistant player stats
            playingTrack:AdjustSpeed(playbackSpeed)
        end

        if self.playingTrackNum == Animations:GetAnimationIndex("Push") then
            local vel = 14
            local playbackSpeed = (vel / 16) --Todo: Persistant player stats
            playingTrack:AdjustSpeed(playbackSpeed)
        end
    end

    --[[
	if (self.humanoid == nil) then
		self.humanoid = self.model:FindFirstChild("Humanoid")
	end]]
    --

    --[[
    if (self.humanoid and self.humanoid.Health <= 0) then
        --its dead! Really this should never happen
		self:DestroyModel()
		self:CreateModel(self.userId)
        return
    end]]
    --

    local newCF = CFrame.new(
        dataRecord.pos + modelData.modelOffset + self.mispredict + Vector3.new(0, dataRecord.stepUp, 0)
    ) * CFrame.fromEulerAnglesXYZ(0, dataRecord.angle, 0)

    if bulkMoveToList and self.primaryPart then
        table.insert(bulkMoveToList.parts, self.primaryPart)
        table.insert(bulkMoveToList.cframes, newCF)
    else
        model:PivotTo(newCF)
    end
end

function CharacterModel:SetCharacterModel(callback: (userId: number) -> Model?)
    table.insert(self.characterModelCallbacks, callback)
end

return CharacterModel
