--[[
	AI
	A battlefield commander for teams with no human player.

	  * Infantry advance as a line, then pair off against enemy units.
	  * Archers pick targets that aren't tangled up with friendly troops and
	    fall back when enemy melee units close in.
	  * Cavalry hold the flanks, then hunt archers or charge engaged enemies in
	    the rear, pulling out and re-charging when a melee drags on.
	  * The general stays behind the line and only fights to defend itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Formation = require(Shared.Formation)

local States = Config.States

local AI = {}
AI.__index = AI

local THINK_INTERVAL = 1

function AI.new(battle, team: number)
	return setmetatable({
		battle = battle,
		team = team,
		timer = 2,
		cav = {},
		retreatAt = {},
	}, AI)
end

local function dist(ax, az, bx, bz): number
	local dx, dz = bx - ax, bz - az
	return math.sqrt(dx * dx + dz * dz)
end

local function centroidOf(list)
	local x, z = 0, 0
	for _, r in list do
		x += r.cx
		z += r.cz
	end
	local n = math.max(#list, 1)
	return x / n, z / n
end

local function engagedWithTeam(reg, team: number): boolean
	for other in reg.contact do
		if other.team == team then
			return true
		end
	end
	return false
end

local function planInput(r)
	return {
		id = r.id,
		def = r.def,
		alive = r.alive,
		x = r.ax,
		z = r.az,
		fx = r.fx,
		fz = r.fz,
		width = r.width,
	}
end

function AI:moveIfChanged(r, x, z, fx, fz, width, run)
	local d = r.dest
	if r.order.kind == "move" and d and dist(d.x, d.z, x, z) < 25 then
		return
	end
	if r.order.kind ~= "move" and dist(r.ax, r.az, x, z) < 6 then
		return
	end
	r:orderMove(x, z, fx, fz, width, run)
end

function AI:update(dt: number)
	self.timer -= dt
	if self.timer > 0 then
		return
	end
	self.timer = THINK_INTERVAL

	local battle = self.battle
	if battle.phase ~= "Battle" then
		return
	end
	local team = self.team
	local now = battle.time

	local mine, active, all = {}, {}, {}
	for _, r in battle.regiments do
		if r.alive > 0 and r.state ~= States.Dead then
			if r.team == team then
				if r:isActive() then
					table.insert(mine, r)
				end
			else
				table.insert(all, r)
				if not r:isBroken() then
					table.insert(active, r)
				end
			end
		end
	end
	if #mine == 0 or #all == 0 then
		return
	end
	local targets = #active > 0 and active or all

	local inf, rng, cav, gen = {}, {}, {}, nil
	for _, r in mine do
		if r.def.isGeneral then
			gen = r
		elseif r.def.ranged then
			table.insert(rng, r)
		elseif r.def.category == "cavalry" then
			table.insert(cav, r)
		else
			table.insert(inf, r)
		end
	end

	local ecx, ecz = centroidOf(targets)
	local core = #inf > 0 and inf or mine
	local icx, icz = centroidOf(core)
	local fx, fz, gap = Formation.normalize(ecx - icx, ecz - icz)
	local rx, rz = -fz, fx

	-- distance from our line to the closest enemy unit
	local closest = math.huge
	for _, e in targets do
		for _, r in core do
			closest = math.min(closest, dist(r.cx, r.cz, e.cx, e.cz))
		end
	end

	local anyEngaged = false
	for _, r in inf do
		if r.state == States.Melee then
			anyEngaged = true
		end
	end

	-- Infantry -----------------------------------------------------------
	if now >= 4 and #inf > 0 then
		if closest > 75 and not anyEngaged then
			local advance = math.min(gap - 65, 80)
			if advance > 8 then
				local cx, cz = icx + fx * advance, icz + fz * advance
				local length = 0
				for _, r in inf do
					length += math.min(r.def.defaultWidth, r.alive) * r.def.spacingX + 4
				end
				local inputs = {}
				for _, r in inf do
					table.insert(inputs, planInput(r))
				end
				local plans = Formation.planLine(
					inputs,
					cx - rx * length / 2,
					cz - rz * length / 2,
					cx + rx * length / 2,
					cz + rz * length / 2
				)
				for _, p in plans do
					local r = battle.byId[p.id]
					if r and r.state ~= States.Melee then
						self:moveIfChanged(r, p.x, p.z, p.fx, p.fz, p.width, false)
					end
				end
			end
		else
			local assigned = {}
			for _, r in inf do
				local t = r.order.target
				if r.order.kind == "attack" and t and t.alive > 0 and not t:isBroken() then
					assigned[t] = (assigned[t] or 0) + 1
				end
			end
			for _, r in inf do
				local t = r.order.target
				local needsTarget = r.state ~= States.Melee
					and (r.order.kind ~= "attack" or not t or t.alive <= 0 or t:isBroken())
				if needsTarget then
					local best, bestScore = nil, math.huge
					for _, e in targets do
						local score = dist(r.cx, r.cz, e.cx, e.cz) + (assigned[e] or 0) * 30
						if e.def.ranged then
							score -= 10
						end
						if score < bestScore then
							best, bestScore = e, score
						end
					end
					if best then
						assigned[best] = (assigned[best] or 0) + 1
						r:orderAttack(best, false)
					end
				end
			end
		end
	end

	-- Archers --------------------------------------------------------------
	for i, r in rng do
		if r.state ~= States.Melee then
			local threat, threatD = nil, math.huge
			for _, e in active do
				if not e.def.ranged then
					local d = dist(r.cx, r.cz, e.cx, e.cz)
					if d < threatD then
						threat, threatD = e, d
					end
				end
			end
			local lastRetreat = self.retreatAt[r] or -100
			if threat and threatD < 45 and now - lastRetreat > 8 and not engagedWithTeam(threat, team) then
				local bx, bz = Formation.normalize(r.cx - threat.cx, r.cz - threat.cz)
				self.retreatAt[r] = now
				r:orderMove(r.ax + bx * 55, r.az + bz * 55, -bx, -bz, r.width, true)
			elseif r.order.kind ~= "move" then
				local best, bestD = nil, math.huge
				for _, e in targets do
					if not engagedWithTeam(e, team) then
						local d = dist(r.cx, r.cz, e.cx, e.cz)
						if d < bestD then
							best, bestD = e, d
						end
					end
				end
				local range = r.def.ranged.range
				local current = r.order.kind == "attack" and r.order.target or nil
				if current and engagedWithTeam(current, team) then
					-- never keep shooting into a melee our own men are part of
					r:orderHalt()
				end
				if best and bestD < range * 1.4 and r.ammo > 0 then
					if r.order.target ~= best then
						r:orderAttack(best, false)
					end
				elseif r.order.kind ~= "attack" and now >= 4 then
					-- follow behind the infantry line
					local side = (i % 2 == 0) and 1 or -1
					local tx, tz = icx - fx * 28 + rx * side * 40, icz - fz * 28 + rz * side * 40
					self:moveIfChanged(r, tx, tz, fx, fz, r.width, false)
				end
			end
		end
	end

	-- Cavalry ------------------------------------------------------------
	for _, r in cav do
		local st = self.cav[r]
		if not st then
			st = { mode = "wait", untilT = 0 }
			self.cav[r] = st
		end
		if r.state == States.Melee then
			st.mode = "fight"
			local enemy = next(r.contact)
			local chasing = enemy and enemy:isBroken()
			if not chasing and now - r.meleeStart > 7 then
				-- pull out and charge again
				if enemy then
					local bx, bz = Formation.normalize(r.cx - enemy.cx, r.cz - enemy.cz)
					r:orderMove(r.cx + bx * 70, r.cz + bz * 70, -bx, -bz, r.width, true)
					st.mode = "regroup"
					st.untilT = now + 7
				end
			end
		elseif st.mode == "regroup" and now < st.untilT then
			continue
		elseif now < 18 then
			local side = (r.cx - icx) * rx + (r.cz - icz) * rz >= 0 and 1 or -1
			local tx, tz = icx + rx * side * 150 + fx * 15, icz + rz * side * 150 + fz * 15
			self:moveIfChanged(r, tx, tz, fx, fz, r.width, false)
		else
			-- pick a victim: archers, then engaged units (rear charge), then the routing
			local best, bestScore = nil, math.huge
			for _, e in all do
				local d = dist(r.cx, r.cz, e.cx, e.cz)
				local score = d
				if e:isBroken() then
					score += 120
				elseif e.def.ranged then
					score -= 80
				elseif next(e.contact) ~= nil then
					score -= 50
				elseif e.def.bonusVsLarge > 0 then
					score += 150
				end
				if score < bestScore then
					best, bestScore = e, score
				end
			end
			if best then
				local engaged = next(best.contact) ~= nil and not best:isBroken()
				if engaged then
					-- swing round behind it first
					local depth = best:depth()
					local rearX, rearZ = best.ax - best.fx * (depth + 35), best.az - best.fz * (depth + 35)
					if dist(r.cx, r.cz, rearX, rearZ) > 30 and dist(r.cx, r.cz, best.cx, best.cz) > 45 then
						self:moveIfChanged(r, rearX, rearZ, best.fx, best.fz, r.width, true)
					elseif r.order.target ~= best then
						r:orderAttack(best, true)
					end
				elseif r.order.target ~= best then
					r:orderAttack(best, true)
				end
				st.mode = "attack"
			end
		end
	end

	-- General --------------------------------------------------------------
	if gen and gen.state ~= States.Melee then
		local threat, threatD = battle:nearestEnemyRegiment(gen, gen.cx, gen.cz, true)
		if threat and threatD < 45 and gen.morale > 40 then
			if gen.order.target ~= threat then
				gen:orderAttack(threat, true)
			end
		elseif now >= 4 then
			local tx, tz = icx - fx * 50, icz - fz * 50
			if dist(gen.cx, gen.cz, tx, tz) > 25 then
				self:moveIfChanged(gen, tx, tz, fx, fz, gen.width, false)
			end
		end
	end
end

return AI
