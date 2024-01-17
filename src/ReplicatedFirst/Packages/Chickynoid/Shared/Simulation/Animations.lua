--!strict

local module = {}
module.animations = {} --num, string
module.reverseLookups = {} --string, num

type Self = typeof(module)

function module.RegisterAnimation(self: Self, name: string)
    if self.reverseLookups[name] ~= nil then
        return self.reverseLookups[name]
    end

    table.insert(self.animations, name)
    local index = #self.animations

    module.reverseLookups[name] = index
    return index
end

function module.GetAnimationIndex(self: Self, name: string): number
    return self.reverseLookups[name]
end

function module.GetAnimation(self: Self, index: number): string
    return self.animations[index]
end

function module.SetAnimationsFromWorldState(self: Self, animations: { string })
    self.animations = animations
    self.reverseLookups = {}

    for key, value in self.animations do
        self.reverseLookups[value] = key
    end
end

function module.ServerSetup(self: Self)
    --Register some default animations
    self:RegisterAnimation("Stop")
    self:RegisterAnimation("Idle")
    self:RegisterAnimation("Walk")
    self:RegisterAnimation("Run")
    self:RegisterAnimation("Push")
    self:RegisterAnimation("Jump")
    self:RegisterAnimation("Fall")
end

return module
