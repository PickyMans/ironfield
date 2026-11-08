--[[
	State
	Client-side mirror of the battle. Filled by the network handlers in
	init.client and read by the renderer, input and UI modules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local State = {}

State.battleId = -1
State.phase = "Loading"
State.seed = 0
State.myTeam = 0
State.battle = nil -- last BattleState table from the server

-- id -> regiment { id, team, type, def, men, alive, morale, state, ammo, flags,
--                  ax, az, facing, width, cx, cz, soldiers = { [i] = soldier } }
State.regs = {}
State.order = {} -- regiment ids in spawn order

State.selected = {} -- id -> true
State.hovered = nil -- id

local function signal()
	return Instance.new("BindableEvent")
end

State.SelectionChanged = signal()
State.RegimentsReset = signal()
State.BattleChanged = signal()
State.Notified = signal()

function State.reg(id: number)
	return State.regs[id]
end

function State.isMine(reg): boolean
	return reg ~= nil and reg.team == State.myTeam
end

function State.isActive(reg): boolean
	return reg.alive > 0
		and reg.state ~= Config.States.Dead
		and reg.state ~= Config.States.Routing
		and reg.state ~= Config.States.Shattered
end

function State.selectedList()
	local list = {}
	for _, id in State.order do
		if State.selected[id] then
			local r = State.regs[id]
			if r and State.isActive(r) and State.isMine(r) then
				table.insert(list, r)
			end
		end
	end
	return list
end

function State.myRegiments()
	local list = {}
	for _, id in State.order do
		local r = State.regs[id]
		if r and r.team == State.myTeam then
			table.insert(list, r)
		end
	end
	return list
end

function State.setSelection(ids, additive: boolean?)
	if not additive then
		table.clear(State.selected)
	end
	for _, id in ids do
		local r = State.regs[id]
		if r and State.isMine(r) and State.isActive(r) then
			State.selected[id] = true
		end
	end
	State.SelectionChanged:Fire()
end

function State.toggleSelected(id: number)
	if State.selected[id] then
		State.selected[id] = nil
	else
		local r = State.regs[id]
		if r and State.isMine(r) and State.isActive(r) then
			State.selected[id] = true
		end
	end
	State.SelectionChanged:Fire()
end

function State.clearSelection()
	table.clear(State.selected)
	State.SelectionChanged:Fire()
end

-- Drop units that can no longer be commanded from the selection.
function State.pruneSelection()
	local changed = false
	for id in State.selected do
		local r = State.regs[id]
		if not r or not State.isActive(r) then
			State.selected[id] = nil
			changed = true
		end
	end
	if changed then
		State.SelectionChanged:Fire()
	end
end

return State
