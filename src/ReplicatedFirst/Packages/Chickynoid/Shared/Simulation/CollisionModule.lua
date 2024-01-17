--@!native
--!strict

local RunService = game:GetService("RunService")
local path = script.Parent.Parent

local MinkowskiSumInstance = require(script.Parent.MinkowskiSumInstance)
local TerrainModule = require(script.Parent.TerrainCollision)
local FastSignal = require(path.Vendor.FastSignal)

local module = {}

type CollisionModule = typeof(module)
type HullRecord = MinkowskiSumInstance.HullRecord

type PartRecord = {
    instance: BasePart?,
    hull: {HullRecord}?,
}

type DynamicPartRecord = PartRecord & {
    currentCFrame: CFrame,
    Update: (self: DynamicPartRecord) -> (),
}

export type HullData = {
    startPos: Vector3,
    endPos: Vector3,
    fraction: number,
    startSolid: boolean,
    allSolid: boolean,
    planeNum: number,
    planeD: number,
    normal: Vector3,
    checks: number,
    hullRecord: PartRecord?,
}

local SKIN_THICKNESS = 0.05 --closest you can get to a wall
module.planeNum = 0
module.gridSize = 4
module.fatGridSize = 16
module.fatPartSize = 32
module.profile = false
module.dynamicRecords = {} :: {DynamicPartRecord}

module.hullRecords = {} :: {
    [BasePart]: PartRecord
}

module.grid = {} :: {
    [Vector3]: {
        [BasePart]: PartRecord
    }
}

module.fatGrid = {} :: {
    [Vector3]: {
        [BasePart]: PartRecord
    }
}

module.cache = {} :: {
    [Vector3]: {
        [Vector3]: {PartRecord}
    }
}

module.cacheCount = 0
module.maxCacheCount = 10000

module.loadProgress = 0
module.OnLoadProgressChanged = FastSignal.new()

module.expansionSize = Vector3.new(2, 5, 2)
module.processing = false

local debugParts = false

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


function module.FetchCell(self: CollisionModule, x: number, y: number, z: number)
	local key = Vector3.new(x, y, z)
	return self.grid[key]
end

function module.FetchFatCell(self: CollisionModule, x: number, y: number, z: number)
	local key = Vector3.new(x, y, z)
	return self.fatGrid[key]
end

function module.CreateAndFetchCell(self: CollisionModule, x: number, y: number, z: number)
	local key = Vector3.new(x, y, z)
	local res = self.grid[key]

	if res == nil then
		res = {}
		self.grid[key] = res
	end

	return res
end

function module.CreateAndFetchFatCell(self: CollisionModule, x: number, y: number, z: number)
	local key = Vector3.new(x, y, z)
	local res = self.fatGrid[key]

	if res == nil then
		res = {}
		self.fatGrid[key] = res
	end

	return res
end

function module.FindAABB(part: BasePart)
    local orientation = part.CFrame
    local size = part.Size

    local minx = math.huge
    local miny = math.huge
    local minz = math.huge

    local maxx = -math.huge
    local maxy = -math.huge
    local maxz = -math.huge

    for _, corner in pairs(corners) do
        local vec = orientation * (size * corner)
        if vec.X < minx then
            minx = vec.X
        end
        if vec.Y < miny then
            miny = vec.Y
        end
        if vec.Z < minz then
            minz = vec.Z
        end
        if vec.X > maxx then
            maxx = vec.X
        end
        if vec.Y > maxy then
            maxy = vec.Y
        end
        if vec.Z > maxz then
            maxz = vec.Z
        end
    end

    return minx, miny, minz, maxx, maxy, maxz
end

function module.WritePartToHashMap(self: CollisionModule, instance: BasePart, hullRecord: PartRecord)
    local minx, miny, minz, maxx, maxy, maxz = module.FindAABB(instance)

	if maxx - minx > self.fatPartSize or maxy-miny > self.fatPartSize or maxz-minz > self.fatPartSize then
						
        --Part is fat
        for x = (minx // self.fatGridSize), (maxx // self.fatGridSize)  do
            for z = (minz // self.fatGridSize), (maxz // self.fatGridSize)  do
                for y = (miny // self.fatGridSize), (maxy // self.fatGridSize)  do
                    local cell = self:CreateAndFetchFatCell(x, y, z)
                    cell[instance] = hullRecord
                end
            end
        end
		--print("Fat part", instance.Name)
		
		--[[
		if (RunService:IsClient() and instance:GetAttribute("showdebug")) then
			for x = math.floor(minx / self.fatGridSize), math.ceil(maxx/self.fatGridSize)-1 do
				for z = math.floor(minz / self.fatGridSize), math.ceil(maxz/self.fatGridSize)-1 do
					for y = math.floor(miny / self.fatGridSize), math.ceil(maxy/self.fatGridSize)-1 do

						self:SpawnDebugFatGridBox(x,y,z, Color3.new(math.random(),1,1))
					end
				end
			end
		end
		]]--
    else
        for x = (minx // self.gridSize), (maxx // self.gridSize) do
            for z = (minz // self.gridSize), (maxz // self.gridSize) do
                for y = (miny // self.gridSize), (maxy // self.gridSize) do
                    local cell = self:CreateAndFetchCell(x, y, z)
                    cell[instance] = hullRecord
                end
            end
        end
        --[[
        if (RunService:IsClient() and instance:GetAttribute("showdebug")) then
            for x = math.floor(minx / self.gridSize), math.ceil(maxx/self.gridSize)-1 do
                for z = math.floor(minz / self.gridSize), math.ceil(maxz/self.gridSize)-1 do
                    for y = math.floor(miny / self.gridSize), math.ceil(maxy/self.gridSize)-1 do

                        self:SpawnDebugGridBox(x,y,z, Color3.new(math.random(),1,1))
                    end
                end
            end
        end]]
    end
end

 

function module.RemovePartFromHashMap(self: CollisionModule, instance: BasePart)
    if instance:GetAttribute("ChickynoidIgnoreRemoval") then
        return
    end

    local minx, miny, minz, maxx, maxy, maxz = module.FindAABB(instance)

	if maxx-minx > self.fatPartSize or maxy-miny > self.fatPartSize or maxz-minz > self.fatPartSize then
        for x = (minx // self.fatGridSize), (maxx // self.fatGridSize)  do
            for z = (minz // self.fatGridSize), (maxz // self.fatGridSize) do
                for y = (miny // self.fatGridSize), (maxy // self.fatGridSize) do
                    local cell = self:FetchFatCell(x, y, z)
                    if cell then
                        cell[instance] = nil
                    end
                end
            end
        end
    else
        for x = (minx // self.gridSize), (maxx // self.gridSize)  do
            for z = (minz // self.gridSize), (maxz // self.gridSize)  do
                for y = (miny // self.gridSize), (maxy // self.gridSize)  do
                    local cell = self:FetchCell(x, y, z)
                    if cell then
                        cell[instance] = nil
                    end
                end
            end
        end
    end
end

function module.FetchHullsForPoint(self: CollisionModule, point: Vector3)
    local cell = self:FetchCell(
        point.X // self.gridSize,
        point.Y // self.gridSize,
        point.Z // self.gridSize
    )

    local hullRecords = {}

    if cell then
        for part, hull in cell do
            hullRecords[part] = hull
        end
    end

    cell = self:FetchFatCell(
        point.X // self.fatGridSize,
        point.Y // self.fatGridSize,
        point.Z // self.fatGridSize
    )

    hullRecords = {}

    if cell then
        for part, hull in cell do
            hullRecords[part] = hull
        end
    end

    return hullRecords
end

function module.FetchHullsForBox(self: CollisionModule, min: Vector3, max: Vector3): {PartRecord}
    local minx = min.X
    local miny = min.Y
    local minz = min.Z

    local maxx = max.X
    local maxy = max.Y
    local maxz = max.Z

    if minx > maxx then
        local t = minx
        minx = maxx
        maxx = t
    end
    if miny > maxy then
        local t = miny
        miny = maxy
        maxy = t
    end
    if minz > maxz then
        local t = minz
        minz = maxz
        maxz = t
	end
	
	local key: Vector3 = Vector3.new(minx, minz, miny) // self.gridSize
	local otherKey: Vector3 = Vector3.new(maxx, maxy, maxz) // self.gridSize

	local cached = self.cache[key]
	if cached then
		local rec = cached[otherKey]
		if rec then
			return rec
		end
	end
			

    local hullMap = {}
    local hullCount = 0

    --Expanded by 1, so objects right on borders will be in the appropriate query
    for x = (minx // self.gridSize) - 1, (maxx // self.gridSize)+1 do
        for z = (minz // self.gridSize) - 1, (maxz // self.gridSize)+1 do
            for y = (miny // self.gridSize) - 1, (maxy // self.gridSize)+1 do
                local cell = self:FetchCell(x, y, z)
                if cell then
                    for part, hull in cell do
                        hullMap[hull] = true
                        hullCount += 1
                    end
                end

                local terrainHull = TerrainModule:FetchCell(x, y, z)
                if terrainHull then
                    for i, hull in pairs(terrainHull) do
                        if not hullMap[hull] then
                            hullMap[hull] = true
                            hullCount += 1
                        end
                    end
                end
            end
        end
    end

    --Expanded by 1, so objects right on borders will be in the appropriate query
    for x =  (minx // self.fatGridSize) - 1, (maxx // self.fatGridSize)+1 do
        for z =  (minz // self.fatGridSize) - 1, (maxz // self.fatGridSize)+1 do
            for y =  (miny // self.fatGridSize) - 1, (maxy // self.fatGridSize)+1 do
                local cell = self:FetchFatCell(x, y, z)
                if cell then
                    for part, hull in cell do
                        hullMap[hull] = true
                        hullCount += 1
                    end
                end
            end
        end
    end
	
	self.cacheCount += 1

	if self.cacheCount > self.maxCacheCount then
		self.cacheCount = 0
		self.cache = {}
	end
	
	--Store it
    local hullRecords = table.create(hullCount)
	cached = self.cache[key]

	if cached == nil then
		cached = {}
		self.cache[key] = cached
	end
    
	--Inflate missing hulls
    for record in hullMap do
    	if record.hull == nil and record.instance then
            local hull = self:GenerateConvexHullAccurate(record.instance, module.expansionSize, self:GenerateSnappedCFrame(record.instance))
			
            if hull then
                record.hull = hull
			else
                continue
            end
		end

        table.insert(hullRecords, record)
	end

	cached[otherKey] = hullRecords
	return hullRecords
end

function module.GenerateConvexHullAccurate(self: CollisionModule, part: BasePart, expansionSize: Vector3, cframe: CFrame): {HullRecord}?
    local debugRoot = nil

    if debugParts == true and RunService:IsClient() then
        debugRoot = workspace.Terrain
    end

    local hull, counter = MinkowskiSumInstance:GetPlanesForInstance(
        part,
        expansionSize,
        cframe,
        self.planeNum,
        debugRoot
    )

    self.planeNum = counter
    return hull
end


--1/100th of a degree  0.01 etc
local function RoundOrientation(num: number): number
	return math.floor(num * 100 + 0.5) / 100
end
 
function module.GenerateSnappedCFrame(self: CollisionModule, instance: BasePart): CFrame
	--Because roblox cannot guarentee perfect replication of part orientation, we'll take what is replicated and rount it after a certain level of precision
	--techically positions might have the same problem, but orientations were mispredicting on sloped surfaces

	local x = RoundOrientation(instance.Orientation.X)
	local y = RoundOrientation(instance.Orientation.Y)
	local z = RoundOrientation(instance.Orientation.Z)
	
	return CFrame.new(instance.CFrame.Position) * CFrame.fromOrientation(math.rad(x), math.rad(y), math.rad(z))
end

function module.ProcessCollisionOnInstance(self: CollisionModule, instance: Instance, playerSize: Vector3)
    if instance:IsA("BasePart") then
        if instance.CanCollide == false then
            return
        end

        if module.hullRecords[instance] ~= nil then
            return
        end
		
        --[[
        if instance:HasTag("Dynamic") then
            local record = {}
            record.instance = instance
            record.hull = self:GenerateConvexHullAccurate(instance, playerSize, instance.CFrame)
            record.currentCFrame = instance.CFrame

            -- Weird Selene shadowing bug here
            -- selene: allow(shadowing)
            function record:Update()
                if
                    ((record.currentCFrame.Position - instance.CFrame.Position).Magnitude < 0.00001)
                    and (record.currentCFrame.LookVector:Dot(instance.CFrame.LookVector) > 0.999)
                then
                    return
                end

                record.hull = module:GenerateConvexHullAccurate(instance, playerSize, instance.CFrame)
                record.currentCFrame = instance.CFrame
            end

            table.insert(module.dynamicRecords, record)

            return
        end
        ]]--

        local record = {}
        record.instance = instance
        --record.hull = self:GenerateConvexHullAccurate(instance, playerSize, self:GenerateSnappedCFrame(instance))
        self:WritePartToHashMap(record.instance, record)

        module.hullRecords[instance] = record
    end
end

function module.SpawnDebugGridBox(self: CollisionModule, x: number, y: number, z: number, color: Color3)
    local instance = Instance.new("Part")
    instance.Size = Vector3.new(self.gridSize, self.gridSize, self.gridSize)
    instance.Position = (Vector3.new(x, y, z) * self.gridSize)
        + (Vector3.new(self.gridSize, self.gridSize, self.gridSize) * 0.5)
    instance.Transparency = 0.75
    instance.Color = color
    instance.Parent = game.Workspace
    instance.Anchored = true
    instance.TopSurface = Enum.SurfaceType.Smooth
    instance.BottomSurface = Enum.SurfaceType.Smooth
end


function module.SpawnDebugFatGridBox(self: CollisionModule, x: number, y: number, z: number, color: Color3)
	local instance = Instance.new("Part")
	instance.Size = Vector3.new(self.fatGridSize, self.fatGridSize, self.fatGridSize)
	instance.Position = (Vector3.new(x, y, z) * self.fatGridSize)
		+ (Vector3.new(self.fatGridSize, self.fatGridSize, self.fatGridSize) * 0.5)
	instance.Transparency = 0.75
	instance.Color = color
	instance.Parent = game.Workspace
	instance.Anchored = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
end

function module.SimpleRayTest(self: CollisionModule, a: Vector3, b: Vector3, hull: {Plane}): (number?, number?)
    local d = b - a
    
    local tfirst = -1
    local tlast = 1
    
    for _, p in pairs(hull) do
        local denom = p.n:Dot(d)
        local dist = p.ed - ( p.n:Dot(a) )

        if denom == 0 then
            if dist > 0 then
                return nil, nil
            end
        else
            local t = dist / denom
            if denom < 0 then
                if t > tfirst then
                    tfirst = t
                end
            else
                if t < tlast then
                    tlast = t
                end
            end
            
            if tfirst > tlast then
                return nil, nil
            end
        end
    end

    return tfirst, tlast
end


function module.CheckBrushPoint(self: CollisionModule, data: HullData, hullRecord: PartRecord)
    local startsOut = false
    local hullPtr = hullRecord.hull

    if hullPtr == nil then
        return
    end

    for _, p in pairs(hullPtr) do
        local startDistance = data.startPos:Dot(p.n) - p.ed

        if startDistance > 0 then
            startsOut = true
            break
        end
    end

    if startsOut == false then
        data.startSolid = true
        data.allSolid = true
        return
    end

    data.hullRecord = hullRecord
end

--Checks a brush, but doesn't handle it well if the start point is inside a brush
function module.CheckBrush(self: CollisionModule, data: HullData, hullRecord: PartRecord)
    local startFraction = -1.0
    local endFraction = 1.0
    local startsOut = false
    local endsOut = false
    local lastPlane = nil
    local hull = hullRecord.hull

    if not hull then
        return
    end

    for _, p in pairs(hull) do
        local startDistance = data.startPos:Dot(p.n) - p.ed
        local endDistance = data.endPos:Dot(p.n) - p.ed

        if startDistance > 0 then
            startsOut = true
        end
        if endDistance > 0 then
            endsOut = true
        end

        -- make sure the trace isn't completely on one side of the brush
        if startDistance > 0 and (endDistance >= SKIN_THICKNESS or endDistance >= startDistance) then
            return --both are in front of the plane, its outside of this brush
        end
        if startDistance <= 0 and endDistance <= 0 then
            --both are behind this plane, it will get clipped by another one
            continue
        end

        if startDistance > endDistance then
            --  line is entering into the brush
            local fraction = (startDistance - SKIN_THICKNESS) / (startDistance - endDistance)
            if fraction < 0 then
                fraction = 0
            end
            if fraction > startFraction then
                startFraction = fraction
                lastPlane = p
            end
        else
            --line is leaving the brush
            local fraction = (startDistance + SKIN_THICKNESS) / (startDistance - endDistance)
            if fraction > 1 then
                fraction = 1
            end
            if fraction < endFraction then
                endFraction = fraction
            end
        end
    end

    if startsOut == false then
        data.startSolid = true
        if endsOut == false then
            --Allsolid
            data.allSolid = true
            return
        end
    end

    --Update the output fraction
    if startFraction < endFraction then
        if startFraction > -1 and startFraction < data.fraction then
            if startFraction < 0 then
                startFraction = 0
            end
            data.fraction = startFraction
            data.normal = lastPlane.n
            data.planeD = lastPlane.ed
            data.planeNum = lastPlane.planeNum
            data.hullRecord = hullRecord
        end
    end
end

--Checks a brush, but is smart enough to ignore the brush entirely if the start point is inside but the ray is "exiting" or "exited"


function module.CheckBrushNoStuck(self: CollisionModule, data: HullData, hullRecord: PartRecord)
    local startFraction = -1.0
    local endFraction = 1.0
    local startsOut = false
    local endsOut = false
    local lastPlane = nil

    local nearestStart = -math.huge
    local nearestEnd = -math.huge
    local hull = hullRecord.hull

    if not hull then
        return
    end
	
    for _, p in pairs(hull) do
        local startDistance = data.startPos:Dot(p.n) - p.ed
        local endDistance = data.endPos:Dot(p.n) - p.ed

        if startDistance > 0 then
            startsOut = true
        end

        if endDistance > 0 then
            endsOut = true
        end

        -- make sure the trace isn't completely on one side of the brush
        if startDistance > 0 and (endDistance >= SKIN_THICKNESS or endDistance >= startDistance) then
            return --both are in front of the plane, its outside of this brush
        end

        --Record the distance to this plane
        nearestStart = math.max(nearestStart, startDistance)
        nearestEnd = math.max(nearestEnd, endDistance)

        if startDistance <= 0 and endDistance <= 0 then
            --both are behind this plane, it will get clipped by another one
            continue
        end

        if startDistance > endDistance then
            --  line is entering into the brush
            local fraction = (startDistance - SKIN_THICKNESS) / (startDistance - endDistance)
            if fraction < 0 then
                fraction = 0
            end
            if fraction > startFraction then
                startFraction = fraction
                lastPlane = p
            end
        else
            --line is leaving the brush
            local fraction = (startDistance + SKIN_THICKNESS) / (startDistance - endDistance)
            if fraction > 1 then
                fraction = 1
            end
            if fraction < endFraction then
                endFraction = fraction
            end
        end
    end

    --Point started inside this brush
    if startsOut == false then
        data.startSolid = true

        --We might be both start-and-end solid
        --If thats the case, we want to pretend we never saw this brush if we are moving "out"
        --This is either: we exited - or -
        --                the end point is nearer any plane than the start point is
        if endsOut == false and nearestEnd < nearestStart then
            --Allsolid
            data.allSolid = true
            return
        end

        --Not stuck! We should pretend we never touched this brush
        data.startSolid = false
        return --Ignore this brush
    end

    --Update the output fraction
    if startFraction < endFraction then
        if startFraction > -1 and startFraction < data.fraction then
            if startFraction < 0 then
                startFraction = 0
            end
            data.fraction = startFraction
            data.normal = lastPlane.n
            data.planeD = lastPlane.ed
            data.planeNum = lastPlane.planeNum
            data.hullRecord = hullRecord
        end
    end
end

function module.PlaneLineIntersect(self: CollisionModule, normal: Vector3, distance: number, V1: Vector3, V2: Vector3): Vector3?
    local denominator = normal:Dot(V2 - V1)

    if denominator == 0 then
        return nil
    end

    local u = (normal:Dot(V1) + distance) / -denominator
    return (V1 + u * (V2 - V1))
end


function module.Sweep(self: CollisionModule, startPos: Vector3, endPos: Vector3): HullData
    local data = {}
    data.startPos = startPos
    data.endPos = endPos
    data.fraction = 1
    data.startSolid = false
    data.allSolid = false
    data.planeNum = 0
    data.planeD = 0
    data.normal = Vector3.yAxis
    data.checks = 0
    data.hullRecord = nil

    if (startPos - endPos).Magnitude > 1000 then
        return data
    end

    if self.profile then
        debug.profilebegin("Sweep")
    end

	--calc bounds of sweep
	if self.profile then
		debug.profilebegin("Fetch")
	end

    local hullRecords = self:FetchHullsForBox(startPos, endPos)

	if self.profile then
		debug.profileend()
	end
	
	if self.profile then
		debug.profilebegin("Collide")
	end
    
    for _, hullRecord in pairs(hullRecords) do
		data.checks += 1
		
		if (hullRecord.hull ~= nil) then
	        self:CheckBrushNoStuck(data, hullRecord)
	        if data.allSolid == true then
	            data.fraction = 0
	            break
	        end
	        if data.fraction < SKIN_THICKNESS then
	            break
			end
		end
	end

	if self.profile then
		debug.profileend()
	end

    --Collide with dynamic objects
    if data.fraction >= SKIN_THICKNESS or data.allSolid == false then
        for _, hullRecord in pairs(self.dynamicRecords) do
            data.checks += 1

            self:CheckBrushNoStuck(data, hullRecord)
            if data.allSolid then
                data.fraction = 0
                break
            end
            if data.fraction < SKIN_THICKNESS then
                break
            end
        end
    end

    if data.fraction < 1 then
        local vec = (endPos - startPos)
        data.endPos = startPos + (vec * data.fraction)
    end

    if self.profile then
        debug.profileend()
    end

    return data
end

function module.BoxTest(self: CollisionModule, pos: Vector3): HullData
    local data = {}
    data.startPos = pos
    data.endPos = pos
    data.fraction = 1
    data.startSolid = false
    data.allSolid = false
    data.planeNum = 0
    data.planeD = 0
    data.normal = Vector3.yAxis
    data.checks = 0
    data.hullRecord = nil

    debug.profilebegin("PointTest")
    --calc bounds of sweep
    local hullRecords = self:FetchHullsForPoint(pos)

    for _, hullRecord in pairs(hullRecords) do
        data.checks += 1
        self:CheckBrushPoint(data, hullRecord)
        if data.allSolid == true then
            data.fraction = 0
            break
        end
    end

    debug.profileend()
    return data
end

--Call this before you try and simulate
function module.UpdateDynamicParts(self: CollisionModule)
    for _, record in pairs(self.dynamicRecords) do
        if record.Update then
            record:Update()
        end
    end
end

function module.MakeWorld(self: CollisionModule, folder: Folder, playerSize: Vector3)
	
	debug.setmemorycategory("ChickynoidCollision")
	
    self.expansionSize = playerSize
	self.hulls = {}
	self:ClearCache()
	
	if (self.processing == true) then
		return
	end
	self.processing = true
    TerrainModule:Setup(self.gridSize, playerSize)
	
	local startTime = tick()
	local meshTime = 0

	coroutine.wrap(function()
		local list = folder:GetDescendants()
		local total = #folder:GetDescendants()
		
		local lastTime = tick()
		for counter = 1, total do		
			local instance = list[counter]
						
			if (instance:IsA("BasePart") and instance.CanCollide == true) then
						
				local begin = tick()
				self:ProcessCollisionOnInstance(instance, playerSize)
				local timeTaken = tick()- begin
				if (instance:IsA("MeshPart")) then
					meshTime += timeTaken
				end				
			end
		
            local maxTime = 0.2
 
            if (tick() - lastTime > maxTime) then
                lastTime = tick()
      
				wait()	
		
                local progress = counter/total;
                module.loadProgress = progress;
                module.OnLoadProgressChanged:Fire(progress)
				print("Collision processing: " .. math.floor(progress * 100) .. "%")
			end
	    end
        module.loadProgress = 1
        module.OnLoadProgressChanged:Fire(1)
		print("Collision processing: 100%")
		self.processing = false
		
		if (RunService:IsServer()) then
			print("Server Time Taken: ", math.floor(tick() - startTime), "seconds")
			
		else
			print("Client Time Taken: ", math.floor(tick() - startTime), "seconds")
		end
		print("Mesh time: ", meshTime, "seconds")
		print("Tracing time:", MinkowskiSumInstance.timeSpentTracing, "seconds")
		self:ClearCache()
 
	end)()
	
	
	 
    folder.DescendantAdded:Connect(function(instance)
        self:ClearCache()
        self:ProcessCollisionOnInstance(instance, playerSize)
    end)
    
    folder.DescendantRemoving:Connect(function(instance)
        if instance:IsA("BasePart") and module.hullRecords[instance] then
            self:ClearCache()
            self:RemovePartFromHashMap(instance)
        end
    end)
end

function module.ClearCache(self: CollisionModule)
	self.cache = {}
	self.cacheCount = 0	
end

return module
