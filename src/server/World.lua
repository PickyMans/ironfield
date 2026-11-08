--[[
	World
	Builds the battlefield: smooth terrain from the shared heightmap, a dirt
	road, forests, boulders and the lighting/atmosphere.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Heightmap = require(Shared.Heightmap)

local World = {}

local RES = 4
local MIN_Y = -24
local MAX_Y = 96
local CHUNK = 128

local M = Enum.Material

local function roadX(z: number, seed: number): number
	return math.noise(z / 240, seed * 0.13, 4.7) * 90
end

local function surfaceMaterial(x: number, z: number, h: number, seed: number)
	local slope = Heightmap.slope(x, z)
	if slope > 0.6 then
		return M.Rock
	elseif slope > 0.38 then
		return M.Ground
	end
	if math.abs(x - roadX(z, seed)) < 5 + math.noise(z / 20, seed) * 1.5 then
		return M.Mud
	end
	local n = math.noise(x / 70, z / 70, seed + 5.5)
	if n > 0.22 then
		return M.LeafyGrass
	elseif n < -0.3 then
		return M.Ground
	end
	if h > 40 then
		return M.Rock
	end
	return M.Grass
end

function World.buildTerrain(seed: number)
	local terrain = workspace.Terrain
	terrain:Clear()
	terrain:SetMaterialColor(M.Grass, Color3.fromRGB(98, 124, 58))
	terrain:SetMaterialColor(M.LeafyGrass, Color3.fromRGB(80, 106, 46))
	terrain:SetMaterialColor(M.Ground, Color3.fromRGB(112, 94, 68))
	terrain:SetMaterialColor(M.Mud, Color3.fromRGB(96, 80, 60))
	terrain:SetMaterialColor(M.Rock, Color3.fromRGB(110, 108, 102))

	local half = Config.MAP_HALF
	local ny = (MAX_Y - MIN_Y) // RES
	local nxz = CHUNK // RES

	for x0 = -half, half - 1, CHUNK do
		for z0 = -half, half - 1, CHUNK do
			local mats, occs = table.create(nxz), table.create(nxz)
			for ix = 1, nxz do
				local mx, ox = table.create(ny), table.create(ny)
				for iy = 1, ny do
					mx[iy] = table.create(nxz)
					ox[iy] = table.create(nxz)
				end
				mats[ix], occs[ix] = mx, ox
				local wx = x0 + (ix - 0.5) * RES
				for iz = 1, nxz do
					local wz = z0 + (iz - 0.5) * RES
					local h = Heightmap.get(wx, wz)
					local surf = surfaceMaterial(wx, wz, h, seed)
					for iy = 1, ny do
						local y0 = MIN_Y + (iy - 1) * RES
						local occ = math.clamp((h - y0) / RES, 0, 1)
						if occ <= 0 then
							mx[iy][iz] = M.Air
							ox[iy][iz] = 0
						else
							mx[iy][iz] = (h - y0 > RES * 2) and M.Ground or surf
							ox[iy][iz] = occ
						end
					end
				end
			end
			local region = Region3.new(Vector3.new(x0, MIN_Y, z0), Vector3.new(x0 + CHUNK, MAX_Y, z0 + CHUNK))
			terrain:WriteVoxels(region, RES, mats, occs)
			task.wait()
		end
	end
end

local function makePart(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		p[k] = v
	end
	return p
end

local function makeTree(rng: Random, x: number, z: number, parent: Instance)
	local y = Heightmap.get(x, z)
	local model = Instance.new("Model")
	model.Name = "Tree"
	local trunkH = rng:NextNumber(6, 10)
	local trunk = makePart({
		Name = "Trunk",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(trunkH, 1.1, 1.1),
		CFrame = CFrame.new(x, y + trunkH / 2 - 0.5, z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(92, 66, 44),
		Material = M.Wood,
	})
	trunk.Parent = model
	local green = Color3.fromRGB(rng:NextInteger(48, 70), rng:NextInteger(82, 104), rng:NextInteger(36, 50))
	local conifer = rng:NextNumber() < 0.45
	if conifer then
		for i = 0, 2 do
			local s = 7 - i * 1.9
			local cone = makePart({
				Name = "Leaves",
				Size = Vector3.new(s, s * 0.55, s),
				CFrame = CFrame.new(x, y + trunkH - 1 + i * 2.4, z)
					* CFrame.Angles(0, i * 0.5 + rng:NextNumber(0, 1), 0),
				Color = green,
				Material = M.Grass,
				CastShadow = true,
			})
			cone.Parent = model
		end
	else
		for _ = 1, 3 do
			local s = rng:NextNumber(5, 8)
			local ball = makePart({
				Name = "Leaves",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(s, s, s),
				CFrame = CFrame.new(
					x + rng:NextNumber(-1.8, 1.8),
					y + trunkH + rng:NextNumber(-0.5, 2),
					z + rng:NextNumber(-1.8, 1.8)
				),
				Color = green,
				Material = M.Grass,
				CastShadow = true,
			})
			ball.Parent = model
		end
	end
	model.Parent = parent
end

local function makeRock(rng: Random, x: number, z: number, parent: Instance)
	local y = Heightmap.get(x, z)
	local s = rng:NextNumber(2, 6)
	local rock = makePart({
		Name = "Rock",
		Size = Vector3.new(s * rng:NextNumber(1, 1.6), s * 0.7, s),
		CFrame = CFrame.new(x, y + s * 0.15, z)
			* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6.28), rng:NextNumber(-0.3, 0.3)),
		Color = Color3.fromRGB(118, 116, 110),
		Material = M.Slate,
	})
	rock.Parent = parent
end

-- Keep the deployment zones and the centre clear so scenery doesn't sit inside formations.
local function blocked(x: number, z: number): boolean
	local hw = Config.DEPLOY_HALF_WIDTH + 20
	for _, t in Config.Teams do
		if math.abs(x) < hw and z > t.deployZ[1] - 20 and z < t.deployZ[2] + 20 then
			return true
		end
	end
	if math.abs(x) < 200 and math.abs(z) < 150 then
		return true
	end
	return math.abs(x) > Config.MAP_HALF - 10 or math.abs(z) > Config.MAP_HALF - 10
end

function World.buildScenery(seed: number)
	local old = workspace:FindFirstChild("Scenery")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Scenery"

	local rng = Random.new(seed)
	local half = Config.MAP_HALF - 20

	-- forests
	for _ = 1, 16 do
		local cx, cz = rng:NextNumber(-half, half), rng:NextNumber(-half, half)
		if not blocked(cx, cz) then
			local count = rng:NextInteger(8, 18)
			for _ = 1, count do
				local a, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0, 45)
				local x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
				if not blocked(x, z) then
					makeTree(rng, x, z, folder)
				end
			end
		end
	end
	-- lone trees and boulders
	for _ = 1, 40 do
		local x, z = rng:NextNumber(-half, half), rng:NextNumber(-half, half)
		if not blocked(x, z) then
			makeTree(rng, x, z, folder)
		end
	end
	for _ = 1, 45 do
		local x, z = rng:NextNumber(-half, half), rng:NextNumber(-half, half)
		if not blocked(x, z) then
			makeRock(rng, x, z, folder)
		end
	end

	folder.Parent = workspace
end

function World.setupLighting()
	Lighting.ClockTime = 15.2
	Lighting.GeographicLatitude = 35
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(70, 70, 78)
	Lighting.OutdoorAmbient = Color3.fromRGB(132, 132, 142)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.25

	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") or child:IsA("PostEffect") then
			child:Destroy()
		end
	end

	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.3
	atmosphere.Offset = 0.12
	atmosphere.Color = Color3.fromRGB(200, 192, 172)
	atmosphere.Decay = Color3.fromRGB(104, 112, 126)
	atmosphere.Glare = 0.25
	atmosphere.Haze = 1.4
	atmosphere.Parent = Lighting

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Saturation = 0.06
	cc.Contrast = 0.08
	cc.Brightness = 0.01
	cc.TintColor = Color3.fromRGB(255, 247, 234)
	cc.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.35
	bloom.Size = 24
	bloom.Threshold = 1.6
	bloom.Parent = Lighting

	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = 0.05
	rays.Spread = 0.6
	rays.Parent = Lighting
end

function World.build(seed: number)
	World.buildTerrain(seed)
	World.buildScenery(seed)
end

return World
