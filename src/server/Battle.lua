--[[
	Battle
	Owns the battle lifecycle (Loading -> Deployment -> Battle -> Ended),
	the regiments, the per-tick simulation, replication and player commands.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Formation = require(Shared.Formation)
local Codec = require(Shared.Codec)
local Net = require(Shared.Net)
local Heightmap = require(Shared.Heightmap)

local Regiment = require(script.Parent.Regiment)
local Combat = require(script.Parent.Combat)
local SpatialHash = require(script.Parent.SpatialHash)
local AI = require(script.Parent.AI)
local World = require(script.Parent.World)

local States = Config.States

local Battle = {}
Battle.__index = Battle

local function isFiniteNumber(v): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Battle.new()
	local self = setmetatable({}, Battle)
	self.regiments = {}
	self.byId = {}
	self.nextId = 1
	self.time = 0
	self.phase = "Loading"
	self.winner = 0
	self.battleId = 0
	self.seed = 0
	self.hash = SpatialHash.new(8)
	self.queryBuf = {}
	self.generals = {}
	self.generalDead = {}
	self.losses = { 0, 0 }
	self.fled = { 0, 0 }
	self.startMen = { 0, 0 }
	self.controllers = {} -- [team] = Player
	self.ready = { false, false }
	self.ais = {}
	self.tickCount = 0
	self.moraleTimer = 0
	self.victoryTimer = 0
	self.commandBudget = {}
	self.updateOrder = {}
	return self
end

-- Teams & players ----------------------------------------------------------

function Battle:teamOf(player: Player): number
	for team = 1, 2 do
		if self.controllers[team] == player then
			return team
		end
	end
	return 0
end

function Battle:assignPlayer(player: Player)
	for team = 1, 2 do
		if self.controllers[team] == nil then
			self.controllers[team] = player
			self.ready[team] = false
			break
		end
	end
	self:broadcastState()
end

function Battle:removePlayer(player: Player)
	for team = 1, 2 do
		if self.controllers[team] == player then
			self.controllers[team] = nil
			self.ready[team] = false
			-- a waiting spectator takes over, otherwise the AI does
			for _, p in Players:GetPlayers() do
				if p ~= player and self:teamOf(p) == 0 then
					self.controllers[team] = p
					break
				end
			end
		end
	end
	self.commandBudget[player] = nil
	self:broadcastState()
	self:checkAllReady()
end

-- Lifecycle ----------------------------------------------------------------

function Battle:clear()
	for _, r in self.regiments do
		r.dead = true
	end
	self.regiments = {}
	self.byId = {}
	self.nextId = 1
	self.generals = {}
	self.generalDead = {}
	Combat.reset()
end

function Battle:spawnArmy(team: number)
	local t = Config.Teams[team]
	local fz = t.facingZ
	local fx = 0
	local sideSign = -fz -- army-local +x is the army's right
	for _, slot in Config.Army do
		local x = slot.x * sideSign
		local z = t.frontZ - fz * slot.depth
		local reg = Regiment.new(self, self.nextId, team, slot.type, x, z, fx, fz)
		self.nextId += 1
		table.insert(self.regiments, reg)
		self.byId[reg.id] = reg
		if reg.def.isGeneral then
			self.generals[team] = reg
		end
		self.startMen[team] += reg.maxMen
	end
end

function Battle:startNew()
	self.phase = "Loading"
	self:broadcastState()
	self:clear()

	self.battleId += 1
	self.seed = math.random(1, 99999)
	Heightmap.setSeed(self.seed)
	World.build(self.seed)

	self.time = 0
	self.winner = 0
	self.losses = { 0, 0 }
	self.fled = { 0, 0 }
	self.startMen = { 0, 0 }
	self.ready = { false, false }
	self.ais = { AI.new(self, 1), AI.new(self, 2) }

	self:spawnArmy(1)
	self:spawnArmy(2)
	for _, r in self.regiments do
		r:computeCentroid()
	end

	self.phase = "Deployment"
	self:broadcastState()
	self:broadcastRegimentInfo()
	self:notify("Deploy your army, then press Start Battle.", nil, "info")
end

function Battle:checkAllReady()
	if self.phase ~= "Deployment" then
		return
	end
	local anyHuman = false
	for team = 1, 2 do
		if self.controllers[team] then
			anyHuman = true
			if not self.ready[team] then
				return
			end
		end
	end
	if anyHuman then
		self:beginBattle()
	end
end

function Battle:beginBattle()
	self.phase = "Battle"
	self.time = 0
	self:broadcastState()
	self:notify("The battle has begun!", nil, "info")
end

function Battle:endBattle(winner: number)
	self.phase = "Ended"
	self.winner = winner
	self:broadcastState()
end

-- Simulation helpers -------------------------------------------------------

function Battle:notify(text: string, team: number?, kind: string?)
	local remote = Net.get("Notify")
	remote:FireAllClients({ text = text, team = team or 0, kind = kind or "info" })
end

function Battle:killSoldier(s, attackerReg)
	if not s.alive then
		return
	end
	s.alive = false
	s.hp = 0
	s.target = nil
	local r = s.reg
	r.alive -= 1
	r.recentLosses += 1
	r.slotsDirty = true
	self.losses[r.team] += 1
	if attackerReg and attackerReg.team ~= r.team then
		attackerReg.kills += 1
	end
	if r.alive <= 0 then
		r.state = States.Dead
		self:notify(r.def.displayName .. " have been wiped out!", r.team, "bad")
		if r.def.isGeneral then
			self:onGeneralDeath(r.team)
		end
	end
end

function Battle:escapeSoldier(s)
	if not s.alive then
		return
	end
	s.alive = false
	s.escaped = true
	s.target = nil
	local r = s.reg
	r.alive -= 1
	self.fled[r.team] += 1
	if r.alive <= 0 then
		r.state = States.Dead
		if r.def.isGeneral then
			self:onGeneralDeath(r.team)
		end
	end
end

function Battle:onGeneralDeath(team: number)
	if self.generalDead[team] then
		return
	end
	self.generalDead[team] = true
	for _, r in self.regiments do
		if r.team == team and r.alive > 0 then
			r.recentLosses += r.maxMen * 0.15
		end
	end
	self:notify(Config.Teams[team].name .. "'s general has fallen!", team, "bad")
end

function Battle:nearestEnemyRegiment(reg, x: number, z: number, activeOnly: boolean?)
	local best, bestD2 = nil, math.huge
	for _, r in self.regiments do
		if r.team ~= reg.team and r.alive > 0 and r.state ~= States.Dead then
			if not activeOnly or not r:isBroken() then
				local dx, dz = r.cx - x, r.cz - z
				local d2 = dx * dx + dz * dz
				if d2 < bestD2 then
					best, bestD2 = r, d2
				end
			end
		end
	end
	return best, math.sqrt(bestD2)
end

function Battle:findEnemySoldier(s, radius: number)
	local buf = self.queryBuf
	local n = self.hash:query(s.x, s.z, radius, buf)
	local best, bestD2 = nil, radius * radius
	local team = s.reg.team
	for i = 1, n do
		local o = buf[i]
		if o.alive and o.reg.team ~= team then
			local dx, dz = o.ox - s.ox, o.oz - s.oz
			-- a little noise spreads attackers over several enemies
			local d2 = dx * dx + dz * dz + math.random() * 2
			if d2 < bestD2 then
				best, bestD2 = o, d2
			end
		end
	end
	return best
end

-- Pushes soldiers apart and detects which regiments are touching enemies.
function Battle:computeSeparation()
	local hash = self.hash
	local buf = self.queryBuf
	local R = Config.CONTACT_RADIUS
	local R2 = R * R
	local now = self.time
	for _, r in self.regiments do
		if r.alive > 0 then
			local rDef = r.def
			local rLarge = rDef.isLarge
			local team = r.team
			local charging = r.chargeUntil > now
			for _, s in r.soldiers do
				if s.alive then
					local n = hash:query(s.x, s.z, R, buf)
					local px, pz = 0, 0
					for i = 1, n do
						local o = buf[i]
						if o ~= s and o.alive then
							local dx, dz = s.x - o.x, s.z - o.z
							local d2 = dx * dx + dz * dz
							local oReg = o.reg
							local enemy = oReg.team ~= team
							if enemy and d2 < R2 then
								r.contact[oReg] = true
								if charging and s.impactsLeft > 0 and d2 < 6.5 then
									s.impactsLeft -= 1
									Combat.chargeImpact(self, s, o)
									if not s.alive then
										break
									end
								end
							end
							local large = rLarge or oReg.def.isLarge
							local minD
							if enemy then
								minD = large and 2.6 or 1.5
							else
								minD = large and 2.3 or 1.15
							end
							if d2 < minD * minD and o.alive then
								if d2 < 1e-4 then
									dx, dz = math.random() - 0.5, math.random() - 0.5
									d2 = dx * dx + dz * dz + 1e-6
								end
								local d = math.sqrt(d2)
								local w = oReg.def.mass / (rDef.mass + oReg.def.mass)
								local push = (minD - d) * w
								px += dx / d * push
								pz += dz / d * push
							end
						end
					end
					local m = math.sqrt(px * px + pz * pz)
					local cap = 0.6
					if m > cap then
						px, pz = px / m * cap, pz / m * cap
					end
					s.px, s.pz = px * 0.5, pz * 0.5
				end
			end
		end
	end
end

function Battle:checkVictory()
	local activeCount = { 0, 0 }
	for _, r in self.regiments do
		if r:isActive() then
			activeCount[r.team] += 1
		end
	end
	if activeCount[1] == 0 or activeCount[2] == 0 then
		local winner = 0
		if activeCount[1] > 0 then
			winner = 1
		elseif activeCount[2] > 0 then
			winner = 2
		end
		self:endBattle(winner)
	end
end

function Battle:simulate(dt: number)
	local hash = self.hash
	hash:clear()
	for _, r in self.regiments do
		table.clear(r.contact)
		if r.alive > 0 then
			r:computeCentroid()
			for _, s in r.soldiers do
				if s.alive then
					-- start-of-tick position: everyone reacts to the same picture of the field
					s.ox, s.oz = s.x, s.z
					hash:insert(s, s.x, s.z)
				end
			end
		end
	end

	self:computeSeparation()

	-- process regiments in a random order so neither army systematically acts first
	local order = self.updateOrder
	table.clear(order)
	for i, r in self.regiments do
		order[i] = r
	end
	for i = #order, 2, -1 do
		local j = math.random(1, i)
		order[i], order[j] = order[j], order[i]
	end

	for _, r in order do
		r:update(dt)
	end
	for _, r in order do
		r:updateSoldiers(dt)
	end

	Combat.update(self)

	self.moraleTimer += dt
	if self.moraleTimer >= 0.5 then
		for _, r in self.regiments do
			r:updateMorale(self.moraleTimer)
		end
		self.moraleTimer = 0
	end

	for team, ai in self.ais do
		if self.controllers[team] == nil then
			ai:update(dt)
		end
	end

	self.victoryTimer += dt
	if self.victoryTimer >= 1 then
		self.victoryTimer = 0
		self:checkVictory()
	end
end

function Battle:step(dt: number)
	if self.phase == "Battle" then
		self.time += dt
		self:simulate(dt)
	end
	local fired = Combat.takeFired()
	if fired then
		Net.get("Volley"):FireAllClients(Codec.encodeVolley(fired))
	end
	self.tickCount += 1
	if self.phase ~= "Loading" and self.tickCount % Config.SNAPSHOT_EVERY == 0 then
		self:broadcastSnapshot()
	end
end

-- Replication --------------------------------------------------------------

local function soldierFlags(s): number
	local f = 0
	if s.alive then
		f += Codec.SF_ALIVE
	end
	f += bit32.lshift(s.attackCount % 4, 1)
	if s.escaped then
		f += Codec.SF_ESCAPED
	end
	if s.inMelee then
		f += Codec.SF_MELEE
	end
	return f
end

local function angleDiff(a: number, b: number): number
	return math.abs((a - b + math.pi) % (math.pi * 2) - math.pi)
end

function Battle:regHeader(r, entries)
	local flags = 0
	if r.running or r.orderRun then
		flags += Codec.RF_RUNNING
	end
	if r.fireAtWill then
		flags += Codec.RF_FIRE_AT_WILL
	end
	if r.charging or r.chargeUntil > self.time then
		flags += Codec.RF_CHARGING
	end
	local ammo = 255
	if r.maxAmmo > 0 then
		ammo = math.floor(r.ammo / r.maxAmmo * 254 + 0.5)
	end
	return {
		id = r.id,
		alive = r.alive,
		morale = r.morale,
		state = r.state,
		ammo = ammo,
		flags = flags,
		ax = r.ax,
		az = r.az,
		facing = Formation.angleOf(r.fx, r.fz),
		width = r.width,
		entries = entries,
	}
end

function Battle:broadcastSnapshot()
	local list = {}
	for _, r in self.regiments do
		local entries = {}
		for _, s in r.soldiers do
			local fl = soldierFlags(s)
			if
				s.sx == nil
				or fl ~= s.sfl
				or math.abs(s.x - s.sx) > 0.08
				or math.abs(s.z - s.sz) > 0.08
				or angleDiff(s.facing, s.sf) > 0.05
			then
				s.flags = fl
				s.sx, s.sz, s.sf, s.sfl = s.x, s.z, s.facing, fl
				entries[#entries + 1] = s
			end
		end
		list[#list + 1] = self:regHeader(r, entries)
	end
	Net.get("Snapshot"):FireAllClients(Codec.encodeSnapshot(list))
end

function Battle:fullSnapshot()
	local list = {}
	for _, r in self.regiments do
		local entries = {}
		for _, s in r.soldiers do
			s.flags = soldierFlags(s)
			entries[#entries + 1] = s
		end
		list[#list + 1] = self:regHeader(r, entries)
	end
	return Codec.encodeSnapshot(list)
end

function Battle:regimentInfo()
	local regs = {}
	for _, r in self.regiments do
		table.insert(regs, {
			id = r.id,
			team = r.team,
			type = r.typeKey,
			men = r.maxMen,
		})
	end
	return { battleId = self.battleId, regs = regs }
end

function Battle:broadcastRegimentInfo()
	Net.get("RegimentInfo"):FireAllClients(self:regimentInfo())
end

function Battle:stateFor(player: Player)
	local names = {}
	for team = 1, 2 do
		local c = self.controllers[team]
		names[team] = c and c.DisplayName or "AI"
	end
	local kills = { 0, 0 }
	for _, r in self.regiments do
		kills[r.team] += r.kills
	end
	return {
		battleId = self.battleId,
		phase = self.phase,
		seed = self.seed,
		yourTeam = self:teamOf(player),
		controllers = names,
		ready = { self.ready[1], self.ready[2] },
		time = self.time,
		winner = self.winner,
		losses = { self.losses[1], self.losses[2] },
		fled = { self.fled[1], self.fled[2] },
		kills = kills,
		startMen = { self.startMen[1], self.startMen[2] },
	}
end

function Battle:broadcastState()
	local remote = Net.get("BattleState")
	for _, p in Players:GetPlayers() do
		remote:FireClient(p, self:stateFor(p))
	end
end

function Battle:syncPlayer(player: Player)
	Net.get("BattleState"):FireClient(player, self:stateFor(player))
	if self.phase ~= "Loading" then
		Net.get("RegimentInfo"):FireClient(player, self:regimentInfo())
		Net.get("Snapshot"):FireClient(player, self:fullSnapshot())
	end
end

-- Commands -----------------------------------------------------------------

function Battle:ownRegiment(team: number, id)
	if type(id) ~= "number" then
		return nil
	end
	local r = self.byId[id]
	if r and r.team == team and r:isActive() then
		return r
	end
	return nil
end

function Battle:clampToDeployZone(team: number, x: number, z: number): (number, number)
	local t = Config.Teams[team]
	local hw = Config.DEPLOY_HALF_WIDTH
	return math.clamp(x, -hw, hw), math.clamp(z, t.deployZ[1], t.deployZ[2])
end

function Battle:applyMoveOrders(team: number, orders, run: boolean)
	if type(orders) ~= "table" then
		return
	end
	local limit = Config.PLAY_HALF
	for i, o in orders do
		if i > 40 then
			break
		end
		if type(o) == "table" then
			local r = self:ownRegiment(team, o.id)
			if
				r
				and isFiniteNumber(o.x)
				and isFiniteNumber(o.z)
				and isFiniteNumber(o.fx)
				and isFiniteNumber(o.fz)
				and isFiniteNumber(o.width)
			then
				local fx, fz, m = Formation.normalize(o.fx, o.fz)
				if m < 1e-3 then
					fx, fz = r.fx, r.fz
				end
				local x, z = math.clamp(o.x, -limit, limit), math.clamp(o.z, -limit, limit)
				if self.phase == "Deployment" then
					x, z = self:clampToDeployZone(team, x, z)
					r:teleport(x, z, fx, fz, o.width)
				elseif self.phase == "Battle" then
					r:orderMove(x, z, fx, fz, o.width, run)
				end
			end
		end
	end
end

function Battle:forEachOwn(team: number, ids, fn)
	if type(ids) ~= "table" then
		return
	end
	for i, id in ids do
		if i > 40 then
			break
		end
		local r = self:ownRegiment(team, id)
		if r then
			fn(r)
		end
	end
end

function Battle:handleCommand(player: Player, cmd)
	if type(cmd) ~= "table" or type(cmd.kind) ~= "string" then
		return
	end

	-- simple rate limit: 30 commands per second burst
	local now = os.clock()
	local budget = self.commandBudget[player]
	if not budget then
		budget = { tokens = 30, last = now }
		self.commandBudget[player] = budget
	end
	budget.tokens = math.min(30, budget.tokens + (now - budget.last) * 15)
	budget.last = now
	if budget.tokens < 1 then
		return
	end
	budget.tokens -= 1

	local kind = cmd.kind
	if kind == "sync" then
		self:syncPlayer(player)
		return
	end

	local team = self:teamOf(player)
	if team == 0 then
		return
	end

	if kind == "ready" then
		if self.phase == "Deployment" then
			self.ready[team] = true
			self:broadcastState()
			self:checkAllReady()
		end
	elseif kind == "newBattle" then
		if self.phase == "Ended" then
			task.spawn(function()
				self:startNew()
			end)
		end
	elseif kind == "surrender" then
		if self.phase == "Battle" then
			self:endBattle(team == 1 and 2 or 1)
		end
	elseif self.phase == "Deployment" or self.phase == "Battle" then
		if kind == "move" then
			self:applyMoveOrders(team, cmd.orders, cmd.run == true)
		elseif self.phase == "Battle" then
			if kind == "attack" then
				local target = type(cmd.target) == "number" and self.byId[cmd.target] or nil
				if target and target.team ~= team and target.alive > 0 then
					self:forEachOwn(team, cmd.ids, function(r)
						r:orderAttack(target, cmd.run == true)
					end)
				end
			elseif kind == "halt" then
				self:forEachOwn(team, cmd.ids, function(r)
					r:orderHalt()
				end)
			end
		end
		if kind == "run" then
			self:forEachOwn(team, cmd.ids, function(r)
				r:setRunning(cmd.value == true)
			end)
		elseif kind == "fireAtWill" then
			self:forEachOwn(team, cmd.ids, function(r)
				r:setFireAtWill(cmd.value == true)
			end)
		end
	end
end

return Battle
