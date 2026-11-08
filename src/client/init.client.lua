--[[
	Ironfield client bootstrap.
	Wires network events into the client state, renderer, effects and UI,
	and drives everything from a single RenderStepped loop.
]]

local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Net = require(Shared.Net)
local Heightmap = require(Shared.Heightmap)

Net.init()

local State = require(script.State)
local Renderer = require(script.Renderer)
local Projectiles = require(script.Projectiles)
local CameraController = require(script.CameraController)
local Commander = require(script.Commander)
local UI = require(script.UI)

-- hide default Roblox HUD bits that don't make sense in an RTS
task.spawn(function()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)
		end)
		if ok then
			break
		end
		task.wait(0.5)
	end
end)

local camera = workspace.CurrentCamera

CameraController.init()
local gui = UI.init()
Commander.init(gui)
Renderer.reset()
Projectiles.reset()

local lastSync = -10
local function requestSync()
	local now = os.clock()
	if now - lastSync > 1.5 then
		lastSync = now
		Net.get("Command"):FireServer({ kind = "sync" })
	end
end

local function placeCamera()
	local team = Config.Teams[State.myTeam]
	if team then
		local z = team.frontZ - team.facingZ * 30
		local yaw = team.facingZ < 0 and 0 or math.pi
		CameraController.setView(0, z, yaw, 180, true)
	else
		CameraController.setView(0, 0, math.pi / 2, 320, true)
	end
end

local cameraPlacedFor = nil

Net.get("BattleState").OnClientEvent:Connect(function(b)
	local prevTeam = State.myTeam
	State.battle = b
	State.phase = b.phase
	State.myTeam = b.yourTeam or 0
	State.seed = b.seed
	Heightmap.setSeed(b.seed)

	if prevTeam ~= State.myTeam then
		table.clear(State.selected)
		State.RegimentsReset:Fire()
	end

	if b.phase == "Deployment" then
		Commander.showDeployZone(State.myTeam)
	else
		Commander.showDeployZone(nil)
	end

	-- frame the army once per battle (and again if we switch sides)
	local key = tostring(b.battleId) .. ":" .. tostring(State.myTeam)
	if b.phase ~= "Loading" and cameraPlacedFor ~= key then
		cameraPlacedFor = key
		placeCamera()
	end

	UI.onBattleState(b)
	State.BattleChanged:Fire(b)
end)

Net.get("RegimentInfo").OnClientEvent:Connect(function(info)
	if info.battleId ~= State.battleId then
		Projectiles.reset()
	end
	Renderer.applyRegimentInfo(info)
end)

Net.get("Snapshot").OnClientEvent:Connect(function(buf)
	local regs = Codec.decodeSnapshot(buf)
	if not Renderer.applySnapshot(regs, os.clock()) then
		requestSync()
	end
end)

Net.get("Volley").OnClientEvent:Connect(function(buf)
	Projectiles.spawnVolley(Codec.decodeVolley(buf), os.clock())
end)

Net.get("Notify").OnClientEvent:Connect(function(data)
	State.Notified:Fire(data)
end)

RunService.RenderStepped:Connect(function(dt)
	local now = os.clock()
	CameraController.update(dt)
	Commander.update(dt)
	Renderer.update(dt, now, camera.CFrame.Position)
	Projectiles.update(now)
	UI.update(dt, now)
end)

requestSync()
