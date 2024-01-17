--!strict

local module = {}
local active = false

type Record = {
    averages: { number },
    average: number,
    currentSample: number,
    startTime: number,
}

module.tagStack = {} :: { string }

module.tags = {} :: {
    [string]: Record,
}

type Self = typeof(module)

function module.BeginSample(self: Self, name: string)
    local rec = self.tags[name]

    if rec == nil then
        rec = {
            averages = {},
            average = 0,
            currentSample = 0,
            startTime = 0,
        }

        self.tags[name] = rec
    end

    rec.startTime = tick()
    table.insert(module.tagStack, name)
end

function module.EndSample(self: Self)
    if #module.tagStack == 0 then
        warn("Profile tagstack already empty")
        return
    end

    local rec = module.tags[module.tagStack[#module.tagStack]]
    table.remove(module.tagStack, #module.tagStack)
    rec.currentSample = tick() - rec.startTime

    table.insert(rec.averages, rec.currentSample)

    if #rec.averages > 10 then
        table.remove(rec.averages, 1)
    end
end

function module.Print(self: Self, name: string)
    local rec = module.tags[name]

    if rec == nil then
        warn("Unknown tag", name)
        return
    end

    local average = 0
    local counter = 0

    for key, value in rec.averages do
        average += value
        counter += 1
    end

    average /= counter
    print(
        name,
        string.format("%.3f", rec.currentSample * 1000) .. "ms avg:",
        string.format("%.3f", average * 1000) .. "ms"
    )
end

if active then
    local RunService = game:GetService("RunService")
    local nextTick = tick() + 1

    RunService.Heartbeat:Connect(function()
        if tick() > nextTick then
            nextTick = tick() + 1

            for key in module.tags do
                module:Print(key)
            end
        end
    end)
end

return module
