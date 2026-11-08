--[[
	Combat
	Hit resolution for melee, cavalry charge impacts and arrows.
	All randomness is server side; clients only see the results.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Heightmap = require(Shared.Heightmap)

local States = Config.States

local Combat = {}

local pending = {} -- arrows in flight
local firedThisTick = {} -- arrows fired this tick (sent to clients for visuals)
local queryBuf = {}

local FRONT, SIDE, REAR = 0, 1, 2

-- kill counters by cause (handy for balancing)
Combat.stats = { melee = 0, arrow = 0, charge = 0, braced = 0 }
Combat.arrowStats = { fired = 0, hit = 0, blocked = 0, missed = 0, friendly = 0 }

local function isBroken(reg)
	return reg.state == States.Routing or reg.state == States.Shattered
end

-- Where is (ax, az) relative to the victim's regiment facing?
local function flankOf(victim, ax: number, az: number): number
	local reg = victim.reg
	local dx, dz = ax - victim.x, az - victim.z
	local m = math.sqrt(dx * dx + dz * dz)
	if m < 1e-3 then
		return FRONT
	end
	local dot = (dx * reg.fx + dz * reg.fz) / m
	if dot < -0.45 then
		return REAR
	elseif dot < 0.35 then
		return SIDE
	end
	return FRONT
end
Combat.flankOf = flankOf

function Combat.reset()
	table.clear(pending)
	table.clear(firedThisTick)
	for k in Combat.stats do
		Combat.stats[k] = 0
	end
end

function Combat.applyDamage(battle, victim, base: number, ap: number, attackerReg, cause: string?)
	if not victim.alive then
		return
	end
	local armor = victim.reg.def.armor
	local dmg = base * (1 - armor / 100) + ap
	victim.hp -= dmg
	if victim.hp <= 0 then
		battle:killSoldier(victim, attackerReg)
		local c = cause or "melee"
		Combat.stats[c] = (Combat.stats[c] or 0) + 1
	end
end

function Combat.melee(battle, attacker, victim)
	local aReg, vReg = attacker.reg, victim.reg
	local adef, vdef = aReg.def, vReg.def
	local now = battle.time

	local atk = adef.meleeAttack
	local base = adef.damage
	local defense = vdef.meleeDefense

	if aReg.chargeUntil > now then
		atk += adef.chargeBonus
		base += adef.chargeBonus * 0.5
	end
	if vdef.isLarge and adef.bonusVsLarge > 0 then
		atk += adef.bonusVsLarge
		base += adef.bonusVsLarge * 0.4
	end

	-- high ground
	local dh = Heightmap.get(attacker.x, attacker.z) - Heightmap.get(victim.x, victim.z)
	if dh > 1.5 then
		atk += 6
	elseif dh < -1.5 then
		atk -= 4
	end

	if isBroken(vReg) then
		defense = 0
	else
		local side = flankOf(victim, attacker.x, attacker.z)
		if side == REAR then
			defense = 0
			vReg.rearHitTime = now
		elseif side == SIDE then
			defense *= 0.5
			vReg.sideHitTime = now
		end
	end

	-- a soldier that is knocked down can't parry
	if victim.stunUntil > now then
		defense *= 0.3
	end

	local chance = math.clamp(0.24 + (atk - defense) / 110, 0.05, 0.85)
	if math.random() < chance then
		Combat.applyDamage(battle, victim, base, adef.ap, aReg)
	end
end

-- A charging rider smashes into an enemy soldier.
function Combat.chargeImpact(battle, rider, victim)
	local aReg, vReg = rider.reg, victim.reg
	local now = battle.time

	-- braced spears facing the charge punish it hard
	local braced = vReg.def.bonusVsLarge > 0
		and not isBroken(vReg)
		and vReg.state ~= States.Moving
		and flankOf(victim, rider.x, rider.z) == FRONT
	if braced then
		Combat.applyDamage(battle, rider, vReg.def.bonusVsLarge * 1.2, 6, vReg, "braced")
		rider.impactsLeft = 0
		rider.stunUntil = now + 0.6
		return
	end

	-- horses colliding with horses hurt far less than riding down infantry
	local impact = aReg.def.chargeBonus * (vReg.def.isLarge and 0.4 or 0.9)
	if math.random() < 0.75 then
		Combat.applyDamage(battle, victim, impact, aReg.def.ap, aReg, "charge")
	end
	if victim.alive and not vReg.def.isLarge then
		local dx, dz = victim.x - rider.x, victim.z - rider.z
		local m = math.sqrt(dx * dx + dz * dz)
		if m > 1e-3 then
			-- push along the rider's travel direction mixed with the separation direction
			local vx, vz = rider.vx, rider.vz
			local vm = math.sqrt(vx * vx + vz * vz)
			if vm > 1e-3 then
				dx, dz = dx / m * 0.5 + vx / vm * 0.5, dz / m * 0.5 + vz / vm * 0.5
			else
				dx, dz = dx / m, dz / m
			end
			victim.kx += dx * 3
			victim.kz += dz * 3
		end
		victim.stunUntil = now + 0.9
	end
end

-- Returns true if an arrow was loosed.
function Combat.fireArrow(battle, shooter, targetReg): boolean
	local victim = targetReg:randomAliveSoldier()
	if not victim then
		return false
	end
	local r = shooter.reg.def.ranged
	local dx, dz = victim.x - shooter.x, victim.z - shooter.z
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist > r.range * 1.08 then
		return false
	end

	local flight = dist / r.projectileSpeed + 0.6
	-- imperfect leading of moving targets
	local tx = victim.x + victim.vx * flight * 0.9
	local tz = victim.z + victim.vz * flight * 0.9
	-- scatter
	local spread = 0.9 + dist * (1 - r.accuracy) * 0.04
	local ang = math.random() * math.pi * 2
	local rad = spread * math.sqrt(math.random())
	tx += math.cos(ang) * rad
	tz += math.sin(ang) * rad

	Combat.arrowStats.fired += 1
	table.insert(pending, {
		t = battle.time + flight,
		x = tx,
		z = tz,
		ox = shooter.x,
		oz = shooter.z,
		reg = shooter.reg,
		targetReg = targetReg,
	})
	table.insert(firedThisTick, {
		regId = shooter.reg.id,
		index = shooter.index,
		tx = tx,
		tz = tz,
		flight = flight,
	})
	return true
end

local function resolveArrow(battle, a)
	local hash = battle.hash
	local n = hash:query(a.x, a.z, 1.6, queryBuf)
	local best, bestD2 = nil, math.huge
	for i = 1, n do
		local s = queryBuf[i]
		if s.alive then
			local dx, dz = s.x - a.x, s.z - a.z
			local d2 = dx * dx + dz * dz
			local hitR = s.reg.def.isLarge and 1.4 or 0.75
			if d2 < hitR * hitR and d2 < bestD2 then
				best, bestD2 = s, d2
			end
		end
	end

	if a.targetReg and a.targetReg.alive > 0 then
		a.targetReg.underFireTime = battle.time
	end
	if not best then
		Combat.arrowStats.missed += 1
		return
	end

	local vReg = best.reg
	vReg.underFireTime = battle.time
	if vReg.team == a.reg.team then
		Combat.arrowStats.friendly += 1
	end
	local r = a.reg.def.ranged
	if not isBroken(vReg) and vReg.def.shield > 0 and flankOf(best, a.ox, a.oz) == FRONT then
		if math.random() < vReg.def.shield then
			Combat.arrowStats.blocked += 1
			return -- blocked by shield
		end
	end
	if math.random() < 0.9 then
		Combat.arrowStats.hit += 1
		Combat.applyDamage(battle, best, r.damage, r.ap, a.reg, "arrow")
	end
end

function Combat.update(battle)
	local now = battle.time
	local i = 1
	while i <= #pending do
		local a = pending[i]
		if now >= a.t then
			resolveArrow(battle, a)
			pending[i] = pending[#pending]
			pending[#pending] = nil
		else
			i += 1
		end
	end
end

-- Hands over (and clears) the list of arrows fired since the last call.
function Combat.takeFired()
	if #firedThisTick == 0 then
		return nil
	end
	local list = table.clone(firedThisTick)
	table.clear(firedThisTick)
	return list
end

return Combat
