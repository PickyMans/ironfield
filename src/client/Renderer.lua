--[[
	Renderer
	Turns the replicated battle state into visuals:
	  * builds a part-based model for every soldier
	  * interpolates positions between 10 Hz snapshots
	  * procedurally animates walking, attacks, bow shots and deaths
	  * moves everything with one workspace:BulkMoveTo per frame
	  * draws a floating banner per regiment and selection highlights
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Heightmap = require(Shared.Heightmap)

local State = require(script.Parent.State)
local SoldierRig = require(script.Parent.SoldierRig)

local Renderer = {}

local States = Config.States
local TAU = math.pi * 2
local INTERP = 0.11
local HIDDEN_CF = CFrame.new(0, -2000, 0)
local band, rshift = bit32.band, bit32.rshift

local player = Players.LocalPlayer
local armies: Folder? = nil
local playerGui = player:WaitForChild("PlayerGui")
local partsBuf, cframesBuf = {}, {}

local GOLD = Color3.fromRGB(240, 200, 90)

-- Banners ----------------------------------------------------------------

local function moraleColor(m: number): Color3
	if m > 55 then
		return Color3.fromRGB(110, 200, 90)
	elseif m > 30 then
		return Color3.fromRGB(230, 190, 60)
	end
	return Color3.fromRGB(220, 70, 50)
end

local function makeBar(parent, y, color)
	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, 0, 0, 4)
	back.Position = UDim2.new(0, 0, 0, y)
	back.BackgroundColor3 = Color3.fromRGB(20, 18, 16)
	back.BorderSizePixel = 0
	back.Parent = parent
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = back
	return fill
end

local function createBanner(reg)
	local team = Config.Teams[reg.team]

	local anchor = Instance.new("Part")
	anchor.Name = "BannerAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = HIDDEN_CF
	anchor.Parent = reg.model

	local gui = Instance.new("BillboardGui")
	gui.Name = "Banner_" .. reg.id
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(46, 66)
	gui.SizeOffset = Vector2.new(0, 0.5)
	gui.LightInfluence = 0
	gui.MaxDistance = 2000
	gui.Active = true
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	local pole = Instance.new("Frame")
	pole.Size = UDim2.new(0, 2, 0, 18)
	pole.Position = UDim2.new(0.5, -1, 1, -18)
	pole.BackgroundColor3 = Color3.fromRGB(40, 34, 28)
	pole.BorderSizePixel = 0
	pole.Parent = gui

	local flag = Instance.new("TextButton")
	flag.Name = "Flag"
	flag.AutoButtonColor = false
	flag.Size = UDim2.new(1, 0, 0, 34)
	flag.BackgroundColor3 = team.color
	flag.BorderSizePixel = 0
	flag.Text = reg.def.short
	flag.Font = Enum.Font.GothamBlack
	flag.TextSize = 15
	flag.TextColor3 = Color3.fromRGB(250, 244, 230)
	flag.TextStrokeTransparency = 0.6
	flag.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = flag
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(20, 18, 16)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = flag

	local bars = Instance.new("Frame")
	bars.BackgroundTransparency = 1
	bars.Size = UDim2.new(1, 0, 0, 10)
	bars.Position = UDim2.new(0, 0, 0, 36)
	bars.Parent = gui
	local men = makeBar(bars, 0, Color3.fromRGB(235, 230, 220))
	local morale = makeBar(bars, 5, moraleColor(100))

	flag.MouseButton1Click:Connect(function()
		if State.isMine(reg) and State.isActive(reg) then
			local additive = Renderer.isShiftDown and Renderer.isShiftDown()
			if additive then
				State.toggleSelected(reg.id)
			else
				State.setSelection({ reg.id })
			end
		end
	end)
	flag.MouseButton2Click:Connect(function()
		if Renderer.onBannerRightClick then
			Renderer.onBannerRightClick(reg)
		end
	end)
	flag.MouseEnter:Connect(function()
		Renderer.bannerHover = reg.id
	end)
	flag.MouseLeave:Connect(function()
		if Renderer.bannerHover == reg.id then
			Renderer.bannerHover = nil
		end
	end)

	reg.banner = {
		gui = gui,
		anchor = anchor,
		flag = flag,
		stroke = stroke,
		men = men,
		morale = morale,
	}
end

local function updateBanner(reg, now: number)
	local b = reg.banner
	if not b then
		return
	end
	local team = Config.Teams[reg.team]
	local dead = reg.alive <= 0 or reg.state == States.Dead
	b.gui.Enabled = not dead
	if dead then
		return
	end
	b.men.Size = UDim2.fromScale(reg.alive / reg.men, 1)
	b.morale.Size = UDim2.fromScale(math.clamp(reg.morale / 100, 0, 1), 1)
	b.morale.BackgroundColor3 = moraleColor(reg.morale)

	local color = team.color
	if reg.state == States.Shattered then
		color = Color3.fromRGB(90, 90, 90)
	elseif reg.state == States.Routing then
		color = (math.floor(now * 4) % 2 == 0) and Color3.fromRGB(240, 240, 240) or team.color
	end
	b.flag.BackgroundColor3 = color

	if State.selected[reg.id] then
		b.stroke.Color = GOLD
		b.stroke.Thickness = 3
	elseif State.hovered == reg.id then
		b.stroke.Color = State.isMine(reg) and Color3.new(1, 1, 1) or Color3.fromRGB(255, 90, 70)
		b.stroke.Thickness = 2.5
	else
		b.stroke.Color = Color3.fromRGB(20, 18, 16)
		b.stroke.Thickness = 1.5
	end
end

-- Regiments --------------------------------------------------------------

local function createSoldier(reg, info, index: number)
	local model = info.model:Clone()
	local parts = table.create(#info.rig)
	local rig = {}
	for _, entry in info.rig do
		local part = model:FindFirstChild(entry.name)
		if part then
			if entry.tag == "banner" and index ~= 1 then
				part:Destroy()
			else
				table.insert(parts, part)
				table.insert(rig, entry)
				part.CFrame = HIDDEN_CF
			end
		end
	end

	-- per-soldier variation
	local skin = SoldierRig.SKIN[math.random(1, #SoldierRig.SKIN)]
	local horse = reg.def.isGeneral and SoldierRig.GENERAL_HORSE or SoldierRig.HORSE[math.random(1, #SoldierRig.HORSE)]
	for i, entry in rig do
		if entry.tag == "skin" then
			parts[i].Color = skin
		elseif entry.tag == "horse" then
			parts[i].Color = horse
		end
	end

	for _, p in parts do
		p.Parent = reg.model
	end
	model:Destroy()

	return {
		index = index,
		parts = parts,
		rig = rig,
		synced = false,
		alive = true,
		escaped = false,
		hiddenDone = false,
		deathT = nil,
		fallSide = math.random() < 0.5 and -1 or 1,
		settled = false,
		x = 0,
		z = 0,
		fromX = 0,
		fromZ = 0,
		toX = 0,
		toZ = 0,
		t0 = 0,
		facing = 0,
		toFacing = 0,
		atkCounter = 0,
		atkT = -100,
		melee = false,
		walkPhase = math.random() * TAU,
		speed = 0,
		amp = 0,
		h = 0,
		hx = math.huge,
		hz = math.huge,
		dirty = true,
		scale = 0.94 + math.random() * 0.1,
	}
end

function Renderer.reset()
	if armies then
		armies:Destroy()
	end
	for _, reg in State.regs do
		if reg.banner then
			reg.banner.gui:Destroy()
		end
	end
	armies = Instance.new("Folder")
	armies.Name = "Armies"
	armies.Parent = workspace

	table.clear(State.regs)
	table.clear(State.order)
	table.clear(State.selected)
	State.hovered = nil
end

function Renderer.createRegiment(data)
	if State.regs[data.id] then
		return
	end
	local def = Config.UnitTypes[data.type]
	if not def then
		return
	end
	local model = Instance.new("Model")
	model.Name = def.displayName .. "_" .. data.id

	local reg = {
		id = data.id,
		team = data.team,
		type = data.type,
		def = def,
		men = data.men,
		alive = data.men,
		morale = def.morale,
		state = States.Idle,
		ammo = 255,
		flags = 0,
		ax = 0,
		az = 0,
		facing = 0,
		width = def.defaultWidth,
		cx = 0,
		cz = 0,
		model = model,
		soldiers = {},
	}

	local info = SoldierRig.get(data.type, data.team)
	reg.info = info
	for i = 1, data.men do
		reg.soldiers[i] = createSoldier(reg, info, i)
	end

	local highlight = Instance.new("Highlight")
	highlight.Enabled = false
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.15
	highlight.Parent = model
	reg.highlight = highlight

	model.Parent = armies
	createBanner(reg)

	State.regs[data.id] = reg
	table.insert(State.order, data.id)
end

function Renderer.applyRegimentInfo(info)
	if info.battleId ~= State.battleId then
		Renderer.reset()
		State.battleId = info.battleId
		for _, r in info.regs do
			Renderer.createRegiment(r)
		end
		State.RegimentsReset:Fire()
	else
		local added = false
		for _, r in info.regs do
			if not State.regs[r.id] then
				Renderer.createRegiment(r)
				added = true
			end
		end
		if added then
			State.RegimentsReset:Fire()
		end
	end
end

-- Snapshots --------------------------------------------------------------

local function hideSoldier(s)
	for _, p in s.parts do
		p.CFrame = HIDDEN_CF
	end
	s.hiddenDone = true
	s.settled = true
end

-- Returns false if the snapshot references regiments we don't know about yet.
function Renderer.applySnapshot(regs, now: number): boolean
	local complete = true
	for _, r in regs do
		local reg = State.regs[r.id]
		if not reg then
			complete = false
			continue
		end
		local wasActive = State.isActive(reg)
		reg.alive = r.alive
		reg.morale = r.morale
		reg.state = r.state
		reg.ammo = r.ammo
		reg.flags = r.flags
		reg.ax, reg.az = r.ax, r.az
		reg.facing = r.facing
		reg.width = r.width
		if wasActive and not State.isActive(reg) and State.selected[reg.id] then
			State.selected[reg.id] = nil
			State.SelectionChanged:Fire()
		end

		for _, e in r.entries do
			local s = reg.soldiers[e.index]
			if s then
				local alive = band(e.flags, Codec.SF_ALIVE) ~= 0
				if not s.synced then
					s.synced = true
					s.x, s.z = e.x, e.z
					s.fromX, s.fromZ = e.x, e.z
					s.facing = e.facing
					if not alive then
						if band(e.flags, Codec.SF_ESCAPED) ~= 0 then
							s.alive = false
							s.escaped = true
							hideSoldier(s)
						else
							s.alive = false
							s.deathT = -100
						end
					end
				else
					s.fromX, s.fromZ = s.x, s.z
				end
				s.toX, s.toZ = e.x, e.z
				s.t0 = now
				s.toFacing = e.facing
				s.melee = band(e.flags, Codec.SF_MELEE) ~= 0

				local counter = band(rshift(e.flags, 1), 3)
				if counter ~= s.atkCounter then
					s.atkCounter = counter
					s.atkT = now
				end

				if s.alive and not alive then
					s.alive = false
					if band(e.flags, Codec.SF_ESCAPED) ~= 0 then
						s.escaped = true
						hideSoldier(s)
					else
						s.deathT = now
					end
				end
				s.dirty = true
			end
		end
	end
	return complete
end

-- Queries used by input & effects ---------------------------------------

function Renderer.soldierPosition(regId: number, index: number): Vector3?
	local reg = State.regs[regId]
	if not reg then
		return nil
	end
	local s = reg.soldiers[index]
	if not s or not s.synced then
		return nil
	end
	return Vector3.new(s.x, s.h, s.z)
end

-- Nearest regiment to a screen point (pixels). Returns reg, distance in px.
function Renderer.pickRegiment(camera: Camera, point: Vector2, maxPx: number, filter)
	local best, bestD = nil, maxPx
	for _, id in State.order do
		local reg = State.regs[id]
		if reg and reg.alive > 0 and (not filter or filter(reg)) then
			local c, onScreen =
				camera:WorldToViewportPoint(Vector3.new(reg.cx, Heightmap.get(reg.cx, reg.cz) + 2, reg.cz))
			-- quick reject on far away regiments
			if onScreen and (Vector2.new(c.X, c.Y) - point).Magnitude < 400 then
				for _, s in reg.soldiers do
					if s.alive and s.synced then
						local p, vis = camera:WorldToViewportPoint(Vector3.new(s.x, s.h + 2, s.z))
						if vis then
							local d = (Vector2.new(p.X, p.Y) - point).Magnitude
							if d < bestD then
								best, bestD = reg, d
							end
						end
					end
				end
			end
		end
	end
	return best, bestD
end

-- Regiments with any soldier inside a screen rectangle.
function Renderer.regimentsInRect(camera: Camera, minP: Vector2, maxP: Vector2, filter)
	local out = {}
	for _, id in State.order do
		local reg = State.regs[id]
		if reg and reg.alive > 0 and (not filter or filter(reg)) then
			for _, s in reg.soldiers do
				if s.alive and s.synced then
					local p, vis = camera:WorldToViewportPoint(Vector3.new(s.x, s.h + 2, s.z))
					if vis and p.X >= minP.X and p.X <= maxP.X and p.Y >= minP.Y and p.Y <= maxP.Y then
						table.insert(out, reg.id)
						break
					end
				end
			end
		end
	end
	return out
end

-- Per-frame update -------------------------------------------------------

local function attackCurve(kind: string, p: number): number
	if kind == "thrust" then
		if p < 0.3 then
			return -0.4 * (p / 0.3)
		elseif p < 0.5 then
			return -0.4 + 1.6 * ((p - 0.3) / 0.2)
		end
		return 1.2 * (1 - (p - 0.5) / 0.5)
	elseif kind == "swing" then
		if p < 0.35 then
			return -1.5 * (p / 0.35)
		elseif p < 0.55 then
			return -1.5 + 2.7 * ((p - 0.35) / 0.2)
		end
		return 1.2 * (1 - (p - 0.55) / 0.45)
	else -- bow: draw and hold, then release
		if p < 0.6 then
			return p / 0.6
		end
		return 1 - (p - 0.6) / 0.4
	end
end

local ATTACK_DUR = { thrust = 0.5, swing = 0.55, bow = 1.0 }

function Renderer.update(dt: number, now: number, camPos: Vector3)
	local n = 0
	local parts, cframes = partsBuf, cframesBuf
	local pi = math.pi

	for _, id in State.order do
		local reg = State.regs[id]
		if not reg then
			continue
		end
		local info = reg.info
		local isRider = info.isRider
		local animKind = info.anim
		local sumX, sumZ, count = 0, 0, 0

		for _, s in reg.soldiers do
			if s.settled or not s.synced then
				continue
			end

			-- interpolate towards the latest snapshot position
			local a = math.clamp((now - s.t0) / INTERP, 0, 1)
			local nx = s.fromX + (s.toX - s.fromX) * a
			local nz = s.fromZ + (s.toZ - s.fromZ) * a
			local mdx, mdz = nx - s.x, nz - s.z
			local moved = math.sqrt(mdx * mdx + mdz * mdz)
			s.x, s.z = nx, nz
			if s.alive then
				sumX += nx
				sumZ += nz
				count += 1
			end

			local spd = dt > 0 and moved / dt or 0
			s.speed += (spd - s.speed) * math.min(1, dt * 10)

			local df = (s.toFacing - s.facing + pi) % TAU - pi
			local turning = math.abs(df) > 0.01
			if turning then
				s.facing += df * math.min(1, dt * 10)
			end

			local targetAmp = s.alive and math.min(s.speed / 6, 1) or 0
			s.amp += (targetAmp - s.amp) * math.min(1, dt * 6)

			local attacking = now - s.atkT
				< (ATTACK_DUR[s.melee and (animKind == "bow" and "swing" or animKind) or animKind] or 0.6)
			local dying = s.deathT ~= nil and now - s.deathT < 0.8
			local animating = moved > 0.0005 or turning or s.amp > 0.01 or attacking or dying or s.dirty

			if not animating then
				continue
			end
			s.dirty = false

			-- ground height (cached while standing still)
			if math.abs(s.x - s.hx) > 0.05 or math.abs(s.z - s.hz) > 0.05 then
				s.h = Heightmap.get(s.x, s.z) - 0.15
				s.hx, s.hz = s.x, s.z
			end

			-- level of detail: far soldiers skip limb animation
			local dx, dy, dz = s.x - camPos.X, s.h - camPos.Y, s.z - camPos.Z
			local far = dx * dx + dy * dy + dz * dz > 350 * 350

			s.walkPhase += s.speed * dt * (isRider and 0.55 or 1.5)
			local phase = s.walkPhase
			local amp = s.amp
			local bob = isRider and math.sin(phase * 2) * 0.18 * amp or math.abs(math.sin(phase)) * 0.14 * amp

			local root = CFrame.new(s.x, s.h + bob, s.z) * CFrame.Angles(0, s.facing + pi, 0)
			if s.deathT then
				local p = math.clamp((now - s.deathT) / 0.7, 0, 1)
				p = 1 - (1 - p) * (1 - p)
				root = root * CFrame.new(0, -0.25 * p, 0) * CFrame.Angles(0, 0, s.fallSide * (pi / 2) * p)
				if p >= 1 then
					s.settled = true
				end
			end

			-- animation channels
			local legSwing = math.sin(phase) * 0.7 * amp
			local armCF = CFrame.identity
			local offArmCF = CFrame.identity
			local atkP = (now - s.atkT)
			if s.alive and not far then
				local kind = animKind
				if s.melee and kind == "bow" then
					kind = "swing"
				end
				local dur = ATTACK_DUR[kind]
				if atkP < dur then
					local c = attackCurve(kind, atkP / dur)
					if kind == "thrust" then
						armCF = CFrame.new(0, 0, -0.9 * c)
					elseif kind == "swing" then
						armCF = CFrame.Angles(c, 0, 0)
					else
						offArmCF = CFrame.Angles(0.8 * c, 0, 0)
						armCF = CFrame.Angles(0.5 * c, 0, 0)
					end
				elseif amp > 0.05 and not isRider then
					armCF = CFrame.Angles(-legSwing * 0.4, 0, 0)
				end
			end

			for i, entry in s.rig do
				local role = entry.role
				local anim = nil
				if not far and role ~= "static" then
					if role == "arm" then
						anim = armCF
					elseif role == "offArm" then
						anim = offArmCF
					elseif role == "legL" then
						anim = CFrame.Angles(legSwing, 0, 0)
					elseif role == "legR" then
						anim = CFrame.Angles(-legSwing, 0, 0)
					elseif role == "hfl" then
						anim = CFrame.Angles(math.sin(phase) * 0.6 * amp, 0, 0)
					elseif role == "hfr" then
						anim = CFrame.Angles(math.sin(phase + 0.6) * 0.6 * amp, 0, 0)
					elseif role == "hbl" then
						anim = CFrame.Angles(math.sin(phase + pi) * 0.6 * amp, 0, 0)
					elseif role == "hbr" then
						anim = CFrame.Angles(math.sin(phase + pi + 0.6) * 0.6 * amp, 0, 0)
					end
				end
				local cf
				if anim then
					cf = root * entry.pivot * anim * entry.rest
				else
					cf = root * entry.offset
				end
				n += 1
				parts[n] = s.parts[i]
				cframes[n] = cf
			end
		end

		-- regiment centroid (falls back to a full pass while soldiers are still syncing)
		if count > 0 and count == reg.alive then
			reg.cx, reg.cz = sumX / count, sumZ / count
		else
			local sx, sz, c = 0, 0, 0
			for _, s in reg.soldiers do
				if s.alive and s.synced then
					sx += s.x
					sz += s.z
					c += 1
				end
			end
			if c > 0 then
				reg.cx, reg.cz = sx / c, sz / c
			end
		end

		-- banner
		if reg.banner then
			local y = Heightmap.get(reg.cx, reg.cz) + (reg.def.category == "cavalry" and 11 or 8)
			n += 1
			parts[n] = reg.banner.anchor
			cframes[n] = CFrame.new(reg.cx, y, reg.cz)
			updateBanner(reg, now)
		end

		-- highlight
		local hl = reg.highlight
		if hl then
			local selected = State.selected[reg.id] == true
			local hovered = State.hovered == reg.id
			local on = (selected or hovered) and reg.alive > 0
			if hl.Enabled ~= on then
				hl.Enabled = on
			end
			if on then
				if selected then
					hl.OutlineColor = GOLD
					hl.FillColor = GOLD
				elseif State.isMine(reg) then
					hl.OutlineColor = Color3.new(1, 1, 1)
					hl.FillColor = Color3.new(1, 1, 1)
				else
					hl.OutlineColor = Color3.fromRGB(255, 80, 60)
					hl.FillColor = Color3.fromRGB(255, 80, 60)
				end
			end
		end
	end

	if n > 0 then
		-- trim stale entries from previous frames
		for i = n + 1, #parts do
			parts[i] = nil
			cframes[i] = nil
		end
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

return Renderer
