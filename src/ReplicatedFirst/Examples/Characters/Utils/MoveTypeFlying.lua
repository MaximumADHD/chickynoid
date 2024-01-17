local module = {}

local path = game.ReplicatedFirst.Packages.Chickynoid
local MathUtils = require(path.Shared.Simulation.MathUtils)
local Enums = require(path.Shared.Enums)

local Simulation = require(path.Shared.Simulation.Simulation)
local CommandLayout = require(path.Shared.Simulation.CommandLayout)

type Simulation = Simulation.Class
type Command = CommandLayout.Command

--Call this on both the client and server!
function module:ModifySimulation(simulation: Simulation)
    simulation:RegisterMoveState({
        name = "Flying",
        updateState = self.ActiveThink,
        alwaysThink = self.AlwaysThink,
        startState = self.StartState,
    })

    simulation.constants.flyFriction = 0.2
    simulation.state.flyingCooldown = 0
end

-- Imagine this is inside Simulation...
function module.AlwaysThink(simulation: Simulation, cmd: Command)
    if simulation.state.flyingCooldown > 0 then
        simulation.state.flyingCooldown = math.max(simulation.state.flyingCooldown - cmd.deltaTime, 0)
    end

    if simulation.state.flyingCooldown == 0 and cmd.flying == 1 then
        if simulation:GetMoveState().name == "Flying" then
            simulation.state.flyingCooldown = 0.5
            simulation:SetMoveState("Walking")
        else
            simulation.state.flyingCooldown = 0.5
            simulation:SetMoveState("Flying")
        end
    end
end

function module.StartState(simulation: Simulation, cmd: Command)
    --pop us up when we enter this state
    simulation.state.vel = Vector3.new(0, 100, 0)
end

--Imagine this is inside Simulation...
function module.ActiveThink(simulation: Simulation, cmd: Command)
    --Did the player have a movement request?
    local wishDir = nil

    if cmd.x ~= 0 or cmd.y ~= 0 or cmd.z ~= 0 then
        wishDir = Vector3.new(cmd.x, cmd.y, cmd.z).Unit
        simulation.state.pushDir = Vector2.new(cmd.x, cmd.z)
    else
        simulation.state.pushDir = Vector2.new(0, 0)
    end

    --Does the player have an input?
    if wishDir ~= nil then
        simulation.state.vel = MathUtils:GroundAccelerate(
            wishDir,
            simulation.constants.maxSpeed,
            simulation.constants.accel,
            simulation.state.vel,
            cmd.deltaTime
        )

        simulation.characterData:PlayAnimation("Run", Enums.AnimChannel.Channel0, false)
    else
        simulation.characterData:PlayAnimation("Idle", Enums.AnimChannel.Channel0, false)
    end

    simulation.state.vel =
        MathUtils:VelocityFriction(simulation.state.vel, simulation.constants.flyFriction, cmd.deltaTime)

    local walkNewPos, walkNewVel = simulation:ProjectVelocity(simulation.state.pos, simulation.state.vel, cmd.deltaTime)
    simulation.state.pos = walkNewPos
    simulation.state.vel = walkNewVel

    --Do angles
    if wishDir ~= nil then
        simulation.state.targetAngle = MathUtils:PlayerVecToAngle(wishDir)
        simulation.state.angle = MathUtils:LerpAngle(
            simulation.state.angle,
            simulation.state.targetAngle,
            simulation.constants.turnSpeedFrac * cmd.deltaTime
        )
    end
end

return module
