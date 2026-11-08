--[[
	Regiment
	A block of soldiers that moves and fights as one unit.

	The regiment owns a formation "anchor" (centre of the front rank), a facing
	and a width (files). Every soldier has a slot in that formation and walks
	towards it, unless it is busy fighting an enemy soldier in melee.

	Regiment states: Idle, Moving, Melee, Firing, Routing, Shattered, Dead
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Formation = require(Shared.Formation)

local Combat = require(script.Parent.Combat)

local States = Config.States
local TAU = math.pi * 2

local Regiment = {}
Regiment.__index = Regiment

local function turnTowards(cur: number, target: number, maxStep: number): number
	local d = (target - cur + math.pi) % TAU - math.pi
	if d > maxStep then
		d = maxStep
	elseif d < -maxStep then
		d = -maxStep
	end
	return cur + d
end

local function angleBetween(ax, az, bx, bz): number
	local dot = math.clamp(ax * bx + az * bz, -1, 1)
	return math.acos(dot)
end

function Regiment.new(battle, id: number, team: number, typeKey: string, ax: number, az: number, fx: number, fz: number)
	local def = Config.UnitTypes[typeKey]
	assert(def, "Unknown unit type " .. tostring(typeKey))

	local self = setmetatable({}, Regiment)
	self.battle = battle
	self.id = id
	self.team = team
	self.typeKey = typeKey
	self.def = def
	self.maxMen = def.men
	self.alive = def.men

	self.ax, self.az = ax, az
	self.fx, self.fz = fx, fz
	self.width = Formation.defaultWidth(def, def.men)

	self.order = { kind = "idle" }
	self.state = States.Idle
	self.movePhase = nil
	self.dest = nil
	self.running = false
	self.orderRun = false
	self.charging = false
	self.fireAtWill = def.ranged ~= nil
	self.fireTarget = nil
	self.fireSearch = 0
	self.ammo = def.ranged and def.ranged.ammo * def.men or 0
	self.maxAmmo = self.ammo

	self.morale = def.morale
	self.rallyBonus = 0
	self.routCount = 0
	self.calmTime = 0
	self.recentLosses = 0
	self.rearHitTime = -100
	self.sideHitTime = -100
	self.underFireTime = -100

	self.contact = {}
	self.lastContact = -100
	self.meleeStart = 0
	self.anyTarget = false
	self.chargeUntil = -100
	self.speedAvg = 0

	self.kills = 0
	self.slotError = 0
	self.slotsDirty = false
	self.lastReassign = 0
	self.formStart = 0

	self.cx, self.cz = ax, az
	self.radius = 10

	self.soldiers = {}
	local facing = Formation.angleOf(fx, fz)
	for i = 1, def.men do
		local sx, sz = Formation.slotWorld(ax, az, fx, fz, i, def.men, self.width, def.spacingX, def.spacingZ)
		self.soldiers[i] = {
			reg = self,
			index = i,
			slot = i,
			x = sx + (math.random() - 0.5) * 0.3,
			z = sz + (math.random() - 0.5) * 0.3,
			facing = facing,
			vx = 0,
			vz = 0,
			px = 0,
			pz = 0,
			kx = 0,
			kz = 0,
			jx = 0,
			jz = 0,
			hp = def.hp,
			alive = true,
			escaped = false,
			ox = sx,
			oz = sz,
			target = nil,
			retarget = math.random() * 0.4,
			cd = math.random() * def.attackInterval,
			reload = math.random() * (def.ranged and def.ranged.reload or 1),
			attackCount = 0,
			inMelee = false,
			impactsLeft = 0,
			stunUntil = 0,
			flags = 1,
		}
	end
	return self
end

-- Queries ------------------------------------------------------------------

function Regiment:isBroken(): boolean
	return self.state == States.Routing or self.state == States.Shattered
end

function Regiment:isActive(): boolean
	return self.alive > 0 and self.state ~= States.Dead and not self:isBroken()
end

function Regiment:speed(): number
	local def = self.def
	if self:isBroken() then
		return def.runSpeed
	end
	if self.running or self.orderRun or self.charging then
		return def.runSpeed
	end
	return def.walkSpeed
end

function Regiment:depth(): number
	return Formation.depth(math.max(self.alive, 1), math.max(self.width, 1), self.def.spacingZ)
end

function Regiment:randomAliveSoldier()
	if self.alive <= 0 then
		return nil
	end
	local soldiers = self.soldiers
	for _ = 1, 8 do
		local s = soldiers[math.random(1, #soldiers)]
		if s.alive then
			return s
		end
	end
	for _, s in soldiers do
		if s.alive then
			return s
		end
	end
	return nil
end

function Regiment:computeCentroid()
	local sx, sz, n = 0, 0, 0
	for _, s in self.soldiers do
		if s.alive then
			sx += s.x
			sz += s.z
			n += 1
		end
	end
	if n == 0 then
		return
	end
	self.cx, self.cz = sx / n, sz / n
	local r2 = 0
	for _, s in self.soldiers do
		if s.alive then
			local dx, dz = s.x - self.cx, s.z - self.cz
			local d2 = dx * dx + dz * dz
			if d2 > r2 then
				r2 = d2
			end
		end
	end
	self.radius = math.sqrt(r2)
end

function Regiment:aliveList()
	local list = {}
	for _, s in self.soldiers do
		if s.alive then
			list[#list + 1] = s
		end
	end
	return list
end

-- Formation ----------------------------------------------------------------

function Regiment:reassignSlots()
	self.width = Formation.clampWidth(self.def, self.alive, self.width)
	Formation.assignSlots(self:aliveList(), self.fx, self.fz, self.width)
	self.slotsDirty = false
	self.lastReassign = self.battle.time
end

function Regiment:setFormation(ax, az, fx, fz, width, reassign: boolean?)
	self.ax, self.az = ax, az
	self.fx, self.fz = fx, fz
	self.width = Formation.clampWidth(self.def, self.alive, width or self.width)
	if reassign then
		self:reassignSlots()
	end
end

-- Re-form in place around the current centroid, facing (fx, fz).
function Regiment:reformAt(fx, fz, width)
	width = Formation.clampWidth(self.def, self.alive, width or self.width)
	local depth = Formation.depth(self.alive, width, self.def.spacingZ)
	self:setFormation(self.cx + fx * depth / 2, self.cz + fz * depth / 2, fx, fz, width, true)
end

-- Turn the block to face a direction if it is noticeably off.
function Regiment:faceTowards(dx, dz, threshold)
	local fx, fz, m = Formation.normalize(dx, dz)
	if m < 1e-3 then
		return
	end
	if angleBetween(self.fx, self.fz, fx, fz) > (threshold or math.rad(25)) then
		self:reformAt(fx, fz)
	end
end

-- Teleport into formation (used during deployment).
function Regiment:teleport(ax, az, fx, fz, width)
	self:setFormation(ax, az, fx, fz, width, true)
	local def = self.def
	local facing = Formation.angleOf(fx, fz)
	for _, s in self.soldiers do
		if s.alive then
			s.x, s.z = Formation.slotWorld(ax, az, fx, fz, s.slot, self.alive, self.width, def.spacingX, def.spacingZ)
			s.facing = facing
			s.vx, s.vz = 0, 0
		end
	end
	self:computeCentroid()
end

-- Orders -------------------------------------------------------------------

function Regiment:clearCombatOrders()
	self.fireTarget = nil
	self.charging = false
	for _, s in self.soldiers do
		s.target = nil
	end
end

function Regiment:orderMove(x, z, fx, fz, width, run: boolean?)
	if not self:isActive() then
		return
	end
	self:clearCombatOrders()
	self.order = { kind = "move" }
	self.orderRun = run == true
	width = Formation.clampWidth(self.def, self.alive, width or self.width)
	self.dest = { x = x, z = z, fx = fx, fz = fz, width = width }
	self.state = States.Moving

	local dx, dz, dist = Formation.normalize(x - self.cx, z - self.cz)
	if dist > 22 then
		-- march: form a block facing the direction of travel, centred on where we are now
		self.movePhase = "march"
		local depth = Formation.depth(self.alive, width, self.def.spacingZ)
		local needReassign = angleBetween(self.fx, self.fz, dx, dz) > math.rad(8) or width ~= self.width
		self:setFormation(self.cx + dx * depth / 2, self.cz + dz * depth / 2, dx, dz, width, needReassign)
	else
		self.movePhase = "form"
		self.formStart = self.battle.time
		self:setFormation(x, z, fx, fz, width, true)
	end
end

function Regiment:orderAttack(target, run: boolean?)
	if not self:isActive() or not target or target.team == self.team or target.alive <= 0 then
		return
	end
	self:clearCombatOrders()
	self.order = { kind = "attack", target = target }
	self.orderRun = run == true
	self.dest = nil
	self.movePhase = nil
	if self.state ~= States.Melee then
		self.state = States.Moving
	end
end

function Regiment:orderHalt()
	if not self:isActive() then
		return
	end
	self:clearCombatOrders()
	self.order = { kind = "idle" }
	self.orderRun = false
	self.dest = nil
	self.movePhase = nil
	if self.state ~= States.Melee then
		self.state = States.Idle
		self:reformAt(self.fx, self.fz)
	end
end

function Regiment:setRunning(v: boolean)
	self.running = v
end

function Regiment:setFireAtWill(v: boolean)
	if self.def.ranged then
		self.fireAtWill = v
		if not v and self.order.kind ~= "attack" then
			self.fireTarget = nil
		end
	end
end

-- Morale -------------------------------------------------------------------

function Regiment:rout()
	local def = self.def
	self.routCount += 1
	local shattered = self.routCount >= Config.MAX_ROUTS or (self.alive / self.maxMen) < Config.SHATTER_FRACTION
	self.state = shattered and States.Shattered or States.Routing
	self:clearCombatOrders()
	self.order = { kind = "idle" }
	self.dest = nil
	self.movePhase = nil
	self.orderRun = false
	self.calmTime = 0
	for _, s in self.soldiers do
		s.jx = (math.random() - 0.5) * 2
		s.jz = (math.random() - 0.5) * 2
	end
	self.battle:notify(
		string.format("%s %s!", def.displayName, shattered and "have shattered and flee the field" or "are routing"),
		self.team,
		"bad"
	)
end

function Regiment:rally()
	self.state = States.Idle
	self.order = { kind = "idle" }
	self.calmTime = 0
	local enemy = self.battle:nearestEnemyRegiment(self, self.cx, self.cz)
	local fx, fz = self.fx, self.fz
	if enemy then
		fx, fz = Formation.normalize(enemy.cx - self.cx, enemy.cz - self.cz)
	end
	self:reformAt(fx, fz, Formation.defaultWidth(self.def, self.alive))
	self.battle:notify(self.def.displayName .. " have rallied!", self.team, "good")
end

function Regiment:updateMorale(dt: number)
	if self.alive <= 0 then
		return
	end
	local battle = self.battle
	local def = self.def
	local now = battle.time
	local m = def.morale

	m -= (1 - self.alive / self.maxMen) * 58
	m -= math.min(self.recentLosses / self.maxMen * 100 * 1.2, 36)

	if now - self.rearHitTime < 3 then
		m -= 18
	elseif now - self.sideHitTime < 3 then
		m -= 9
	end
	if now - self.underFireTime < 3 then
		m -= 5
	end

	if self.state == States.Melee then
		local enemyMen = 0
		for enemy in self.contact do
			enemyMen += enemy.alive
		end
		if enemyMen > self.alive * 2 then
			m -= 8
		end
	end

	local friendsRouting, enemiesRouting = 0, 0
	for _, r in battle.regiments do
		if r ~= self and r.alive > 0 and r:isBroken() then
			local dx, dz = r.cx - self.cx, r.cz - self.cz
			if dx * dx + dz * dz < 90 * 90 then
				if r.team == self.team then
					friendsRouting += 1
				else
					enemiesRouting += 1
				end
			end
		end
	end
	m -= math.min(friendsRouting * 6, 18)
	m += math.min(enemiesRouting * 4, 12)

	local gen = battle.generals[self.team]
	if gen and gen.alive > 0 and not gen:isBroken() then
		local dx, dz = gen.cx - self.cx, gen.cz - self.cz
		if gen == self or dx * dx + dz * dz < Config.GENERAL_AURA * Config.GENERAL_AURA then
			m += 12
		end
	elseif battle.generalDead[self.team] then
		m -= 12
	end

	m += self.rallyBonus
	if not self:isBroken() then
		self.rallyBonus = math.max(0, self.rallyBonus - dt)
	end

	self.recentLosses *= 0.95 ^ (dt / 0.5)
	self.morale = math.clamp(self.morale + (m - self.morale) * 0.3, 0, 100)

	if not self:isBroken() and self.morale < Config.ROUT_THRESHOLD then
		self:rout()
	end
end

-- State machine ------------------------------------------------------------

function Regiment:enterMelee()
	local now = self.battle.time
	local def = self.def
	local wasCharging = self.charging or ((self.running or self.orderRun) and self.speedAvg > def.walkSpeed * 1.15)
	if wasCharging and self.speedAvg > def.walkSpeed * 0.9 then
		self.chargeUntil = now + (def.isLarge and 6 or 4)
		if def.isLarge then
			for _, s in self.soldiers do
				s.impactsLeft = 2
			end
		end
	end
	self.charging = false
	self.state = States.Melee
	self.meleeStart = now
	self.fireTarget = nil

	-- face the enemy we ran into (only re-form for big turns)
	local enemy = next(self.contact)
	if enemy then
		self:faceTowards(enemy.cx - self.cx, enemy.cz - self.cz, math.rad(70))
	end
end

function Regiment:exitMelee()
	self.state = States.Idle
	for _, s in self.soldiers do
		s.target = nil
		s.impactsLeft = 0
	end
	local t = self.order.target
	if self.order.kind == "attack" and t and t.alive > 0 then
		self.state = States.Moving
	else
		self.order = { kind = "idle" }
	end
	self:reformAt(self.fx, self.fz, Formation.defaultWidth(self.def, self.alive))
end

function Regiment:updateMelee(dt: number)
	-- push the anchor towards the enemies we're fighting so rear ranks press in
	local ex, ez, n = 0, 0, 0
	for enemy in self.contact do
		ex += enemy.cx
		ez += enemy.cz
		n += 1
	end
	if n > 0 then
		ex /= n
		ez /= n
		local dx, dz, dist = Formation.normalize(ex - self.ax, ez - self.az)
		if dist > 2 then
			local step = math.min(dist - 2, 1.5 * dt)
			self.ax += dx * step
			self.az += dz * step
		end
	end
	if self.slotsDirty and self.battle.time - self.lastReassign > 3 then
		self:reassignSlots()
	end
end

function Regiment:updateMove(dt: number)
	local d = self.dest
	if not d then
		self.order = { kind = "idle" }
		self.state = States.Idle
		return
	end
	local now = self.battle.time
	if self.movePhase == "march" then
		local dx, dz, dist = Formation.normalize(d.x - self.ax, d.z - self.az)
		-- arrived at the march target (anchor travels to the front-centre of the destination)
		if dist < 0.6 then
			self.movePhase = "form"
			self.formStart = now
			local reassign = angleBetween(self.fx, self.fz, d.fx, d.fz) > math.rad(8) or d.width ~= self.width
			self:setFormation(d.x, d.z, d.fx, d.fz, d.width, reassign)
		else
			local err = self.slotError
			local factor = (err > 7 and 0.25) or (err > 3.5 and 0.65) or 1
			local step = math.min(dist, self:speed() * factor * dt)
			self.ax += dx * step
			self.az += dz * step
		end
	else
		if self.slotError < 1.0 or now - self.formStart > 10 then
			self.order = { kind = "idle" }
			self.state = States.Idle
			self.movePhase = nil
			self.dest = nil
			self.orderRun = false
		end
	end
end

-- Move the formation towards another regiment, turning to face it.
function Regiment:advanceTowards(target, dt: number)
	local dx, dz, dist = Formation.normalize(target.cx - self.ax, target.cz - self.az)
	if dist < 0.5 then
		return
	end
	if angleBetween(self.fx, self.fz, dx, dz) > math.rad(60) then
		self:reformAt(dx, dz)
	else
		-- small turns: rotate the block smoothly without reshuffling
		self.fx, self.fz = dx, dz
	end
	local err = self.slotError
	local factor = (err > 7 and 0.3) or (err > 3.5 and 0.7) or 1
	local step = math.min(dist, self:speed() * factor * dt)
	self.ax += dx * step
	self.az += dz * step
end

function Regiment:updateAttack(dt: number)
	local t = self.order.target
	if not t or t.alive <= 0 or t.state == States.Dead then
		self.order = { kind = "idle" }
		self.orderRun = false
		self.state = States.Idle
		self.fireTarget = nil
		self.charging = false
		self:reformAt(self.fx, self.fz)
		return
	end
	local def = self.def
	local _, _, dist = Formation.normalize(t.cx - self.cx, t.cz - self.cz)

	if def.ranged and self.ammo > 0 then
		local inRange = dist - t.radius * 0.5 <= def.ranged.range * 0.92
		if inRange then
			if self.state ~= States.Firing or self.fireTarget ~= t then
				self.state = States.Firing
				self.fireTarget = t
			end
			self:faceTowards(t.cx - self.cx, t.cz - self.cz, math.rad(35))
		else
			self.state = States.Moving
			self.fireTarget = nil
			self:advanceTowards(t, dt)
		end
		return
	end

	self.fireTarget = nil
	self.state = States.Moving
	local chargeRange = def.isLarge and Config.CHARGE_RANGE_CAVALRY or Config.CHARGE_RANGE_INFANTRY
	self.charging = dist < chargeRange + t.radius
	self:advanceTowards(t, dt)
end

function Regiment:findFireTarget()
	local def = self.def
	local best, bestD = nil, math.huge
	for _, r in self.battle.regiments do
		if r.team ~= self.team and r.alive > 0 and r.state ~= States.Dead then
			-- don't shoot into a melee our own side is part of
			local friendlyEngaged = false
			for other in r.contact do
				if other.team == self.team then
					friendlyEngaged = true
					break
				end
			end
			if not friendlyEngaged then
				local dx, dz = r.cx - self.cx, r.cz - self.cz
				local d = math.sqrt(dx * dx + dz * dz) - r.radius * 0.5
				if d <= def.ranged.range * 0.92 and d < bestD then
					best, bestD = r, d
				end
			end
		end
	end
	return best
end

function Regiment:updateIdle(dt: number)
	self.charging = false
	local def = self.def
	if def.ranged and self.fireAtWill and self.ammo > 0 then
		self.fireSearch -= dt
		if self.fireSearch <= 0 then
			self.fireSearch = 0.5
			local t = self:findFireTarget()
			if t then
				self.state = States.Firing
				self.fireTarget = t
				self:faceTowards(t.cx - self.cx, t.cz - self.cz, math.rad(35))
			else
				self.state = States.Idle
				self.fireTarget = nil
			end
		end
		if self.fireTarget and (self.fireTarget.alive <= 0) then
			self.fireTarget = nil
			self.state = States.Idle
		end
	else
		self.state = States.Idle
		self.fireTarget = nil
	end
	if self.slotsDirty and self.battle.time - self.lastReassign > 1.5 then
		self:reassignSlots()
	end
end

function Regiment:update(dt: number)
	if self.state == States.Dead then
		return
	end
	if self.alive <= 0 then
		self.state = States.Dead
		return
	end
	if self:isBroken() then
		self:updateRouting(dt)
		return
	end

	local now = self.battle.time
	local inContact = next(self.contact) ~= nil
	if inContact then
		self.lastContact = now
		if self.order.kind ~= "move" and self.state ~= States.Melee then
			self:enterMelee()
		end
	end

	if self.state == States.Melee then
		if self.order.kind == "move" then
			self.state = States.Moving
		elseif now - self.lastContact > 2 and not self.anyTarget then
			self:exitMelee()
		else
			self:updateMelee(dt)
			return
		end
	end

	local kind = self.order.kind
	if kind == "move" then
		self:updateMove(dt)
	elseif kind == "attack" then
		self:updateAttack(dt)
	else
		self:updateIdle(dt)
	end
	if self.slotsDirty and self.state == States.Moving and now - self.lastReassign > 2 then
		self:reassignSlots()
	end
end

-- Soldiers -----------------------------------------------------------------

local function clampToMap(s)
	local h = Config.MAP_HALF - 4
	s.x = math.clamp(s.x, -h, h)
	s.z = math.clamp(s.z, -h, h)
end

local function integrate(s, tx, tz, spd, dt, now)
	local oldX, oldZ = s.x, s.z
	local mx, mz = tx - s.x, tz - s.z
	local md = math.sqrt(mx * mx + mz * mz)
	local maxStep = spd * dt
	if md > maxStep and md > 0 then
		mx, mz = mx / md * maxStep, mz / md * maxStep
	end
	if now < s.stunUntil then
		mx, mz = 0, 0
	end
	-- knockback decays quickly
	local k = math.min(1, dt * 8)
	s.x += mx + s.px + s.kx * k
	s.z += mz + s.pz + s.kz * k
	s.kx *= 1 - k
	s.kz *= 1 - k
	clampToMap(s)
	s.vx, s.vz = (s.x - oldX) / dt, (s.z - oldZ) / dt
end

function Regiment:updateSoldiers(dt: number)
	if self.alive <= 0 or self:isBroken() then
		return
	end
	local battle = self.battle
	local now = battle.time
	local def = self.def
	local melee = self.state == States.Melee
	local fireTarget = (self.state == States.Firing) and self.fireTarget or nil
	if fireTarget and fireTarget.alive <= 0 then
		fireTarget = nil
	end
	local n = self.alive
	local w = math.min(self.width, n)
	local speed = self:speed()
	local meleeSpeed = def.walkSpeed * 1.1
	local reach = def.reach
	local turnRate = (def.isLarge and 4 or 7) * dt
	local errSum, errCount, spdSum = 0, 0, 0
	local anyTarget = false
	local ax, az, fx, fz = self.ax, self.az, self.fx, self.fz
	local regFacing = Formation.angleOf(fx, fz)
	local searchR = Config.MELEE_SEARCH_RADIUS
	local dropR2 = (searchR + 4) * (searchR + 4)

	for _, s in self.soldiers do
		if s.alive then
			local tx, tz, spd
			local faceA = nil
			s.inMelee = false

			if melee then
				local t = s.target
				if t then
					local dx, dz = t.ox - s.x, t.oz - s.z
					if not t.alive or dx * dx + dz * dz > dropR2 then
						t = nil
						s.target = nil
					end
				end
				s.retarget -= dt
				if s.retarget <= 0 then
					s.retarget = 0.35 + math.random() * 0.3
					local nt = battle:findEnemySoldier(s, searchR)
					if nt then
						s.target = nt
						t = nt
					end
				end
				if t then
					anyTarget = true
					s.inMelee = true
					-- use the target's start-of-tick position (see Battle:simulate)
					local dx, dz = t.ox - s.ox, t.oz - s.oz
					local d = math.sqrt(dx * dx + dz * dz)
					faceA = math.atan2(dx, dz)
					if d > reach then
						local stop = reach * 0.85
						tx, tz = t.ox - dx / d * stop, t.oz - dz / d * stop
						spd = meleeSpeed
					else
						tx, tz, spd = s.x, s.z, 0
						s.cd -= dt
						if s.cd <= 0 and now >= s.stunUntil then
							s.cd = def.attackInterval * (0.8 + math.random() * 0.4)
							s.attackCount = (s.attackCount + 1) % 4
							Combat.melee(battle, s, t)
						end
					end
				end
			end

			if not tx then
				local sx, sz = Formation.slotWorld(ax, az, fx, fz, s.slot, n, w, def.spacingX, def.spacingZ)
				tx, tz = sx, sz
				local ex, ez = sx - s.x, sz - s.z
				local e = math.sqrt(ex * ex + ez * ez)
				errSum += e
				errCount += 1
				spd = speed * (e > 3 and 1.3 or 1)
				if melee then
					spd = math.min(spd, meleeSpeed)
				end
				if e > 1.2 then
					faceA = math.atan2(ex, ez)
				else
					faceA = regFacing
				end

				if fireTarget and e < 4 then
					faceA = math.atan2(fireTarget.cx - s.x, fireTarget.cz - s.z)
					s.reload -= dt
					if s.reload <= 0 and self.ammo > 0 then
						if Combat.fireArrow(battle, s, fireTarget) then
							self.ammo -= 1
							s.attackCount = (s.attackCount + 1) % 4
							s.reload = def.ranged.reload * (0.85 + math.random() * 0.3)
						else
							s.reload = 0.5
						end
					end
				end
			end

			integrate(s, tx, tz, spd, dt, now)
			if faceA then
				s.facing = turnTowards(s.facing, faceA, turnRate)
			end
			spdSum += math.sqrt(s.vx * s.vx + s.vz * s.vz)
		end
	end

	self.slotError = errCount > 0 and errSum / errCount or 0
	self.anyTarget = anyTarget
	self.speedAvg = self.speedAvg + ((spdSum / math.max(n, 1)) - self.speedAvg) * math.min(1, dt * 4)
end

function Regiment:updateRouting(dt: number)
	local battle = self.battle
	local def = self.def
	local enemy, enemyDist = battle:nearestEnemyRegiment(self, self.cx, self.cz)
	local home = -Config.Teams[self.team].facingZ

	local dirX, dirZ = 0, home
	if enemy then
		local ex, ez = Formation.normalize(self.cx - enemy.cx, self.cz - enemy.cz)
		dirX, dirZ = Formation.normalize(ex * 0.65, ez * 0.65 + home * 0.35)
	end

	if self.state == States.Routing then
		if not enemy or enemyDist > 70 then
			self.calmTime += dt
		else
			self.calmTime = 0
		end
		self.rallyBonus = math.min(self.rallyBonus + dt * (self.calmTime > 0 and 5 or 1.5), 45)
		if self.calmTime > 6 and self.morale >= Config.RALLY_THRESHOLD then
			self:rally()
			return
		end
	end

	local now = battle.time
	local spd = def.runSpeed * 0.95
	local limit = Config.PLAY_HALF
	for _, s in self.soldiers do
		if s.alive then
			s.target = nil
			s.inMelee = false
			local dx, dz = Formation.normalize(dirX + s.jx * 0.25, dirZ + s.jz * 0.25)
			integrate(s, s.x + dx * 10, s.z + dz * 10, spd, dt, now)
			s.facing = turnTowards(s.facing, math.atan2(dx, dz), 6 * dt)
			if math.abs(s.x) > limit or math.abs(s.z) > limit then
				battle:escapeSoldier(s)
			end
		end
	end
end

return Regiment
