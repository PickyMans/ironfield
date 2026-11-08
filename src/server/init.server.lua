--[[
	Ironfield server bootstrap.
	Creates remotes, sets up the world and runs the fixed-rate battle simulation.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

Net.init()

local World = require(script.World)
local Battle = require(script.Battle)

Players.CharacterAutoLoads = false
World.setupLighting()

local battle = Battle.new()

Net.get("Command").OnServerEvent:Connect(function(player, cmd)
	local ok, err = pcall(battle.handleCommand, battle, player, cmd)
	if not ok then
		warn("[Ironfield] command error:", err)
	end
end)

Players.PlayerAdded:Connect(function(player)
	battle:assignPlayer(player)
end)
Players.PlayerRemoving:Connect(function(player)
	battle:removePlayer(player)
end)
for _, player in Players:GetPlayers() do
	battle:assignPlayer(player)
end

task.spawn(function()
	battle:startNew()
end)

-- Fixed timestep simulation
local STEP = 1 / Config.TICK_RATE
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator = math.min(accumulator + dt, STEP * 5)
	while accumulator >= STEP do
		accumulator -= STEP
		local ok, err = pcall(battle.step, battle, STEP)
		if not ok then
			warn("[Ironfield] simulation error:", err)
		end
	end
end)
