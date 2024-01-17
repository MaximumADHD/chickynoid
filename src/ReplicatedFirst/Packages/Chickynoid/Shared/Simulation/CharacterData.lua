--!native
--!strict

local CharacterData = {}
CharacterData.__index = CharacterData

export type DataRecord = {
    pos: Vector3,
    angle: number,
    stepUp: number,
    flatSpeed: number,
    exclusiveAnimTime: number,

    animCounter0: number,
    animNum0: number,

    animCounter1: number,
    animNum1: number,

    animCounter2: number,
    animNum2: number,

    animCounter3: number,
    animNum3: number,
}

export type Class = typeof(setmetatable(
    {} :: {
        serialized: DataRecord,
        isResimulating: boolean,
        targetPosition: Vector3,
    },
    CharacterData
))

type Self = typeof(CharacterData)

local EPSILION = 0.00001
local MAX_FLOAT16 = 0x10000
local MAX_BYTE = 0xFF

local Animations = require(script.Parent.Animations)
local mathUtils = require(script.Parent.MathUtils)

local function Lerp(a: any, b: any, frac: number)
    return a:Lerp(b, frac)
end

local function AngleLerp(a, b, frac)
    return mathUtils:LerpAngle(a, b, frac)
end

local function NumberLerp(a: number, b: number, frac: number)
    return (a * (1 - frac)) + (b * frac)
end

local function Raw(_a: number, b: number, _frac: number)
    return b
end


local function ValidateFloat16(float: number)
    return math.clamp(float, -MAX_FLOAT16, MAX_FLOAT16)
end

local function ValidateByte(byte: number)
    return math.clamp(byte, 0, MAX_BYTE)
end

local function ValidateVector3(input: Vector3)
    return input
end

local function ValidateNumber(input: number)
    return input
end

local function CompareVector3(a: Vector3, b: Vector3)
    return a:FuzzyEq(b, EPSILION)
end

local function CompareNumber(a: number, b: number)
    return a == b
end

local function WriteVector3(buf: buffer, offset: number, value: Vector3): number
    buffer.writef32(buf, offset, value.X)
    buffer.writef32(buf, offset + 4, value.Y)
    buffer.writef32(buf, offset + 8, value.Z)
    return offset + 12
end

local function ReadVector3(buf: buffer, offset: number)
    local x = buffer.readf32(buf, offset)
    local y = buffer.readf32(buf, offset + 4)
    local z = buffer.readf32(buf, offset + 8)
    return Vector3.new(x, y, z), offset + 12
end

local function WriteFloat32(buf: buffer, offset: number, value: number): number
    buffer.writef32(buf, offset, value)
    return offset + 4
end

local function ReadFloat32(buf: buffer, offset: number)
    local x = buffer.readf32(buf, offset)
    return x, offset + 4
end

local function WriteByte(buf: buffer, offset: number, value: number): number
    buffer.writeu8(buf, offset, value)
    return offset + 1
end

local function ReadByte(buf: buffer, offset: number)
    local x = buffer.readu8(buf, offset)
    return x, offset + 1
end

local function WriteFloat16(buf: buffer, offset: number, value: number): number
    local sign = value < 0
    value = math.abs(value)

    local mantissa, exponent = math.frexp(value)

    if value == math.huge then
        if sign then
            buffer.writeu8(buf, offset, 0b_11111100)
        else
            buffer.writeu8(buf, offset, 0b_01111100)
        end

        buffer.writeu8(buf, offset + 1, 0b_00000000)
        return offset + 2
    elseif value ~= value or value == 0 then
        buffer.writeu16(buf, offset, 0)
        return offset + 2
    elseif exponent + 15 <= 1 then -- Bias for halfs is 15
        mantissa = math.floor(mantissa * 1024 + 0.5)

        if sign then
            buffer.writeu8(buf, offset, (128 + bit32.rshift(mantissa, 8))) -- Sign bit, 5 empty bits, 2 from mantissa
        else
            buffer.writeu8(buf, offset, (bit32.rshift(mantissa, 8)))
        end

        buffer.writeu8(buf, offset + 1, bit32.band(mantissa, 255)) -- Get last 8 bits from mantissa
        return offset + 2
    end

    mantissa = ((mantissa - 0.5) * 2048 + 0.5) // 1

    -- The bias for halfs is 15, 15-1 is 14
    if sign then
        buffer.writeu8(buf, offset, (128 + bit32.lshift(exponent + 14, 2) + bit32.rshift(mantissa, 8)))
    else
        buffer.writeu8(buf, offset, (bit32.lshift(exponent + 14, 2) + bit32.rshift(mantissa, 8)))
    end

    buffer.writeu8(buf, offset + 1, bit32.band(mantissa, 255))
    return offset + 2
end

local function ReadFloat16(buf: buffer, offset: number)
    local b0 = buffer.readu8(buf, offset)
    local b1 = buffer.readu8(buf, offset + 1)

    local sign = bit32.btest(b0, 128)
    local exponent = bit32.rshift(bit32.band(b0, 127), 2)
    local mantissa = bit32.lshift(bit32.band(b0, 3), 8) + b1

    if exponent == 31 then --2^5-1
        if mantissa ~= 0 then
            return (0 / 0), offset + 2
        else
            return (sign and -math.huge or math.huge), offset + 2
        end
    elseif exponent == 0 then
        if mantissa == 0 then
            return 0, offset + 2
        else
            return (sign and -math.ldexp(mantissa / 1024, -14) or math.ldexp(mantissa / 1024, -14)), offset + 2
        end
    end

    mantissa = (mantissa / 1024) + 1
    return (sign and -math.ldexp(mantissa, exponent - 15) or math.ldexp(mantissa, exponent - 15)), offset + 2
end

function CharacterData.SetIsResimulating(self: Class, bool: boolean)
    self.isResimulating = bool
end

function CharacterData.ModuleSetup(self: Self)
    self.methods = {}

    self.methods["Vector3"] = {
        write = WriteVector3,
        read = ReadVector3,
        validate = ValidateVector3,
        compare = CompareVector3,
    }

    self.methods["Float16"] = {
        write = WriteFloat16,
        read = ReadFloat16,
        validate = ValidateFloat16,
        compare = CompareNumber,
    }

    self.methods["Float32"] = {
        write = WriteFloat32,
        read = ReadFloat32,
        validate = ValidateNumber,
        compare = CompareNumber,
    }

    self.methods["Byte"] = {
        write = WriteByte,
        read = ReadByte,
        validate = ValidateByte,
        compare = CompareNumber,
    }

    self.packFunctions = {
        pos = "Vector3",
        angle = "Float16",
        stepUp = "Float16",
        flatSpeed = "Float16",
        exclusiveAnimTime = "Float32",
        animCounter0 = "Byte",
        animNum0 = "Byte",
        animCounter1 = "Byte",
        animNum1 = "Byte",
        animCounter2 = "Byte",
        animNum2 = "Byte",
        animCounter3 = "Byte",
        animNum3 = "Byte",
    }

    self.keys = {
        "pos",
        "angle",
        "stepUp",
        "flatSpeed",
        "exclusiveAnimTime",
        "animCounter0",
        "animNum0",
        "animCounter1",
        "animNum1",
        "animCounter2",
        "animNum2",
        "animCounter3",
        "animNum3",
    }

    self.lerpFunctions = {
        pos = Lerp,
        angle = AngleLerp,
        stepUp = NumberLerp,
        flatSpeed = NumberLerp,
        exclusiveAnimTime = Raw,

        animCounter0 = Raw,
        animNum0 = Raw,
        animCounter1 = Raw,
        animNum1 = Raw,
        animCounter2 = Raw,
        animNum2 = Raw,
        animCounter3 = Raw,
        animNum3 = Raw,
    }

    --This isn't serialized, instead the characterMod field is used to run the same modifications on client and server
    self.animationNames = {}
    self.animationIndices = {}

    self:RegisterAnimationName("Idle")
    self:RegisterAnimationName("Walk")
    self:RegisterAnimationName("Run")
    self:RegisterAnimationName("Jump")
    self:RegisterAnimationName("Fall")
    self:RegisterAnimationName("Push")
end

function CharacterData.new(): Class
    local self = setmetatable({
        serialized = {
            pos = Vector3.zero,
            angle = 0,
            stepUp = 0,
            flatSpeed = 0,
            exclusiveAnimTime = 0,

            animCounter0 = 0,
            animNum0 = 0,
            animCounter1 = 0,
            animNum1 = 0,
            animCounter2 = 0,
            animNum2 = 0,
            animCounter3 = 0,
            animNum3 = 0,
        },

        --Be extremely careful about having any kind of persistant nonserialized data!
        --If in doubt, stick it in the serialized!
        isResimulating = false,
        targetPosition = Vector3.zero,
    }, CharacterData)

    return self
end

--This smoothing is performed on the server only.
--On client, use GetPosition
function CharacterData.SmoothPosition(self: Class, deltaTime, smoothScale)
    if smoothScale == 1 or smoothScale == 0 then
        self.serialized.pos = self.targetPosition
    else
        self.serialized.pos = mathUtils:SmoothLerp(self.serialized.pos, self.targetPosition, smoothScale, deltaTime)
    end
end

function CharacterData.ClearSmoothing(self: Class)
    self.serialized.pos = self.targetPosition
end

--Sets the target position
function CharacterData.SetTargetPosition(self: Class, pos: Vector3, teleport: boolean?)
    self.targetPosition = pos

    if teleport then
        self:ClearSmoothing()
    end
end

function CharacterData.GetPosition(self: Class)
    return self.serialized.pos
end

function CharacterData.SetFlatSpeed(self: Class, num)
    self.serialized.flatSpeed = num
end

function CharacterData.SetAngle(self: Class, angle)
    self.serialized.angle = angle
end

function CharacterData.GetAngle(self: Class)
    return self.serialized.angle
end

function CharacterData.SetStepUp(self: Class, amount)
    self.serialized.stepUp = amount
end

function CharacterData.PlayAnimation(
    self: Class,
    animName: string,
    animChannel: number,
    forceRestart: boolean?,
    exclusiveTime: number?
)
    local animIndex = Animations:GetAnimationIndex(animName)

    if animIndex == nil then
        animIndex = 1
    end

    self:PlayAnimationIndex(animIndex, animChannel, forceRestart, exclusiveTime)
end

function CharacterData.PlayAnimationIndex(
    self: Class,
    animNum: number,
    animChannel: number,
    forceRestart: boolean?,
    exclusiveTime: number?
)
    --Dont change animations during resim
    if self.isResimulating == true then
        return
    end

    if animChannel < 0 or animChannel > 3 then
        return
    end

    --If we're in an exclusive window of having an animation play, ignore this request
    if tick() < self.serialized.exclusiveAnimTime and forceRestart == false then
        return
    end

    if exclusiveTime ~= nil and exclusiveTime > 0 then
        self.serialized.exclusiveAnimTime = tick() + exclusiveTime
    end

    local counterString = "animCounter" .. animChannel
    local slotString = "animNum" .. animChannel

    --Restart this anim, or its a different anim than we're currently playing
    if forceRestart == true or self.serialized[slotString] ~= animNum then
        self.serialized[counterString] += 1

        if self.serialized[counterString] > 255 then
            self.serialized[counterString] = 0
        end
    end

    self.serialized[slotString] = animNum
end

local function internalSetAnim(self: Class, animChannel: number, animNum: number)
    local counterString = "animCounter" .. animChannel
    local slotString = "animNum" .. animChannel
    self.serialized[counterString] += 1

    if self.serialized[counterString] > 255 then
        self.serialized[counterString] = 0
    end

    self.serialized[slotString] = 0
end

function CharacterData.StopAnimation(self: Class, animChannel: number)
    internalSetAnim(self, animChannel, 0)
end

function CharacterData.StopAllAnimation(self: Class)
    self.serialized.exclusiveAnimTime = 0

    for i = 0, 3 do
        internalSetAnim(self, i, 0)
    end
end

function CharacterData.Serialize(self: Class)
    local ret = {}
    --Todo: Add bitpacking

    for key: string in pairs(self.serialized) do
        ret[key] = self.serialized[key]
    end

    return ret
end

function CharacterData.SerializeToBitBuffer(self: Class, previousData, buf: buffer, offset: number)
    if previousData == nil then
        return self:SerializeToBitBufferFast(buf, offset)
    end

    local contentWritePos = offset
    offset += 2 --2 bytes contents

    local contentBits = 0
    local bitIndex = 0

    if previousData == nil then
        --Slow path that wont be hit
        contentBits = 0xFFFF

        for keyIndex, key in CharacterData.keys do
            local value = self.serialized[key]
            local func = CharacterData.methods[CharacterData.packFunctions[key]]
            offset = func.write(buf, offset, value)
        end
    else
        --calculate bits
        for keyIndex, key in CharacterData.keys do
            local value = self.serialized[key]
            local func = CharacterData.methods[CharacterData.packFunctions[key]]

            local valueA = previousData.serialized[key]
            local valueB = value

            if func.compare(valueA, valueB) == false then
                contentBits = bit32.bor(contentBits, bit32.lshift(1, bitIndex))
                offset = func.write(buf, offset, value)
            end
            bitIndex += 1
        end
    end

    buffer.writeu16(buf, contentWritePos, contentBits)
    return offset
end

function CharacterData.SerializeToBitBufferFast(self: Class, buf: buffer, offset: number)
    local contentWritePos = offset
    offset += 2 --2 bytes contents

    local contentBits = 0xFFFF
    local serialized = self.serialized

    offset = WriteVector3(buf, offset, serialized.pos)
    offset = WriteFloat16(buf, offset, serialized.angle)
    offset = WriteFloat16(buf, offset, serialized.stepUp)
    offset = WriteFloat16(buf, offset, serialized.flatSpeed)
    offset = WriteFloat32(buf, offset, serialized.exclusiveAnimTime)
    offset = WriteByte(buf, offset, serialized.animCounter0)
    offset = WriteByte(buf, offset, serialized.animNum0)
    offset = WriteByte(buf, offset, serialized.animCounter1)
    offset = WriteByte(buf, offset, serialized.animNum1)
    offset = WriteByte(buf, offset, serialized.animCounter2)
    offset = WriteByte(buf, offset, serialized.animNum2)
    offset = WriteByte(buf, offset, serialized.animCounter3)
    offset = WriteByte(buf, offset, serialized.animNum3)

    buffer.writeu16(buf, contentWritePos, contentBits)
    return offset
end

function CharacterData.DeserializeFromBitBuffer(self: Class, buf: buffer, offset: number)
    local contentBits = buffer.readu16(buf, offset)
    offset += 2

    local bitIndex = 0

    for keyIndex, key in CharacterData.keys do
        local hasBit = bit32.band(contentBits, bit32.lshift(1, bitIndex)) > 0

        if hasBit then
            local func = CharacterData.methods[CharacterData.packFunctions[key]]
            self.serialized[key], offset = func.read(buf, offset)
        end

        bitIndex += 1
    end

    return offset
end

function CharacterData.CopySerialized(self: Class, otherSerialized: { [string]: any })
    for key, value in pairs(otherSerialized) do
        self.serialized[key] = value
    end
end

function CharacterData.Interpolate(self: Self, dataA, dataB, fraction: number)
    local dataRecord = {}

    for key: string in pairs(dataA) do
        local func: ((a: any, b: any, frac: number) -> number)? = CharacterData.lerpFunctions[key]

        if func == nil then
            dataRecord[key] = dataB[key]
        else
            dataRecord[key] = func(dataA[key], dataB[key], fraction)
        end
    end

    return dataRecord
end

function CharacterData.AnimationNameToAnimationIndex(self: Class, name: string): number
    return self.animationNames[name]
end

function CharacterData.AnimationIndexToAnimationName(self: Class, index: number): string
    return self.animationIndices[index]
end

function CharacterData.RegisterAnimationName(self: Self, name: string)
    table.insert(self.animationIndices, name)
    local index = #self.animationIndices

    if index > 255 then
        error("Too many animations registered, you'll need to use a int16")
    end

    self.animationNames[name] = index
end

function CharacterData.ClearAnimationNames(self: Self)
    table.clear(self.animationNames)
    table.clear(self.animationIndices)
end

CharacterData:ModuleSetup()
return CharacterData
