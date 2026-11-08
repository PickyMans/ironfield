--[[
	Projectiles
	Purely visual arrows. The server decides where they land and who they hit;
	the client just flies a pooled arrow part along a ballistic arc from the
	shooter's rendered position to the impact point and leaves it stuck in the
	ground for a few seconds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Heightmap = require(Shared.Heightmap)

local Renderer = require(script.Parent.Renderer)

local Projectiles = {}

local STUCK_TIME = 4
local MAX_ARROWS = 900
local HIDDEN_CF = CFrame.new(0, -2000, 0)

local folder: Folder? = nil
local pool = {}
local active = {}
local partsBuf, cframesBuf = {}, {}

local function newArrow()
	local p = Instance.new("Part")
	p.Name = "Arrow"
	p.Size = Vector3.new(0.12, 0.12, 2.4)
	p.Color = Color3.fromRGB(70, 54, 38)
	p.Material = Enum.Material.Wood
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CFrame = HIDDEN_CF
	local fletch = Instance.new("Part")
	fletch.Name = "Fletching"
	fletch.Size = Vector3.new(0.04, 0.3, 0.5)
	fletch.Color = Color3.fromRGB(235, 230, 220)
	fletch.Material = Enum.Material.SmoothPlastic
	fletch.Anchored = true
	fletch.CanCollide = false
	fletch.CanQuery = false
	fletch.CanTouch = false
	fletch.CastShadow = false
	fletch.CFrame = HIDDEN_CF
	p.Parent = folder
	fletch.Parent = folder
	return { shaft = p, fletch = fletch }
end

function Projectiles.reset()
	if folder then
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "Arrows"
	folder.Parent = workspace
	table.clear(pool)
	table.clear(active)
end

function Projectiles.spawnVolley(arrows, now: number)
	if not folder then
		Projectiles.reset()
	end
	for _, a in arrows do
		if #active >= MAX_ARROWS then
			break
		end
		local origin = Renderer.soldierPosition(a.regId, a.index)
		if origin then
			origin += Vector3.new(0, 3.2, 0)
			local target = Vector3.new(a.tx, Heightmap.get(a.tx, a.tz) + 0.4, a.tz)
			local horizontal = (Vector3.new(target.X, 0, target.Z) - Vector3.new(origin.X, 0, origin.Z)).Magnitude
			local obj = table.remove(pool) or newArrow()
			obj.origin = origin
			obj.target = target
			obj.apex = horizontal * 0.22 + 2
			obj.t0 = now
			obj.flight = math.max(a.flight, 0.2)
			obj.landed = false
			obj.landCF = nil
			table.insert(active, obj)
		end
	end
end

local function arcPoint(o, t: number): Vector3
	local p = o.origin:Lerp(o.target, t)
	return p + Vector3.new(0, 4 * o.apex * t * (1 - t), 0)
end

function Projectiles.update(now: number)
	local n = 0
	local parts, cframes = partsBuf, cframesBuf
	local i = 1
	while i <= #active do
		local o = active[i]
		local t = (now - o.t0) / o.flight
		if t >= 1 then
			if not o.landed then
				o.landed = true
				local p1, p2 = arcPoint(o, 0.97), o.target
				local dir = (p2 - p1)
				if dir.Magnitude < 1e-3 then
					dir = Vector3.new(0, -1, 0)
				end
				-- bury the tip a little
				o.landCF = CFrame.lookAt(p2, p2 + dir.Unit) * CFrame.new(0, 0, -0.5)
				n += 1
				parts[n], cframes[n] = o.shaft, o.landCF
				n += 1
				parts[n], cframes[n] = o.fletch, o.landCF * CFrame.new(0, 0, 1.05)
			end
			if now - o.t0 - o.flight > STUCK_TIME then
				o.shaft.CFrame = HIDDEN_CF
				o.fletch.CFrame = HIDDEN_CF
				active[i] = active[#active]
				active[#active] = nil
				table.insert(pool, o)
				continue
			end
		else
			local p = arcPoint(o, t)
			local ahead = arcPoint(o, math.min(t + 0.02, 1))
			local dir = ahead - p
			local cf
			if dir.Magnitude > 1e-4 then
				cf = CFrame.lookAt(p, p + dir.Unit)
			else
				cf = CFrame.new(p)
			end
			n += 1
			parts[n], cframes[n] = o.shaft, cf
			n += 1
			parts[n], cframes[n] = o.fletch, cf * CFrame.new(0, 0, 1.05)
		end
		i += 1
	end
	for k = n + 1, #parts do
		parts[k] = nil
		cframes[k] = nil
	end
	if n > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

return Projectiles
