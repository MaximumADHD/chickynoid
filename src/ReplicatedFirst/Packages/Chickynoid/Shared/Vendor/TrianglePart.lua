--!strict
local Triangle = {}

local ref = Instance.new("WedgePart")
ref.Color = Color3.fromRGB(200, 255, 200)
ref.Material = Enum.Material.SmoothPlastic
ref.Reflectance = 0
ref.Transparency = 0
ref.Name = "Tri"
ref.Anchored = true
ref.CanCollide = false
ref.CanTouch = false
ref.CanQuery = false
ref.CFrame = CFrame.new()
ref.Size = Vector3.new(0.25, 0.25, 0.25)
ref.BottomSurface = Enum.SurfaceType.Smooth
ref.TopSurface = Enum.SurfaceType.Smooth

local function fromAxes(p: Vector3, x: Vector3, y: Vector3, z: Vector3)
    return CFrame.new(p.X, p.Y, p.Z, x.X, y.X, z.X, x.Y, y.Y, z.Y, x.Z, y.Z, z.Z)
end

function Triangle:Triangle(a: Vector3, b: Vector3, c: Vector3)
    local ab, ac, bc = b - a, c - a, c - b
    local abl, acl, bcl = ab.Magnitude, ac.Magnitude, bc.Magnitude
    if abl > bcl and abl > acl then
        c, a = a, c
    elseif acl > bcl and acl > abl then
        a, b = b, a
    end
    ab, ac, bc = b - a, c - a, c - b
    local out = ac:Cross(ab).Unit
    local wb = ref:Clone()
    local wc = ref:Clone()
    local biDir = bc:Cross(out).Unit
    local biLen = math.abs(ab:Dot(biDir))
    local norm = bc.Magnitude
    wb.Size = Vector3.new(0, math.abs(ab:Dot(bc)) / norm, biLen)
    wc.Size = Vector3.new(0, biLen, math.abs(ac:Dot(bc)) / norm)
    bc = -bc.Unit
    wb.CFrame = fromAxes((a + b) / 2, -out, bc, -biDir)
    wc.CFrame = fromAxes((a + c) / 2, -out, biDir, bc)

    return wb, wc
end

return Triangle
