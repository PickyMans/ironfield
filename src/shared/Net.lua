--[[
	Net
	Creates (server) or fetches (client) the RemoteEvents used by the game.

	Server -> Client
	  Snapshot      buffer   regiment headers + changed soldier positions (10 Hz)
	  Volley        buffer   arrows fired this tick (visual only)
	  RegimentInfo  table    static info about regiments (type, team, size)
	  BattleState   table    phase, seed, teams, winner, stats
	  Notify        table    toast messages
	Client -> Server
	  Command       table    player orders
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

local NAMES = { "Snapshot", "Volley", "RegimentInfo", "BattleState", "Notify", "Command" }
local FOLDER_NAME = "IronfieldNet"

local remotes = {}

function Net.init()
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		for _, name in NAMES do
			local r = folder:FindFirstChild(name)
			if not r then
				r = Instance.new("RemoteEvent")
				r.Name = name
				r.Parent = folder
			end
			remotes[name] = r
		end
	else
		local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
		for _, name in NAMES do
			remotes[name] = folder:WaitForChild(name)
		end
	end
end

function Net.get(name: string): RemoteEvent
	local r = remotes[name]
	assert(r, "Net not initialised or unknown remote: " .. tostring(name))
	return r
end

return Net
