--[[
	Commander
	Mouse & keyboard control of your army.

	  Left click            select a regiment (Shift = add/remove)
	  Left drag             box select
	  Right click ground    move (group keeps its shape, turns to face travel)
	  Right click enemy     attack
	  Right drag            draw a battle line: regiments spread along it
	  Double right click    same order, but run
	  Ctrl+A select all, 1-0 select unit by card, H halt, R run, F fire at will
]]

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Formation = require(Shared.Formation)
local Heightmap = require(Shared.Heightmap)
local Codec = require(Shared.Codec)
local Net = require(Shared.Net)

local State = require(script.Parent.State)
local Renderer = require(script.Parent.Renderer)

local Commander = {}

local camera = workspace.CurrentCamera
local player = Players.LocalPlayer

local DRAG_PX = 8
local DOUBLE_CLICK = 0.35

local leftDown = nil
local rightDown = nil
local lastRightClick = 0
local boxFrame: Frame
local previewFolder: Folder
local previewPool = {}
local previewShown = 0
local markersHideAt = 0
local hoverTimer = 0
local zoneFolder: Folder? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { workspace.Terrain }

local function send(cmd)
	Net.get("Command"):FireServer(cmd)
end

local function mouse(): Vector2
	return UserInputService:GetMouseLocation()
end

local function groundAt(p: Vector2): Vector3?
	local ray = camera:ViewportPointToRay(p.X, p.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 4000, rayParams)
	if hit then
		return hit.Position
	end
	-- fall back to intersecting the heightmap roughly at the focus height
	if ray.Direction.Y < -1e-3 then
		local t = (Heightmap.get(ray.Origin.X, ray.Origin.Z) - ray.Origin.Y) / ray.Direction.Y
		if t > 0 then
			return ray.Origin + ray.Direction * t
		end
	end
	return nil
end

local function shiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function ctrlDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end

local function mineActive(reg)
	return State.isMine(reg) and State.isActive(reg)
end

local function enemyAlive(reg)
	return reg.team ~= State.myTeam and reg.alive > 0 and reg.state ~= Config.States.Dead
end

local function canCommand(): boolean
	return State.myTeam ~= 0 and (State.phase == "Deployment" or State.phase == "Battle")
end

local function planInputs(regs)
	local inputs = {}
	for _, r in regs do
		local fx, fz = Formation.vecOf(r.facing)
		table.insert(inputs, {
			id = r.id,
			def = r.def,
			alive = r.alive,
			x = r.ax,
			z = r.az,
			fx = fx,
			fz = fz,
			width = math.max(1, math.min(r.width, r.alive)),
		})
	end
	return inputs
end

-- Formation preview ------------------------------------------------------

local function previewPart(i: number)
	local p = previewPool[i]
	if p then
		return p
	end
	local function mk(name, color)
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Transparency = 1
		part.Parent = previewFolder
		return part
	end
	p = {
		body = mk("Footprint", Color3.fromRGB(255, 255, 255)),
		front = mk("Front", Color3.fromRGB(245, 205, 95)),
	}
	previewPool[i] = p
	return p
end

local function showPlans(plans, transparency: number)
	local i = 0
	for _, plan in plans do
		local reg = State.regs[plan.id]
		if reg then
			i += 1
			local def = reg.def
			local width = math.max(1, plan.width)
			local ranks = math.ceil(math.max(reg.alive, 1) / width)
			local F = width * def.spacingX
			local D = ranks * def.spacingZ
			local fx, fz = plan.fx, plan.fz
			local cx = plan.x - fx * (D / 2 - def.spacingZ / 2)
			local cz = plan.z - fz * (D / 2 - def.spacingZ / 2)
			local y = Heightmap.get(cx, cz) + 0.5
			local center = Vector3.new(cx, y, cz)
			local look = CFrame.lookAt(center, center + Vector3.new(fx, 0, fz))
			local p = previewPart(i)
			p.body.Size = Vector3.new(F, 0.2, D)
			p.body.CFrame = look
			p.body.Color = Config.Teams[reg.team].color:Lerp(Color3.new(1, 1, 1), 0.35)
			p.body.Transparency = transparency
			local fy = Heightmap.get(plan.x, plan.z) + 0.6
			p.front.Size = Vector3.new(F, 0.3, 0.45)
			p.front.CFrame = CFrame.lookAt(Vector3.new(plan.x, fy, plan.z), Vector3.new(plan.x + fx, fy, plan.z + fz))
			p.front.Transparency = math.max(transparency - 0.3, 0)
		end
	end
	for k = i + 1, previewShown do
		local p = previewPool[k]
		if p then
			p.body.Transparency = 1
			p.front.Transparency = 1
		end
	end
	previewShown = i
end

local function hidePlans()
	showPlans({}, 1)
end

-- Orders -------------------------------------------------------------------

local function issueMove(plans, run: boolean)
	if #plans == 0 then
		return
	end
	local orders = {}
	for _, p in plans do
		table.insert(orders, { id = p.id, x = p.x, z = p.z, fx = p.fx, fz = p.fz, width = p.width })
	end
	send({ kind = "move", orders = orders, run = run })
	showPlans(plans, 0.7)
	markersHideAt = os.clock() + 1.2
end

local function issueAttack(target, run: boolean)
	local ids = {}
	for _, r in State.selectedList() do
		table.insert(ids, r.id)
	end
	if #ids == 0 then
		return
	end
	send({ kind = "attack", ids = ids, target = target.id, run = run })
	if Commander.onAttackOrdered then
		Commander.onAttackOrdered(target)
	end
end

function Commander.selectedIds()
	local ids = {}
	for _, r in State.selectedList() do
		table.insert(ids, r.id)
	end
	return ids
end

function Commander.halt()
	send({ kind = "halt", ids = Commander.selectedIds() })
end

function Commander.toggleRun()
	local list = State.selectedList()
	if #list == 0 then
		return
	end
	local anyWalking = false
	for _, r in list do
		if bit32.band(r.flags, Codec.RF_RUNNING) == 0 then
			anyWalking = true
		end
	end
	send({ kind = "run", ids = Commander.selectedIds(), value = anyWalking })
end

function Commander.toggleFireAtWill()
	local list = State.selectedList()
	local ids, anyOff = {}, false
	for _, r in list do
		if r.def.ranged then
			table.insert(ids, r.id)
			if bit32.band(r.flags, Codec.RF_FIRE_AT_WILL) == 0 then
				anyOff = true
			end
		end
	end
	if #ids > 0 then
		send({ kind = "fireAtWill", ids = ids, value = anyOff })
	end
end

function Commander.selectAll()
	local ids = {}
	for _, r in State.myRegiments() do
		table.insert(ids, r.id)
	end
	State.setSelection(ids)
end

-- Deployment zone --------------------------------------------------------

function Commander.showDeployZone(team: number?)
	if zoneFolder then
		zoneFolder:Destroy()
		zoneFolder = nil
	end
	if not team or team == 0 then
		return
	end
	zoneFolder = Instance.new("Folder")
	zoneFolder.Name = "DeployZone"
	local t = Config.Teams[team]
	local hw = Config.DEPLOY_HALF_WIDTH
	local z0, z1 = t.deployZ[1], t.deployZ[2]
	local corners = {
		Vector2.new(-hw, z0),
		Vector2.new(hw, z0),
		Vector2.new(hw, z1),
		Vector2.new(-hw, z1),
	}
	local SEG = 12
	for c = 1, 4 do
		local a, b = corners[c], corners[c % 4 + 1]
		local len = (b - a).Magnitude
		local steps = math.ceil(len / SEG)
		for k = 0, steps - 1 do
			local p1 = a:Lerp(b, k / steps)
			local p2 = a:Lerp(b, (k + 1) / steps)
			local v1 = Vector3.new(p1.X, Heightmap.get(p1.X, p1.Y) + 0.4, p1.Y)
			local v2 = Vector3.new(p2.X, Heightmap.get(p2.X, p2.Y) + 0.4, p2.Y)
			local seg = Instance.new("Part")
			seg.Anchored = true
			seg.CanCollide = false
			seg.CanQuery = false
			seg.CanTouch = false
			seg.CastShadow = false
			seg.Material = Enum.Material.Neon
			seg.Color = t.color:Lerp(Color3.new(1, 1, 1), 0.3)
			seg.Transparency = 0.25
			seg.Size = Vector3.new(0.6, 0.3, (v2 - v1).Magnitude + 0.6)
			seg.CFrame = CFrame.lookAt((v1 + v2) / 2, v2)
			seg.Parent = zoneFolder
		end
	end
	zoneFolder.Parent = workspace
end

-- Input --------------------------------------------------------------------

local function onRightRelease()
	local rd = rightDown
	rightDown = nil
	if not rd then
		return
	end
	local selected = State.selectedList()
	if #selected == 0 or not canCommand() then
		hidePlans()
		return
	end

	local now = os.clock()
	local run = now - lastRightClick < DOUBLE_CLICK
	lastRightClick = now

	if rd.dragging and rd.plans and #rd.plans > 0 then
		issueMove(rd.plans, run)
		return
	end

	-- click: attack the enemy under the cursor, else move there
	if State.phase == "Battle" then
		local enemy = nil
		if Renderer.bannerHover then
			local r = State.regs[Renderer.bannerHover]
			if r and enemyAlive(r) then
				enemy = r
			end
		end
		if not enemy then
			enemy = Renderer.pickRegiment(camera, rd.pos, 16, enemyAlive)
		end
		if enemy then
			issueAttack(enemy, run)
			hidePlans()
			return
		end
	end

	if rd.world then
		local plans = Formation.planGroupMove(planInputs(selected), rd.world.X, rd.world.Z)
		issueMove(plans, run)
	end
end

function Commander.init(screenGui: ScreenGui)
	previewFolder = Instance.new("Folder")
	previewFolder.Name = "OrderPreview"
	previewFolder.Parent = workspace

	boxFrame = Instance.new("Frame")
	boxFrame.Name = "SelectionBox"
	boxFrame.BackgroundColor3 = Color3.fromRGB(245, 205, 95)
	boxFrame.BackgroundTransparency = 0.85
	boxFrame.BorderSizePixel = 0
	boxFrame.Visible = false
	boxFrame.ZIndex = 50
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(245, 205, 95)
	stroke.Thickness = 1
	stroke.Parent = boxFrame
	boxFrame.Parent = screenGui

	Renderer.isShiftDown = shiftDown
	Renderer.onBannerRightClick = function(reg)
		if enemyAlive(reg) and State.phase == "Battle" and #State.selectedList() > 0 then
			local now = os.clock()
			local run = now - lastRightClick < DOUBLE_CLICK
			lastRightClick = now
			issueAttack(reg, run)
		end
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 then
			if processed then
				return
			end
			leftDown = { pos = mouse(), boxing = false }
		elseif t == Enum.UserInputType.MouseButton2 then
			if processed then
				return
			end
			local p = mouse()
			rightDown = { pos = p, world = groundAt(p), dragging = false }
		elseif t == Enum.UserInputType.Keyboard and not processed then
			local K = Enum.KeyCode
			local key = input.KeyCode
			if key == K.A and ctrlDown() then
				Commander.selectAll()
			elseif key == K.H then
				Commander.halt()
			elseif key == K.R then
				Commander.toggleRun()
			elseif key == K.F then
				Commander.toggleFireAtWill()
			else
				local numbers = { K.One, K.Two, K.Three, K.Four, K.Five, K.Six, K.Seven, K.Eight, K.Nine, K.Zero }
				for i, k in numbers do
					if key == k then
						local reg = State.myRegiments()[i]
						if reg then
							if shiftDown() then
								State.toggleSelected(reg.id)
							else
								State.setSelection({ reg.id })
							end
						end
						break
					end
				end
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local p = mouse()
		if leftDown then
			if not leftDown.boxing and (p - leftDown.pos).Magnitude > DRAG_PX then
				leftDown.boxing = true
			end
			if leftDown.boxing then
				local a, b = leftDown.pos, p
				local minP = Vector2.new(math.min(a.X, b.X), math.min(a.Y, b.Y))
				local maxP = Vector2.new(math.max(a.X, b.X), math.max(a.Y, b.Y))
				boxFrame.Position = UDim2.fromOffset(minP.X, minP.Y)
				boxFrame.Size = UDim2.fromOffset(maxP.X - minP.X, maxP.Y - minP.Y)
				boxFrame.Visible = true
			end
		end
		if rightDown and rightDown.world and canCommand() then
			if not rightDown.dragging and (p - rightDown.pos).Magnitude > DRAG_PX then
				rightDown.dragging = true
			end
			if rightDown.dragging then
				local w = groundAt(p)
				local selected = State.selectedList()
				if w and #selected > 0 then
					local a = rightDown.world
					local len = Vector2.new(w.X - a.X, w.Z - a.Z).Magnitude
					if len > 3 then
						rightDown.plans = Formation.planLine(planInputs(selected), a.X, a.Z, w.X, w.Z)
						showPlans(rightDown.plans, 0.55)
					end
				end
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 and leftDown then
			local ld = leftDown
			leftDown = nil
			boxFrame.Visible = false
			if ld.boxing then
				local a, b = ld.pos, mouse()
				local minP = Vector2.new(math.min(a.X, b.X), math.min(a.Y, b.Y))
				local maxP = Vector2.new(math.max(a.X, b.X), math.max(a.Y, b.Y))
				local ids = Renderer.regimentsInRect(camera, minP, maxP, mineActive)
				State.setSelection(ids, shiftDown())
			else
				local reg = Renderer.pickRegiment(camera, ld.pos, 16, mineActive)
				if reg then
					if shiftDown() then
						State.toggleSelected(reg.id)
					else
						State.setSelection({ reg.id })
					end
				elseif not shiftDown() then
					State.clearSelection()
				end
			end
		elseif t == Enum.UserInputType.MouseButton2 then
			onRightRelease()
		end
	end)
end

function Commander.update(dt: number)
	-- hover detection (throttled)
	hoverTimer -= dt
	if hoverTimer <= 0 then
		hoverTimer = 0.06
		local hovered = Renderer.bannerHover
		if not hovered and not (rightDown and rightDown.dragging) and not (leftDown and leftDown.boxing) then
			local reg = Renderer.pickRegiment(camera, mouse(), 14)
			hovered = reg and reg.id or nil
		end
		State.hovered = hovered
	end

	if not (rightDown and rightDown.dragging) and markersHideAt > 0 and os.clock() > markersHideAt then
		markersHideAt = 0
		hidePlans()
	end
end

local _ = player
return Commander
