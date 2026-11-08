--[[
	Headless battle test (run with Lune: `lune run tools/headless.luau [seconds] [mode]`)

	Loads the real server + shared modules with minimal Roblox stubs and plays
	a full AI vs AI battle, then reports the result, server tick cost and
	network bandwidth. mode = "ai" (default) or "player" (team 1 gets scripted orders).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local ROOT = "src"
local seconds = tonumber(process.args[1]) or 600
local mode = process.args[2] or "ai"

-- Signals / instances ---------------------------------------------------

local function signal()
	return {
		Connect = function()
			return { Disconnect = function() end }
		end,
	}
end

local sent = { Snapshot = 0, Volley = 0, Other = 0, snapshots = 0, maxSnapshot = 0 }

local function newInstance(className, name)
	local inst = { ClassName = className, Name = name or className, _children = {} }
	local mt = {}
	function mt.__index(t, k)
		local child = rawget(t, "_children")[k]
		if child then
			return child
		end
		return nil
	end
	setmetatable(inst, mt)
	function inst:FindFirstChild(n)
		return self._children[n]
	end
	function inst:WaitForChild(n)
		return self._children[n]
	end
	function inst:GetChildren()
		local out = {}
		for _, c in self._children do
			table.insert(out, c)
		end
		return out
	end
	function inst:IsA(c)
		return self.ClassName == c
	end
	function inst:Destroy() end
	function inst:Clear() end
	function inst:SetMaterialColor() end
	function inst:WriteVoxels() end
	function inst:FireAllClients(payload)
		if self.Name == "Snapshot" then
			local n = buffer.len(payload)
			sent.Snapshot += n
			sent.snapshots += 1
			sent.maxSnapshot = math.max(sent.maxSnapshot, n)
		elseif self.Name == "Volley" then
			sent.Volley += buffer.len(payload)
		else
			sent.Other += 1
		end
	end
	function inst:FireClient() end
	inst.OnServerEvent = signal()
	return inst
end

local function addChild(parent, child)
	parent._children[child.Name] = child
	rawset(child, "Parent", parent)
	return child
end

-- Module tree -------------------------------------------------------------

local cache = {}
local env

local function requireNode(node)
	if cache[node] then
		return cache[node]
	end
	assert(node and node._path, "require on a non-module")
	local src = fs.readFile(node._path)
	local fn = luau.load(src, { debugName = node._path, environment = env(node), injectGlobals = true })
	local result = fn()
	cache[node] = result
	return result
end

local function moduleNode(path, name)
	local node = newInstance("ModuleScript", name)
	node._path = path
	return node
end

local function folderOf(dir, name, className)
	local folder = newInstance(className or "Folder", name)
	for _, file in fs.readDir(dir) do
		local full = dir .. "/" .. file
		if fs.isFile(full) and file:match("%.lua$") and not file:match("^init%.") then
			addChild(folder, moduleNode(full, (file:gsub("%.lua$", ""))))
		end
	end
	return folder
end

local ReplicatedStorage = newInstance("ReplicatedStorage")
addChild(ReplicatedStorage, folderOf(ROOT .. "/shared", "Shared"))
local Server = folderOf(ROOT .. "/server", "Server", "Script")

-- stub the world builder (terrain voxels need a real engine) unless testing it
if process.args[2] ~= "world" then
	Server._children.World = moduleNode("tools/stub_world.luau", "World")
end

local Workspace = newInstance("Workspace")
addChild(Workspace, newInstance("Terrain", "Terrain"))

local services = {
	ReplicatedStorage = ReplicatedStorage,
	Players = {
		GetPlayers = function()
			return {}
		end,
		PlayerAdded = signal(),
		PlayerRemoving = signal(),
	},
	RunService = {
		IsServer = function()
			return true
		end,
		Heartbeat = signal(),
	},
	Lighting = newInstance("Lighting"),
}

local game = {
	GetService = function(_, name)
		return services[name] or newInstance(name)
	end,
}

local InstanceLib = {
	new = function(className)
		return newInstance(className)
	end,
}

function env(node)
	return {
		script = node,
		game = game,
		workspace = Workspace,
		Instance = InstanceLib,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		Random = {
			new = function()
				return {
					NextNumber = function(_, a, b)
						a, b = a or 0, b or 1
						return a + math.random() * (b - a)
					end,
					NextInteger = function(_, a, b)
						return math.random(a, b)
					end,
				}
			end,
		},
		Region3 = roblox.Region3,
		require = requireNode,
		task = {
			wait = function() end,
			spawn = function(f, ...)
				f(...)
			end,
			delay = function() end,
		},
		warn = function(...)
			print("[warn]", ...)
		end,
	}
end

-- Run -------------------------------------------------------------------

if mode == "world" then
	local Heightmap = requireNode(ReplicatedStorage.Shared.Heightmap)
	local World = requireNode(Server.World)
	local voxels, hmin, hmax = 0, math.huge, -math.huge
	Workspace.Terrain.WriteVoxels = function(_, region, res, mats, occs)
		for x = 1, #mats do
			for y = 1, #mats[x] do
				for z = 1, #mats[x][y] do
					assert(mats[x][y][z] ~= nil and occs[x][y][z] ~= nil, "hole in voxel arrays")
					voxels += 1
				end
			end
		end
	end
	Heightmap.setSeed(1234)
	for x = -560, 560, 20 do
		for z = -560, 560, 20 do
			local h = Heightmap.get(x, z)
			hmin, hmax = math.min(hmin, h), math.max(hmax, h)
		end
	end
	local t0 = os.clock()
	World.setupLighting()
	World.build(1234)
	print(string.format("world ok: %d voxels in %.2fs, height range %.1f..%.1f", voxels, os.clock() - t0, hmin, hmax))
	return
end

local Net = requireNode(ReplicatedStorage.Shared.Net)
Net.init()
local Config = requireNode(ReplicatedStorage.Shared.Config)
if process.env.FLAT == "1" then
	local Heightmap = requireNode(ReplicatedStorage.Shared.Heightmap)
	Heightmap.get = function()
		return 10
	end
end
if process.env.MIRROR == "1" then
	-- swap which side of the map each team starts on
	local t1, t2 = Config.Teams[1], Config.Teams[2]
	t1.frontZ, t2.frontZ = t2.frontZ, t1.frontZ
	t1.deployZ, t2.deployZ = t2.deployZ, t1.deployZ
	t1.facingZ, t2.facingZ = t2.facingZ, t1.facingZ
end
local Battle = requireNode(Server.Battle)
local Combat = requireNode(Server.Combat)

math.randomseed(tonumber(process.args[3]) or 7)
local battle = Battle.new()
local fakePlayer = { DisplayName = "Tester", Name = "Tester" }
if mode == "player" then
	battle.controllers[1] = fakePlayer
end
battle:startNew()
assert(battle.phase == "Deployment", "expected deployment phase, got " .. battle.phase)

-- deployment order test: redeploy the left spear unit
if mode == "archery" then
	-- static test: team 2 spears stand still 120 studs in front of team 1 archers
	battle:beginBattle()
	for _, r in battle.regiments do
		if r.team == 1 and r.typeKey == "Archers" then
			r:teleport(r.ax, 100, 0, -1, r.width)
		elseif r.team == 2 and r.typeKey == "Spearmen" and r.ax == 0 then
			r:teleport(0, -20, 0, 1, r.width)
		else
			-- park everyone else far away in the corners
			r:teleport(-440 + r.id * 45, r.team == 1 and 470 or -470, 0, 1, r.width)
		end
	end
	battle.ais = {}
elseif mode == "player" then
	local r = battle.regiments[2]
	battle:handleCommand(fakePlayer, {
		kind = "move",
		orders = { { id = r.id, x = -60, z = 240, fx = 0, fz = -1, width = 15 } },
	})
	battle:handleCommand(fakePlayer, { kind = "ready" })
elseif mode ~= "archery" then
	battle:beginBattle()
end
assert(battle.phase == "Battle", "battle did not start")

local States = Config.States
local dt = 1 / Config.TICK_RATE
local steps = math.floor(seconds / dt)
local worst, total = 0, 0
local ordered = false
local lastReport = 0

for i = 1, steps do
	if mode == "player" and not ordered and battle.time > 3 then
		-- scripted player: line infantry up and send everything at the nearest enemy
		ordered = true
		local ids = {}
		for _, r in battle.regiments do
			if r.team == 1 then
				table.insert(ids, r.id)
			end
		end
		local target
		for _, r in battle.regiments do
			if r.team == 2 and r.def.category == "infantry" then
				target = r
				break
			end
		end
		battle:handleCommand(fakePlayer, { kind = "attack", ids = ids, target = target.id, run = false })
		battle:handleCommand(fakePlayer, { kind = "run", ids = { ids[1] }, value = true })
	end

	local t0 = os.clock()
	battle:step(dt)
	local cost = os.clock() - t0
	total += cost
	worst = math.max(worst, cost)

	if battle.time - lastReport >= (tonumber(process.args[4]) or 30) then
		lastReport = battle.time
		local alive = { 0, 0 }
		local states = { {}, {} }
		for _, r in battle.regiments do
			alive[r.team] += r.alive
			table.insert(
				states[r.team],
				string.format("%s:%s(%d,%d)", r.def.short, Config.StateNames[r.state], r.alive, math.floor(r.morale))
			)
		end
		print(string.format("t=%4ds  men %3d vs %3d", math.floor(battle.time), alive[1], alive[2]))
		print("   T1 " .. table.concat(states[1], " "))
		print("   T2 " .. table.concat(states[2], " "))
	end
	if battle.phase == "Ended" then
		break
	end
end

print("----")
print(string.format("phase=%s winner=%d time=%.1fs", battle.phase, battle.winner, battle.time))
print(
	string.format("losses %d / %d   fled %d / %d", battle.losses[1], battle.losses[2], battle.fled[1], battle.fled[2])
)
local kills = { 0, 0 }
for _, r in battle.regiments do
	kills[r.team] += r.kills
end
print(string.format("kills %d / %d", kills[1], kills[2]))
local cs = Combat.stats
print(
	string.format(
		"kills by cause: melee %d, arrow %d, charge %d, braced spears %d",
		cs.melee,
		cs.arrow,
		cs.charge,
		cs.braced
	)
)
local as = Combat.arrowStats
print(
	string.format(
		"arrows: fired %d, hit %d (friendly %d), blocked %d, missed %d",
		as.fired,
		as.hit,
		as.friendly,
		as.blocked,
		as.missed
	)
)
local byType = {}
for _, r in battle.regiments do
	local t = byType[r.typeKey] or { lost = 0, men = 0, kills = 0 }
	t.lost += r.maxMen - r.alive
	t.men += r.maxMen
	t.kills += r.kills
	byType[r.typeKey] = t
end
for k, t in byType do
	print(string.format("  %-10s lost %3d/%3d  kills %3d", k, t.lost, t.men, t.kills))
end
print(string.format("tick cost avg %.2f ms, worst %.2f ms (budget 50 ms)", total / steps * 1000, worst * 1000))
local dur = math.max(battle.time, 1)
print(
	string.format(
		"bandwidth: snapshots %.1f KB/s (max %d bytes), volleys %.2f KB/s",
		sent.Snapshot / dur / 1024,
		sent.maxSnapshot,
		sent.Volley / dur / 1024
	)
)
