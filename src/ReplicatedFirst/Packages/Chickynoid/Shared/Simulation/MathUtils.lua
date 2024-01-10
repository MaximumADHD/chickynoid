--!native
--!strict

local MathUtils = {}
local THETA = math.pi * 2

type MathUtils = typeof(MathUtils)

function MathUtils.AngleAbs(self: MathUtils, angle: number)
    while angle < 0 do
        angle = angle + THETA
    end
    while angle > THETA do
        angle = angle - THETA
    end
    return angle
end

function MathUtils.AngleShortest(self: MathUtils, a0: number, a1: number)
    local d1 = self:AngleAbs(a1 - a0)
    local d2 = -self:AngleAbs(a0 - a1)
    return math.abs(d1) > math.abs(d2) and d2 or d1
end

function MathUtils.LerpAngle(self: MathUtils, a0: number, a1: number, frac: number)
    return a0 + self:AngleShortest(a0, a1) * frac
end

function MathUtils.PlayerVecToAngle(self: MathUtils, vec: Vector3)
    return math.atan2(-vec.Z, vec.X) - math.rad(90)
end

function MathUtils.PlayerAngleToVec(self: MathUtils, angle: number)
    return Vector3.new(math.sin(angle), 0, math.cos(angle))
end

--dt variable decay function
function MathUtils.Friction(self: MathUtils, val: number, fric: number, deltaTime: number)
    return (1 / (1 + (deltaTime / fric))) * val
end

function MathUtils.VelocityFriction(self: MathUtils, vel: Vector3, fric: number, deltaTime: number)
    local speed = vel.Magnitude
    speed = self:Friction(speed, fric, deltaTime)

    if speed < 0.001 then
        return Vector3.zero
    end

    return vel.Unit * speed
end

function MathUtils.FlatVec(self: MathUtils, vec: Vector3)
    return Vector3.new(vec.X, 0, vec.Z)
end

--Redirects velocity
function MathUtils.GroundAccelerate(self: MathUtils, wishDir: Vector3, wishSpeed: number, accel: number, velocity: Vector3, dt: number)
    --Cap velocity
    local speed = velocity.Magnitude

    if speed > wishSpeed then
        velocity = velocity.Unit * wishSpeed
    end

    local wishVel = wishDir * wishSpeed
    local pushDir = wishVel - velocity

    local pushLen = pushDir.Magnitude
    local canPush = accel * dt * wishSpeed

    if canPush > pushLen then
        canPush = pushLen
    end

    if canPush < 0.00001 then
        return velocity
    end

    return velocity + (canPush * pushDir.Unit)
end

function MathUtils.Accelerate(self: MathUtils, wishDir: Vector3, wishSpeed: number, accel: number, velocity: Vector3, dt: number)
    local speed = velocity.Magnitude

    local currentSpeed = velocity:Dot(wishDir)
    local addSpeed = wishSpeed - currentSpeed

    if addSpeed <= 0 then
        return velocity
    end

    local accelSpeed = accel * dt * wishSpeed

    if accelSpeed > addSpeed then
        accelSpeed = addSpeed
    end

    velocity += (accelSpeed * wishDir)

    --if we're already going over max speed, don't go any faster than that
    --Or you'll get strafe jumping!

    if speed > wishSpeed and velocity.Magnitude > speed then
        velocity = velocity.Unit * speed
    end

    return velocity
end

function MathUtils.CapVelocity(self: MathUtils, velocity: Vector3, maxSpeed: number)
    local mag = velocity.Magnitude
    mag = math.min(mag, maxSpeed)

    if mag > 0.01 then
        return velocity.Unit * mag
    end

    return Vector3.zero
end


function MathUtils.ClipVelocity(self: MathUtils, input: Vector3, normal: Vector3, overbounce: number)
    local backoff = input:Dot(normal)

    if backoff < 0 then
        backoff *= overbounce
    else
        backoff /= overbounce
    end

    return input - (normal * backoff)
end

--Smoothlerp for lua. "Zeno would be proud!"
--Use it in a feedback loop over multiple frames to converge A towards B, in a deltaTime safe way
--eg:  cameraPos = SmoothLerp(cameraPos, target, 0.5, deltaTime)
--Handles numbers and types that implement Lerp like Vector3 and CFrame

function MathUtils.SmoothLerp(self: MathUtils, variableA: any, variableB: any, fraction: number, deltaTime: number)
    local f = 1.0 - math.pow(1.0 - fraction, deltaTime)

    if (type(variableA) == "number") then
        return ((1-f) * variableA) + (variableB * f)
    end

    return variableA:Lerp(variableB, f)
end

return MathUtils