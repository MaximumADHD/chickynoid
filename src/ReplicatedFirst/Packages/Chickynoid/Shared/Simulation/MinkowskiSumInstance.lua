--!native
--!strict

local Root = script.Parent.Parent
local Vendor = Root.Vendor

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local TrianglePart = require(Vendor.TrianglePart)
local QuickHull2 = require(Vendor.QuickHull2)

local module = {}
module.timeSpentTracing = 0

module.meshCache = {} :: {
    [string]: { Vector3 },
}

type Self = typeof(module)

local corners = {
    Vector3.new(0.5, 0.5, 0.5),
    Vector3.new(0.5, 0.5, -0.5),
    Vector3.new(-0.5, 0.5, 0.5),
    Vector3.new(-0.5, 0.5, -0.5),
    Vector3.new(0.5, -0.5, 0.5),
    Vector3.new(0.5, -0.5, -0.5),
    Vector3.new(-0.5, -0.5, 0.5),
    Vector3.new(-0.5, -0.5, -0.5),
}

local wedge = {
    Vector3.new(0.5, -0.5, -0.5),
    Vector3.new(-0.5, -0.5, -0.5),
    Vector3.new(0.5, -0.5, 0.5),
    Vector3.new(-0.5, -0.5, 0.5),
    Vector3.new(0.5, 0.5, 0.5),
    Vector3.new(-0.5, 0.5, 0.5),
}

local cornerWedge = {
    Vector3.new(0.5, 0.5, -0.5),
    Vector3.new(0.5, -0.5, 0.5),
    Vector3.new(-0.5, -0.5, 0.5),
    Vector3.new(0.5, -0.5, -0.5),
    Vector3.new(-0.5, -0.5, -0.5),
}

export type HullRecord = {
    n: Vector3,
    ed: number,
    tri: { Vector3 }?,
    planeNum: number,
}

export type PlaneRecord = {
    [number]: Vector3,
    ed: number,
}

local function IsUnique(list: { HullRecord }, normal: Vector3, d: number)
    local EPS = 0.01
    local normalTol = 0.95

    for _, rec in pairs(list) do
        if math.abs(rec.ed - d) < EPS and rec.n:Dot(normal) > normalTol then
            return false
        end
    end

    return true
end

local function IsUniquePoint(list: { Vector3 }, point: Vector3)
    local EPS = 0.001

    for _, src in pairs(list) do
        if (src - point).Magnitude < EPS then
            return false
        end
    end

    return true
end

local function IsUniqueTri(list: { PlaneRecord }, normal: Vector3, d: number)
    local EPS = 0.001

    for _, rec in pairs(list) do
        if math.abs(rec.ed - d) > EPS then
            continue
        end
        if rec[4]:Dot(normal) < 1 - EPS then
            continue
        end
        return false --got a match
    end

    return true
end

-- local function IsUniquePoints(list, p)
--     local EPS = 0.001

--     for _, point in pairs(list) do
--         if (point - p).magnitude < EPS then
--             return false
--         end
--     end
--     return true
-- end

-- TODO: Remove if no longer needed.
local function _IsValidTri(tri: { Vector3 }, origin: Vector3)
    local normal = (tri[1] - tri[2]):Cross(tri[1] - tri[3]).Unit
    local pos = (tri[1] + tri[2] + tri[3]) / 3
    local vec = (pos - origin).Unit

    if vec:Dot(normal) > 0.75 then
        return true
    end
    return false
end

--Generates a very accurate minkowski summed convex hull from an instance and player box size
--Forces you to pass in the part cframe manually, because we need to snap it for client/server precision reasons
--Not a speedy thing to do!
function module.GetPlanesForInstance(
    self: Self,
    instance: Instance,
    playerSize: Vector3,
    cframe: CFrame,
    basePlaneNum: number,
    showDebugParentPart: BasePart?
)
    if instance:IsA("MeshPart") and instance.Anchored then
        if
            instance.CollisionFidelity == Enum.CollisionFidelity.Hull
            or instance.CollisionFidelity == Enum.CollisionFidelity.PreciseConvexDecomposition
        then
            return module:GetPlanesForInstanceMeshPart(instance, playerSize, cframe, basePlaneNum, showDebugParentPart)
        end
    end

    --generate worldspace points
    local points = self:GeneratePointsForInstance(instance, playerSize, cframe)
    if showDebugParentPart ~= nil then
        self:VisualizePlanesForPoints(points, showDebugParentPart)
    end

    return self:GetPlanesForPoints(points, basePlaneNum)
end

function module.GetPlanesForPointsExpanded(
    self: Self,
    points: { Vector3 },
    playerSize: Vector3,
    basePlaneNum: number,
    debugPart: BasePart?
)
    local newPoints = {}
    for _, point in pairs(points) do
        for _, v in pairs(corners) do
            table.insert(newPoints, point + (v * playerSize))
        end
    end

    if debugPart ~= nil then
        self:VisualizePlanesForPoints(newPoints, debugPart)
    end

    return self:GetPlanesForPoints(newPoints, basePlaneNum)
end

--Same thing but for worldspace point cloud
function module.VisualizePlanesForPoints(self: Self, points: { Vector3 }, debugPart: BasePart?)
    --Run quickhull

    local r = QuickHull2.GenerateHull(points)

    if r then
        self:VisualizeTriangles(r, Vector3.zero)
    end
end

function module.VisualizeTriangles(self: Self, tris: { { Vector3 } }, offset: Vector3)
    local color = Color3.fromHSV(math.random(), 0.5, 1)

    --Add triangles
    for _, tri in pairs(tris) do
        local a, b = TrianglePart:Triangle(tri[1] + offset, tri[2] + offset, tri[3] + offset)
        a.Parent = workspace.Terrain
        a.Color = color
        b.Parent = workspace.Terrain
        b.Color = color

        --Add a normal
        local normal = (tri[1] - tri[2]):Cross(tri[1] - tri[3]).Unit
        local pos = (tri[1] + tri[2] + tri[3]) / 3
        local instance = Instance.new("Part")
        instance.Size = Vector3.new(0.1, 0.1, 2)
        instance.CFrame = CFrame.lookAt(pos + normal, pos + (normal * 2))
        instance.Parent = workspace.Terrain
        instance.CanCollide = false
        instance.Anchored = true
    end
end

--Same thing but for worldspace point cloud
function module.GetPlanesForPoints(self: Self, points: { Vector3 }, basePlaneNum: number)
    --Run quickhull
    local r = QuickHull2.GenerateHull(points)
    local recs = {}

    --Generate unique planes in n+d format
    if r ~= nil then
        for _, tri in pairs(r) do
            local normal = (tri[1] - tri[2]):Cross(tri[1] - tri[3]).Unit
            local ed = tri[1]:Dot(normal) --expanded distance
            basePlaneNum += 1

            if IsUnique(recs, normal, ed) then
                table.insert(recs, {
                    n = normal,
                    ed = ed, --expanded
                    planeNum = basePlaneNum,
                })
            end
        end
    end

    return recs, basePlaneNum
end

--Same thing but for worldspace point cloud

function module.GetPlanePointForPoints(self: Self, points: { Vector3 }): { PlaneRecord }
    --Run quickhull
    local r = QuickHull2.GenerateHull(points)
    local recs = {}

    --Generate unique planes in n+d format
    if r ~= nil then
        for _, tri in pairs(r) do
            local normal = (tri[1] - tri[2]):Cross(tri[1] - tri[3]).Unit
            local ed = tri[1]:Dot(normal) --expanded distance

            if IsUniqueTri(recs, normal, ed) then
                local rec = { tri[1], tri[2], tri[3], normal, ed = ed }
                table.insert(recs, rec)
            end
        end
    end

    return recs
end

function module.PointInsideHull(self: Self, hullRecord: { HullRecord }, point: Vector3)
    for _, p in pairs(hullRecord) do
        local dist = point:Dot(p.n) - p.ed

        if dist > 0 then
            return true
        end
    end

    return false
end

function module.GeneratePointsForInstance(self: Self, instance: Instance, playerSize: Vector3, cframe: CFrame)
    local points = {}

    if instance:IsA("BasePart") then
        local srcPoints = corners

        if instance:IsA("Part") then
            srcPoints = corners
        elseif instance:IsA("WedgePart") then
            srcPoints = wedge
        elseif instance:IsA("CornerWedgePart") then
            srcPoints = cornerWedge
        end

        for _, v in pairs(srcPoints) do
            local part_corner = cframe * CFrame.new(v * instance.Size)

            for _, c in pairs(corners) do
                table.insert(points, (part_corner + c * playerSize).Position)
            end
        end
    end

    return points
end

--As they say - if it's stupid and it works...
--So the idea here is we scale a mesh down to 1,1,1
--Fire a grid of rays at it
--And return this array of points to build a convex hull out of
function module.GetRaytraceInstancePoints(self: Self, instance: MeshPart, cframe: CFrame)
    local start = tick()
    local points = self.meshCache[instance.MeshId]

    if points == nil then
        print("Raytracing ", instance.Name, instance.MeshId)
        points = {}
        local step = 0.2

        local function AddUnique(list: { Vector3 }, point: Vector3)
            for key, value in pairs(list) do
                if (value - point).Magnitude < 0.1 then
                    return
                end
            end
            table.insert(list, point)
        end

        local meshCopy = instance:Clone()
        meshCopy.CFrame = CFrame.identity
        meshCopy.Size = Vector3.one
        meshCopy.Parent = workspace
        meshCopy.CanQuery = true

        local raycastParam = RaycastParams.new()
        raycastParam.FilterType = Enum.RaycastFilterType.Include
        raycastParam.FilterDescendantsInstances = { meshCopy }

        for x = -0.5, 0.5, step do
            for y = -0.5, 0.5, step do
                local pos = Vector3.new(x, -2, y)
                local dir = Vector3.new(0, 4, 0)
                local result = workspace:Raycast(pos, dir, raycastParam)
                if result then
                    AddUnique(points, result.Position)

                    --we hit something, trace from the other side too
                    pos = Vector3.new(x, 2, y)
                    dir = Vector3.new(0, -4, 0)
                    result = workspace:Raycast(pos, dir, raycastParam)

                    if result then
                        AddUnique(points, result.Position)
                    end
                end
            end
        end

        for x = -0.5, 0.5, step do
            for y = -0.5, 0.5, step do
                local pos = Vector3.new(-2, x, y)
                local dir = Vector3.new(4, 0, 0)
                local result = workspace:Raycast(pos, dir, raycastParam)
                if result then
                    AddUnique(points, result.Position)

                    --we hit something, trace from the other side too
                    pos = Vector3.new(2, x, y)
                    dir = Vector3.new(-4, 0, 0)
                    result = workspace:Raycast(pos, dir, raycastParam)
                    if result then
                        AddUnique(points, result.Position)
                    end
                end
            end
        end

        for x = -0.5, 0.5, step do
            for y = -0.5, 0.5, step do
                local pos = Vector3.new(x, y, -2)
                local dir = Vector3.new(0, 0, 4)
                local result = workspace:Raycast(pos, dir, raycastParam)
                if result then
                    AddUnique(points, result.Position)

                    --we hit something, trace from the other side too
                    pos = Vector3.new(x, y, 2)
                    dir = Vector3.new(0, 0, -4)
                    result = workspace:Raycast(pos, dir, raycastParam)
                    if result then
                        AddUnique(points, result.Position)
                    end
                end
            end
        end

        meshCopy:Destroy()

        --Optimize the points down
        local hull = QuickHull2.GenerateHull(points)

        if hull ~= nil then
            local recs = {}

            for _, tri in pairs(hull) do
                local normal = (tri[1] - tri[2]):Cross(tri[1] - tri[3]).Unit
                local ed = tri[1]:Dot(normal) --expanded distance

                if IsUnique(recs, normal, ed) then
                    table.insert(recs, {
                        planeNum = -1, -- FIXME: This was nil before, might cause problems later.
                        n = normal,
                        ed = ed, --expanded
                        tri = tri,
                    })
                end
            end
            points = {}
            for key, record in pairs(recs) do
                local tri = record.tri

                if tri then
                    if IsUniquePoint(points, tri[1]) then
                        table.insert(points, tri[1])
                    end
                    if IsUniquePoint(points, tri[2]) then
                        table.insert(points, tri[2])
                    end
                    if IsUniquePoint(points, tri[3]) then
                        table.insert(points, tri[3])
                    end
                end
            end
            self.meshCache[instance.MeshId] = points
        else
            self.meshCache[instance.MeshId] = {}
        end
    end

    local finals = {}
    local size = instance.Size

    for key, point in pairs(points) do
        local p = cframe:PointToWorldSpace(point * size)
        table.insert(finals, p)
    end

    if false and RunService:IsClient() then
        for key, point in pairs(finals) do
            local debugInstance = Instance.new("Part")
            debugInstance.Parent = workspace
            debugInstance.Anchored = true
            debugInstance.Size = Vector3.new(1, 1, 1)
            debugInstance.Position = point
            debugInstance.Shape = Enum.PartType.Ball
            debugInstance.Color = Color3.new(0, 1, 0)
        end

        self:VisualizePlanesForPoints(finals, workspace)
    end

    self.timeSpentTracing += tick() - start

    return finals
end

function module.GetPlanesForInstanceMeshPart(
    self: Self,
    instance: MeshPart,
    playerSize: Vector3,
    cframe: CFrame,
    basePlaneNum: number,
    showDebugParentPart: BasePart?
): ({ HullRecord }?, number)
    local success, editableMesh = pcall(function()
        return AssetService:CreateEditableMeshFromPartAsync(instance)
    end)
    
    local sourcePoints: {Vector3} = if success
        then editableMesh:GetVertices()
        else self:GetRaytraceInstancePoints(instance, cframe)

    local points = {}

    for _, point in pairs(sourcePoints) do
        for _, c in pairs(corners) do
            table.insert(points, point + (c * playerSize))
        end
    end

    local r = QuickHull2.GenerateHull(points)

    local recs = {}

    --Generate unique planes in n+d format
    if r == nil then
        return nil, basePlaneNum
    end
    for _, tri in pairs(r) do
        local normal = (tri[1] - tri[2]):Cross(tri[1] - tri[3]).Unit
        local ed = tri[1]:Dot(normal) --expanded distance
        basePlaneNum += 1

        if IsUnique(recs, normal, ed) then
            table.insert(recs, {
                n = normal,
                ed = ed, --expanded
                planeNum = basePlaneNum,
            })
        end
    end

    if showDebugParentPart ~= nil and RunService:IsClient() then
        --self:VisualizeTriangles(r, Vector3.zero)
    end

    return recs, basePlaneNum
end

return module
