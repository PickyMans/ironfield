--[[
	UI
	The battle HUD, built entirely in code:
	  * top bar: phase, clock, army strength balance, help & settings
	  * deployment banner with the Start Battle button
	  * unit cards (bottom) with men, morale, ammo and state
	  * order buttons, selected-unit stat panel
	  * toast notifications, end-of-battle report, help overlay, loading screen
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Net = require(Shared.Net)

local State = require(script.Parent.State)
local Commander = require(script.Parent.Commander)
local CameraController = require(script.Parent.CameraController)

local UI = {}

local States = Config.States
local player = Players.LocalPlayer

local C = {
	panel = Color3.fromRGB(24, 21, 18),
	panel2 = Color3.fromRGB(38, 33, 28),
	gold = Color3.fromRGB(218, 182, 100),
	text = Color3.fromRGB(238, 228, 206),
	muted = Color3.fromRGB(168, 156, 136),
	good = Color3.fromRGB(120, 200, 100),
	bad = Color3.fromRGB(226, 84, 64),
}
local TITLE_FONT = Enum.Font.Garamond
local FONT = Enum.Font.GothamMedium
local BOLD = Enum.Font.GothamBold

local gui: ScreenGui
local refs = {}
local cards = {} -- regId -> card refs
local updateTimer = 0
local lastStateAt = 0
local lastCardClick = { id = nil, t = 0 }

-- helpers ----------------------------------------------------------------

local function make(className: string, props, children)
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 6) })
end

local function stroke(color, thickness, transparency)
	return make("UIStroke", {
		Color = color or C.gold,
		Thickness = thickness or 1,
		Transparency = transparency or 0.4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function label(props)
	local base = {
		BackgroundTransparency = 1,
		Font = FONT,
		TextColor3 = C.text,
		TextSize = 14,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextLabel", base)
end

local function button(text: string, props)
	local base = {
		Text = text,
		Font = BOLD,
		TextSize = 14,
		TextColor3 = C.text,
		BackgroundColor3 = C.panel2,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(110, 32),
	}
	for k, v in props or {} do
		base[k] = v
	end
	return make("TextButton", base, { corner(5), stroke(C.gold, 1, 0.3) })
end

local function bar(parent, pos: UDim2, size: UDim2, color: Color3)
	local back = make("Frame", {
		Position = pos,
		Size = size,
		BackgroundColor3 = Color3.fromRGB(12, 10, 9),
		BorderSizePixel = 0,
		Parent = parent,
	}, { corner(2) })
	local fill = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = back,
	}, { corner(2) })
	return fill, back
end

local function moraleColor(m: number): Color3
	if m > 55 then
		return C.good
	elseif m > 30 then
		return Color3.fromRGB(230, 190, 60)
	end
	return C.bad
end

local function moraleWord(reg): string
	if reg.state == States.Shattered then
		return "Shattered"
	elseif reg.state == States.Routing then
		return "Routing!"
	elseif reg.state == States.Dead then
		return "Destroyed"
	elseif reg.morale > 60 then
		return "Steady"
	elseif reg.morale > 40 then
		return "Shaken"
	elseif reg.morale > 22 then
		return "Wavering"
	end
	return "Breaking"
end

local function stateWord(reg): string
	local s = reg.state
	if s == States.Melee then
		return "In melee"
	elseif s == States.Firing then
		return "Firing"
	elseif s == States.Moving then
		if bit32.band(reg.flags, Codec.RF_CHARGING) ~= 0 then
			return "Charging"
		end
		return bit32.band(reg.flags, Codec.RF_RUNNING) ~= 0 and "Running" or "Marching"
	elseif s == States.Routing then
		return "Routing"
	elseif s == States.Shattered then
		return "Shattered"
	elseif s == States.Dead then
		return "Destroyed"
	end
	return "Holding"
end

local function formatTime(t: number): string
	t = math.max(0, math.floor(t))
	return string.format("%d:%02d", t // 60, t % 60)
end

-- build --------------------------------------------------------------------

local function buildTopBar()
	local top = make("Frame", {
		Name = "TopBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(560, 54),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.12,
		Parent = gui,
	}, { corner(8), stroke(C.gold, 1, 0.35) })

	refs.team1 = label({
		Position = UDim2.fromOffset(12, 4),
		Size = UDim2.fromOffset(170, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = BOLD,
		TextColor3 = Config.Teams[1].color:Lerp(Color3.new(1, 1, 1), 0.45),
		Text = Config.Teams[1].name,
		Parent = top,
	})
	refs.team2 = label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 4),
		Size = UDim2.fromOffset(170, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = BOLD,
		TextColor3 = Config.Teams[2].color:Lerp(Color3.new(1, 1, 1), 0.45),
		Text = Config.Teams[2].name,
		Parent = top,
	})
	refs.phase = label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(180, 22),
		Font = TITLE_FONT,
		TextSize = 20,
		TextColor3 = C.gold,
		Text = "Loading",
		Parent = top,
	})

	local balance = make("Frame", {
		Position = UDim2.fromOffset(12, 30),
		Size = UDim2.new(1, -24, 0, 12),
		BackgroundColor3 = Config.Teams[2].color,
		BorderSizePixel = 0,
		Parent = top,
	}, { corner(3) })
	refs.balance = make("Frame", {
		Size = UDim2.fromScale(0.5, 1),
		BackgroundColor3 = Config.Teams[1].color,
		BorderSizePixel = 0,
		Parent = balance,
	}, { corner(3) })
	make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -2),
		Size = UDim2.new(0, 2, 1, 4),
		BackgroundColor3 = C.gold,
		BorderSizePixel = 0,
		Parent = balance,
	})

	-- help & settings
	local help = button("?", {
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(1, 8, 0, 11),
		Size = UDim2.fromOffset(32, 32),
		Parent = top,
	})
	help.MouseButton1Click:Connect(function()
		refs.help.Visible = not refs.help.Visible
	end)
	local edge = button("Edge pan: off", {
		Position = UDim2.new(1, 46, 0, 11),
		Size = UDim2.fromOffset(110, 32),
		TextSize = 12,
		Parent = top,
	})
	edge.MouseButton1Click:Connect(function()
		CameraController.edgePan = not CameraController.edgePan
		edge.Text = CameraController.edgePan and "Edge pan: on" or "Edge pan: off"
	end)
	refs.top = top
end

local function buildDeployPanel()
	local panel = make("Frame", {
		Name = "Deploy",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.fromOffset(420, 84),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = gui,
	}, { corner(8), stroke(C.gold, 1, 0.35) })
	label({
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 24),
		Font = TITLE_FONT,
		TextSize = 22,
		TextColor3 = C.gold,
		Text = "Deployment",
		Parent = panel,
	})
	refs.deployHint = label({
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 16),
		TextSize = 12,
		TextColor3 = C.muted,
		Text = "Right-drag to place regiments inside your zone.",
		Parent = panel,
	})
	local start = button("Start Battle", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 50),
		Size = UDim2.fromOffset(160, 28),
		BackgroundColor3 = Color3.fromRGB(120, 40, 30),
		Parent = panel,
	})
	start.MouseButton1Click:Connect(function()
		Net.get("Command"):FireServer({ kind = "ready" })
	end)
	refs.startButton = start
	refs.deploy = panel
end

local function buildOrderBar()
	local orderBar = make("Frame", {
		Name = "Orders",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -146),
		Size = UDim2.fromOffset(470, 34),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 6),
		}),
	})
	local function orderButton(text, fn)
		local b = button(text, { Size = UDim2.fromOffset(110, 30), TextSize = 13, Parent = orderBar })
		b.MouseButton1Click:Connect(fn)
		return b
	end
	refs.btnHalt = orderButton("Halt  [H]", Commander.halt)
	refs.btnRun = orderButton("Run  [R]", Commander.toggleRun)
	refs.btnFire = orderButton("Fire at will  [F]", Commander.toggleFireAtWill)
	refs.btnAll = orderButton("Select all", Commander.selectAll)
	refs.orders = orderBar
end

local function buildCardTray()
	local tray = make("ScrollingFrame", {
		Name = "Cards",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -560, 0, 132),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.2,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		BorderSizePixel = 0,
		Parent = gui,
	}, {
		corner(8),
		stroke(C.gold, 1, 0.45),
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		make("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
		}),
		make("UISizeConstraint", { MinSize = Vector2.new(320, 132) }),
	})
	refs.tray = tray
end

local function buildInfoPanel()
	local panel = make("Frame", {
		Name = "UnitInfo",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -8),
		Size = UDim2.fromOffset(260, 132),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = gui,
	}, { corner(8), stroke(C.gold, 1, 0.35) })
	refs.infoTitle = label({
		Position = UDim2.fromOffset(10, 6),
		Size = UDim2.new(1, -20, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = TITLE_FONT,
		TextSize = 20,
		TextColor3 = C.gold,
		Parent = panel,
	})
	refs.infoSub = label({
		Position = UDim2.fromOffset(10, 28),
		Size = UDim2.new(1, -20, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 12,
		TextColor3 = C.muted,
		Parent = panel,
	})
	refs.infoStats = label({
		Position = UDim2.fromOffset(10, 48),
		Size = UDim2.new(1, -20, 0, 80),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 12,
		RichText = true,
		Parent = panel,
	})
	refs.info = panel
end

local function buildMinimapLegend()
	-- small controls reminder at bottom right
	local panel = make("Frame", {
		Name = "Hint",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -8),
		Size = UDim2.fromOffset(260, 132),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.12,
		Parent = gui,
	}, { corner(8), stroke(C.gold, 1, 0.35) })
	label({
		Position = UDim2.fromOffset(10, 6),
		Size = UDim2.new(1, -20, 1, -12),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 12,
		TextColor3 = C.muted,
		RichText = true,
		Text = table.concat({
			"<b><font color='#dab664'>Orders</font></b>",
			"LMB select · drag to box select",
			"RMB move · on enemy to attack",
			"RMB drag: draw battle line",
			"Double RMB: run / charge",
			"WASD pan · Q/E rotate · MMB look",
			"Press <b>?</b> for the full guide",
		}, "\n"),
		Parent = panel,
	})
end

local function buildHelp()
	local panel = make("Frame", {
		Name = "Help",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromOffset(560, 430),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.05,
		Visible = false,
		ZIndex = 20,
		Parent = gui,
	}, { corner(10), stroke(C.gold, 1.5, 0.2) })
	label({
		Position = UDim2.fromOffset(0, 10),
		Size = UDim2.new(1, 0, 0, 30),
		Font = TITLE_FONT,
		TextSize = 28,
		TextColor3 = C.gold,
		Text = "Field Manual",
		ZIndex = 21,
		Parent = panel,
	})
	label({
		Position = UDim2.fromOffset(24, 48),
		Size = UDim2.new(1, -48, 1, -100),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 13,
		RichText = true,
		TextWrapped = true,
		ZIndex = 21,
		Text = table.concat({
			"<b><font color='#dab664'>Camera</font></b>  WASD / arrows pan (Shift = fast) · Q / E rotate · mouse wheel zoom · hold middle mouse to look around · double-click a unit card to jump to it.",
			"",
			"<b><font color='#dab664'>Selecting</font></b>  Left click a soldier or banner · Shift adds/removes · drag a box · Ctrl+A selects everything · keys 1-0 pick unit cards.",
			"",
			"<b><font color='#dab664'>Orders</font></b>  Right click ground to move (groups keep their shape). Right click an enemy to attack. Right <i>drag</i> to draw a line: selected regiments spread across it, facing away from the camera; the length sets how wide and deep they stand. Double right-click to run. H halts, R toggles running, F toggles fire at will.",
			"",
			"<b><font color='#dab664'>Battle</font></b>  Spears stop cavalry charges from the front. Cavalry charge hits hard, then should pull out and charge again. Attacks from the flank and especially the rear ignore defense and wreck morale. Shields block arrows from the front. High ground helps in melee. Keep your general close: his presence steadies nearby men, his death shakes the whole army.",
			"",
			"<b><font color='#dab664'>Morale</font></b>  Casualties, flanking and nearby routs drain morale. Units that break flee towards their edge of the map and may rally if left alone; break too often and they shatter for good. Rout every enemy regiment to win.",
		}, "\n"),
		Parent = panel,
	})
	local close = button("Close", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		ZIndex = 22,
		Parent = panel,
	})
	close.MouseButton1Click:Connect(function()
		panel.Visible = false
	end)
	refs.help = panel
end

local function buildEndScreen()
	local panel = make("Frame", {
		Name = "EndScreen",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(460, 300),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.05,
		Visible = false,
		ZIndex = 15,
		Parent = gui,
	}, { corner(10), stroke(C.gold, 2, 0.15) })
	refs.endTitle = label({
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.new(1, 0, 0, 50),
		Font = TITLE_FONT,
		TextSize = 48,
		TextColor3 = C.gold,
		ZIndex = 16,
		Parent = panel,
	})
	refs.endSub = label({
		Position = UDim2.fromOffset(0, 64),
		Size = UDim2.new(1, 0, 0, 20),
		TextColor3 = C.muted,
		ZIndex = 16,
		Parent = panel,
	})
	refs.endStats = label({
		Position = UDim2.fromOffset(30, 96),
		Size = UDim2.new(1, -60, 0, 140),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Code,
		TextSize = 15,
		RichText = true,
		ZIndex = 16,
		Parent = panel,
	})
	local again = button("New Battle", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(170, 36),
		BackgroundColor3 = Color3.fromRGB(120, 40, 30),
		ZIndex = 16,
		Parent = panel,
	})
	again.MouseButton1Click:Connect(function()
		Net.get("Command"):FireServer({ kind = "newBattle" })
	end)
	refs.endScreen = panel
end

local function buildLoading()
	local cover = make("Frame", {
		Name = "Loading",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(14, 12, 10),
		ZIndex = 40,
		Parent = gui,
	})
	label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(600, 60),
		Font = TITLE_FONT,
		TextSize = 56,
		TextColor3 = C.gold,
		Text = "IRONFIELD",
		ZIndex = 41,
		Parent = cover,
	})
	label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.53),
		Size = UDim2.fromOffset(600, 24),
		TextColor3 = C.muted,
		Text = "Preparing the battlefield...",
		ZIndex = 41,
		Parent = cover,
	})
	refs.loading = cover
end

local function buildToasts()
	refs.toasts = make("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 70),
		Size = UDim2.fromOffset(330, 300),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		make("UIListLayout", {
			Padding = UDim.new(0, 6),
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

-- cards ------------------------------------------------------------------

local function createCard(reg, order: number)
	local team = Config.Teams[reg.team]
	local card = make("TextButton", {
		Name = "Card_" .. reg.id,
		LayoutOrder = order,
		Size = UDim2.fromOffset(88, 116),
		BackgroundColor3 = C.panel2,
		AutoButtonColor = false,
		Text = "",
		Parent = refs.tray,
	}, { corner(6) })
	local cardStroke = stroke(Color3.fromRGB(10, 9, 8), 1.5, 0)
	cardStroke.Parent = card

	local badge = make("Frame", {
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 0, 40),
		BackgroundColor3 = team.color,
		Parent = card,
	}, { corner(4) })
	label({
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		Text = reg.def.short,
		TextColor3 = Color3.fromRGB(250, 244, 230),
		TextStrokeTransparency = 0.6,
		Parent = badge,
	})
	local num = label({
		Position = UDim2.fromOffset(3, 1),
		Size = UDim2.fromOffset(14, 12),
		TextSize = 10,
		Font = BOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(250, 244, 230),
		Text = order <= 10 and tostring(order % 10) or "",
		Parent = badge,
	})
	local flags = label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -3, 0, 1),
		Size = UDim2.fromOffset(40, 12),
		TextSize = 10,
		Font = BOLD,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(250, 230, 160),
		Text = "",
		Parent = badge,
	})
	local name = label({
		Position = UDim2.fromOffset(4, 48),
		Size = UDim2.new(1, -8, 0, 14),
		TextSize = 11,
		Font = BOLD,
		TextScaled = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = reg.def.displayName,
		Parent = card,
	})
	local men = label({
		Position = UDim2.fromOffset(4, 62),
		Size = UDim2.new(1, -8, 0, 14),
		TextSize = 12,
		TextColor3 = C.muted,
		Text = "",
		Parent = card,
	})
	local moraleFill = bar(card, UDim2.new(0, 6, 0, 80), UDim2.new(1, -12, 0, 5), C.good)
	local ammoFill, ammoBack = bar(card, UDim2.new(0, 6, 0, 88), UDim2.new(1, -12, 0, 4), Color3.fromRGB(190, 170, 120))
	ammoBack.Visible = reg.def.ranged ~= nil
	local stateLabel = label({
		Position = UDim2.fromOffset(4, 96),
		Size = UDim2.new(1, -8, 0, 14),
		TextSize = 11,
		Text = "",
		Parent = card,
	})

	card.MouseButton1Click:Connect(function()
		local now = os.clock()
		if lastCardClick.id == reg.id and now - lastCardClick.t < 0.35 then
			CameraController.focusOn(reg.cx, reg.cz)
		end
		lastCardClick.id, lastCardClick.t = reg.id, now
		if not State.isActive(reg) then
			return
		end
		local UIS = game:GetService("UserInputService")
		if UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift) then
			State.toggleSelected(reg.id)
		else
			State.setSelection({ reg.id })
		end
	end)

	cards[reg.id] = {
		frame = card,
		stroke = cardStroke,
		badge = badge,
		name = name,
		men = men,
		morale = moraleFill,
		ammo = ammoFill,
		state = stateLabel,
		flags = flags,
		num = num,
	}
end

local function rebuildCards()
	for _, c in cards do
		c.frame:Destroy()
	end
	table.clear(cards)
	for i, reg in State.myRegiments() do
		createCard(reg, i)
	end
end

local function updateCards(now: number)
	for id, c in cards do
		local reg = State.regs[id]
		if reg then
			c.men.Text = string.format("%d / %d", reg.alive, reg.men)
			c.morale.Size = UDim2.fromScale(math.clamp(reg.morale / 100, 0, 1), 1)
			c.morale.BackgroundColor3 = moraleColor(reg.morale)
			if reg.def.ranged then
				local a = reg.ammo == 255 and 0 or reg.ammo / 254
				c.ammo.Size = UDim2.fromScale(a, 1)
			end
			local active = State.isActive(reg)
			local s = stateWord(reg)
			c.state.Text = s
			if reg.state == States.Routing or reg.state == States.Shattered then
				c.state.TextColor3 = C.bad
			elseif reg.state == States.Melee then
				c.state.TextColor3 = Color3.fromRGB(240, 170, 90)
			else
				c.state.TextColor3 = C.text
			end

			local flagText = ""
			if bit32.band(reg.flags, Codec.RF_RUNNING) ~= 0 then
				flagText ..= "»"
			end
			if reg.def.ranged and bit32.band(reg.flags, Codec.RF_FIRE_AT_WILL) ~= 0 then
				flagText ..= " FAW"
			end
			c.flags.Text = flagText

			local team = Config.Teams[reg.team]
			if not active then
				c.badge.BackgroundColor3 = reg.state == States.Routing
						and ((math.floor(now * 4) % 2 == 0) and Color3.fromRGB(230, 230, 230) or team.color)
					or Color3.fromRGB(70, 66, 62)
				c.frame.BackgroundTransparency = 0.4
			else
				c.badge.BackgroundColor3 = team.color
				c.frame.BackgroundTransparency = 0
			end

			if State.selected[id] then
				c.stroke.Color = C.gold
				c.stroke.Thickness = 2.5
			elseif State.hovered == id then
				c.stroke.Color = Color3.new(1, 1, 1)
				c.stroke.Thickness = 1.5
			else
				c.stroke.Color = Color3.fromRGB(10, 9, 8)
				c.stroke.Thickness = 1.5
			end
		end
	end
end

local function updateInfo()
	local sel = State.selectedList()
	local reg = sel[1]
	if not reg then
		-- show hovered enemy info as a scouting report
		local h = State.hovered and State.regs[State.hovered]
		if h and h.team ~= State.myTeam then
			reg = h
		end
	end
	refs.info.Visible = reg ~= nil
	if not reg then
		return
	end
	local d = reg.def
	local title = d.displayName
	if #sel > 1 then
		title ..= string.format("  (+%d)", #sel - 1)
	end
	refs.infoTitle.Text = title
	refs.infoSub.Text = string.format(
		"%s · %d / %d men · %s",
		reg.team == State.myTeam and "Your army" or Config.Teams[reg.team].name,
		reg.alive,
		reg.men,
		moraleWord(reg)
	)
	local lines = {
		string.format("Melee attack <b>%d</b>    Defense <b>%d</b>", d.meleeAttack, d.meleeDefense),
		string.format("Damage <b>%d</b> (+%d AP)    Armor <b>%d</b>", d.damage, d.ap, d.armor),
		string.format("Charge <b>%d</b>    Speed <b>%d</b>", d.chargeBonus, d.runSpeed),
	}
	if d.bonusVsLarge > 0 then
		table.insert(lines, string.format("Bonus vs cavalry <b>+%d</b>", d.bonusVsLarge))
	end
	if d.ranged then
		local ammoPct = reg.ammo == 255 and 0 or math.floor(reg.ammo / 254 * 100)
		table.insert(lines, string.format("Range <b>%d</b>    Ammo <b>%d%%</b>", d.ranged.range, ammoPct))
	end
	refs.infoStats.Text = table.concat(lines, "\n")
end

local function updateOrderButtons()
	local sel = State.selectedList()
	local any = #sel > 0
	local anyRanged, allRunning, allFaw = false, true, true
	for _, r in sel do
		if bit32.band(r.flags, Codec.RF_RUNNING) == 0 then
			allRunning = false
		end
		if r.def.ranged then
			anyRanged = true
			if bit32.band(r.flags, Codec.RF_FIRE_AT_WILL) == 0 then
				allFaw = false
			end
		end
	end
	refs.orders.Visible = State.myTeam ~= 0 and State.phase ~= "Ended" and State.phase ~= "Loading"
	local function style(b, enabled, on)
		b.TextTransparency = enabled and 0 or 0.6
		b.BackgroundColor3 = on and Color3.fromRGB(110, 80, 30) or C.panel2
	end
	style(refs.btnHalt, any, false)
	style(refs.btnRun, any, any and allRunning)
	style(refs.btnFire, anyRanged, anyRanged and allFaw)
	style(refs.btnAll, true, false)
end

local function updateTopBar(now: number)
	local b = State.battle
	if not b then
		return
	end
	local men = { 0, 0 }
	for _, reg in State.regs do
		if State.isActive(reg) then
			men[reg.team] += reg.alive
		end
	end
	local total = men[1] + men[2]
	refs.balance.Size = UDim2.fromScale(total > 0 and men[1] / total or 0.5, 1)

	local phase = State.phase
	if phase == "Battle" then
		local t = (b.time or 0) + (now - lastStateAt)
		refs.phase.Text = "Battle  " .. formatTime(t)
	elseif phase == "Deployment" then
		refs.phase.Text = "Deployment"
	elseif phase == "Ended" then
		refs.phase.Text = "Battle over"
	else
		refs.phase.Text = "Preparing..."
	end

	local names = b.controllers or { "AI", "AI" }
	refs.team1.Text = string.format("%s  (%s)", Config.Teams[1].name, names[1] or "AI")
	refs.team2.Text = string.format("(%s)  %s", names[2] or "AI", Config.Teams[2].name)
end

-- public -------------------------------------------------------------------

function UI.init()
	gui = make("ScreenGui", {
		Name = "IronfieldHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildTopBar()
	buildDeployPanel()
	buildOrderBar()
	buildCardTray()
	buildInfoPanel()
	buildMinimapLegend()
	buildHelp()
	buildEndScreen()
	buildToasts()
	buildLoading()

	State.RegimentsReset.Event:Connect(rebuildCards)
	State.Notified.Event:Connect(UI.toast)
	return gui
end

function UI.toast(data)
	if type(data) ~= "table" or type(data.text) ~= "string" then
		return
	end
	local color = C.gold
	if data.kind == "bad" then
		color = (data.team == State.myTeam) and C.bad or C.good
	elseif data.kind == "good" then
		color = (data.team == State.myTeam or data.team == 0) and C.good or C.bad
	end
	local t = make("TextLabel", {
		Size = UDim2.fromOffset(330, 30),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.1,
		Font = BOLD,
		TextSize = 13,
		TextColor3 = color,
		Text = data.text,
		TextWrapped = true,
		LayoutOrder = math.floor(os.clock() * 100),
		Parent = refs.toasts,
	}, {
		corner(6),
		stroke(color, 1, 0.4),
		make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	})
	local list = refs.toasts:GetChildren()
	local count = 0
	for _, c in list do
		if c:IsA("TextLabel") then
			count += 1
		end
	end
	if count > 6 then
		local oldest, oldestOrder = nil, math.huge
		for _, c in list do
			if c:IsA("TextLabel") and c.LayoutOrder < oldestOrder then
				oldest, oldestOrder = c, c.LayoutOrder
			end
		end
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(4.5, function()
		if t.Parent then
			local tw = TweenService:Create(t, TweenInfo.new(0.5), { TextTransparency = 1, BackgroundTransparency = 1 })
			tw:Play()
			tw.Completed:Wait()
			t:Destroy()
		end
	end)
end

function UI.onBattleState(b)
	lastStateAt = os.clock()
	local phase = b.phase
	refs.loading.Visible = phase == "Loading"
	refs.deploy.Visible = phase == "Deployment" and State.myTeam ~= 0
	if phase == "Deployment" then
		local ready = b.ready and b.ready[State.myTeam]
		refs.startButton.Text = ready and "Waiting for opponent..." or "Start Battle"
		refs.startButton.Active = not ready
		local opponent = State.myTeam == 1 and 2 or 1
		local vs = (b.controllers and b.controllers[opponent]) or "AI"
		refs.deployHint.Text = string.format("Right-drag to place regiments inside your zone. Opponent: %s", vs)
	end

	refs.endScreen.Visible = phase == "Ended"
	if phase == "Ended" then
		local w = b.winner or 0
		if State.myTeam == 0 then
			refs.endTitle.Text = w == 0 and "Draw" or (Config.Teams[w].name .. " wins")
		elseif w == 0 then
			refs.endTitle.Text = "Draw"
		elseif w == State.myTeam then
			refs.endTitle.Text = "Victory"
		else
			refs.endTitle.Text = "Defeat"
		end
		refs.endSub.Text = "Battle lasted " .. formatTime(b.time or 0)
		local rows = {
			string.format("%-14s %9s %9s", "", "Azure", "Crimson"),
			string.format("%-14s %9d %9d", "Soldiers", b.startMen[1], b.startMen[2]),
			string.format("%-14s %9d %9d", "Killed", b.losses[1], b.losses[2]),
			string.format("%-14s %9d %9d", "Fled field", b.fled[1], b.fled[2]),
			string.format("%-14s %9d %9d", "Enemies slain", b.kills[1], b.kills[2]),
		}
		refs.endStats.Text = table.concat(rows, "\n")
	end
	updateTopBar(os.clock())
end

function UI.update(dt: number, now: number)
	updateTimer -= dt
	if updateTimer > 0 then
		return
	end
	updateTimer = 0.12
	updateTopBar(now)
	updateCards(now)
	updateInfo()
	updateOrderButtons()
end

return UI
