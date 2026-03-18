if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local scannerVersion = "phantom-scanner-r1"
local maxStoredLogs = 350
local storedLogs = {}
local autoWatch = false
local lastScanAt = 0
local watchConnections = {}

local keywords = {
	"phantom",
	"orb",
	"orbs",
	"sphere",
	"spirit",
	"soul",
	"ghost",
	"boat",
	"ship",
	"dock",
	"harbor",
	"harbour",
	"port",
	"raft",
	"deliver",
	"submit",
	"return",
	"turn in",
	"deposit",
	"event",
	"collect",
	"pickup",
	"pick up",
}

local includeClasses = {
	Model = true,
	Folder = true,
	Part = true,
	MeshPart = true,
	UnionOperation = true,
	Tool = true,
	ProximityPrompt = true,
	ClickDetector = true,
	BillboardGui = true,
	SurfaceGui = true,
	TextLabel = true,
	TextButton = true,
	ImageLabel = true,
	ImageButton = true,
	Attachment = true,
	ParticleEmitter = true,
	Beam = true,
}

local function appendStoredLog(message)
	table.insert(storedLogs, message)
	if #storedLogs > maxStoredLogs then
		table.remove(storedLogs, 1)
	end
	print(message)
	if statusLabel then
		statusLabel.Text = message
	end
	if countLabel then
		countLabel.Text = "LOGS: " .. tostring(#storedLogs)
	end
	if copyButton then
		copyButton.Text = "COPIAR LOGS (" .. tostring(#storedLogs) .. ")"
	end
	if logBox then
		local dump = table.concat(storedLogs, "\n")
		logBox.Text = dump
		logBox.CursorPosition = #dump + 1
	end
end

local function log(eventName, details)
	local message = string.format("[PHANTOM][%.3f][%s] %s", os.clock(), tostring(eventName), tostring(details or ""))
	appendStoredLog(message)
end

local function copyLogsToClipboard()
	local payload = table.concat(storedLogs, "\n")
	local copyFns = {setclipboard, toclipboard}
	for _, copyFn in ipairs(copyFns) do
		if type(copyFn) == "function" then
			local ok = pcall(copyFn, payload)
			if ok then
				log("COPY", "logs copiados al portapapeles")
				return true
			end
		end
	end
	if type(Clipboard) == "table" and type(Clipboard.set) == "function" then
		local ok = pcall(function()
			Clipboard.set(payload)
		end)
		if ok then
			log("COPY", "logs copiados al portapapeles")
			return true
		end
	end
	log("COPY_FAIL", "sin API de clipboard")
	return false
end

local function safeText(instance)
	if not instance then
		return ""
	end
	local chunks = {}
	local okName, name = pcall(function()
		return instance.Name
	end)
	if okName and type(name) == "string" then
		table.insert(chunks, name)
	end
	pcall(function()
		if type(instance.Text) == "string" and instance.Text ~= "" then
			table.insert(chunks, instance.Text)
		end
	end)
	pcall(function()
		if type(instance.ActionText) == "string" and instance.ActionText ~= "" then
			table.insert(chunks, instance.ActionText)
		end
	end)
	pcall(function()
		if type(instance.ObjectText) == "string" and instance.ObjectText ~= "" then
			table.insert(chunks, instance.ObjectText)
		end
	end)
	pcall(function()
		local parent = instance.Parent
		if parent and type(parent.Name) == "string" then
			table.insert(chunks, parent.Name)
		end
	end)
	return string.lower(table.concat(chunks, " | "))
end

local function safePath(instance)
	if not instance then
		return "nil"
	end
	local ok, path = pcall(function()
		return instance:GetFullName()
	end)
	return ok and path or tostring(instance)
end

local function safeClassName(instance)
	local ok, className = pcall(function()
		return instance.ClassName
	end)
	return ok and className or "Unknown"
end

local function safeWorldPosition(instance)
	if not instance then
		return nil
	end
	local ok, value = pcall(function()
		if instance:IsA("BasePart") then
			return instance.Position
		end
		if instance:IsA("Attachment") then
			return instance.WorldPosition
		end
		if instance:IsA("Model") then
			local pivot = instance:GetPivot()
			return pivot.Position
		end
		local part = instance:FindFirstAncestorWhichIsA("Model")
		if part then
			return part:GetPivot().Position
		end
		return nil
	end)
	if ok then
		return value
	end
	return nil
end

local function formatPosition(position)
	if not position then
		return "pos=nil"
	end
	return string.format("pos=(%.1f, %.1f, %.1f)", position.X, position.Y, position.Z)
end

local function scoreInstance(instance)
	if not instance then
		return 0, ""
	end
	local haystack = safeText(instance) .. " | " .. string.lower(safePath(instance))
	local score = 0
	local matched = {}
	for _, keyword in ipairs(keywords) do
		if haystack:find(keyword, 1, true) then
			score = score + 5
			table.insert(matched, keyword)
		end
	end
	if instance:IsA("ProximityPrompt") then
		score = score + 12
	end
	if instance:IsA("ClickDetector") then
		score = score + 7
	end
	if instance:IsA("Tool") then
		score = score + 4
	end
	if instance:IsA("TextButton") then
		score = score + 6
	end
	if instance:IsA("BillboardGui") or instance:IsA("SurfaceGui") then
		score = score + 3
	end
	return score, table.concat(matched, ",")
end

local function collectMatches(root, label, limit)
	local results = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		local className = safeClassName(descendant)
		if includeClasses[className] then
			local score, matched = scoreInstance(descendant)
			if score > 0 then
				table.insert(results, {
					instance = descendant,
					score = score,
					matched = matched,
					className = className,
					path = safePath(descendant),
					position = safeWorldPosition(descendant),
				})
			end
		end
	end

	table.sort(results, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.path < b.path
	end)

	log("SCAN_" .. label, "candidatos=" .. tostring(#results))
	for index = 1, math.min(limit or 30, #results) do
		local entry = results[index]
		log(
			label,
			string.format(
				"#%d score=%d class=%s keywords=%s %s path=%s",
				index,
				entry.score,
				entry.className,
				entry.matched ~= "" and entry.matched or "none",
				formatPosition(entry.position),
				entry.path
			)
		)
	end

	return results
end

local function scanWorkspace()
	lastScanAt = os.clock()
	collectMatches(workspace, "WORLD", 40)
	local activeBrainrots = workspace:FindFirstChild("ActiveBrainrots")
	if activeBrainrots then
		collectMatches(activeBrainrots, "BRAINROTS", 25)
	end
	local boats = workspace:FindFirstChild("Boats") or workspace:FindFirstChild("Boat") or workspace:FindFirstChild("Ships")
	if boats then
		collectMatches(boats, "BOATS", 20)
	end
end

local function scanGui()
	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		log("SCAN_GUI", "sin PlayerGui")
		return
	end
	collectMatches(playerGui, "GUI", 40)
	local backpack = LP:FindFirstChildOfClass("Backpack")
	if backpack then
		collectMatches(backpack, "BACKPACK", 20)
	end
end

local function inspectNearestPrompts()
	local character = LP.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		log("NEAR", "sin HumanoidRootPart")
		return
	end
	local prompts = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			local parent = descendant.Parent
			local position = safeWorldPosition(parent) or safeWorldPosition(descendant)
			if position then
				table.insert(prompts, {
					prompt = descendant,
					path = safePath(descendant),
					distance = (root.Position - position).Magnitude,
					position = position,
				})
			end
		end
	end
	table.sort(prompts, function(a, b)
		return a.distance < b.distance
	end)
	log("NEAR", "prompts encontrados=" .. tostring(#prompts))
	for index = 1, math.min(20, #prompts) do
		local entry = prompts[index]
		log(
			"NEAR",
			string.format(
				"#%d dist=%.1f action=%s object=%s %s path=%s",
				index,
				entry.distance,
				tostring(entry.prompt.ActionText or ""),
				tostring(entry.prompt.ObjectText or ""),
				formatPosition(entry.position),
				entry.path
			)
		)
	end
end

local function clearWatchConnections()
	for _, connection in ipairs(watchConnections) do
		connection:Disconnect()
	end
	table.clear(watchConnections)
	autoWatch = false
	if watchButton then
		watchButton.Text = "AUTO WATCH: OFF"
		watchButton.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
	end
end

local function armWatchers()
	clearWatchConnections()
	autoWatch = true
	if watchButton then
		watchButton.Text = "AUTO WATCH: ON"
		watchButton.BackgroundColor3 = Color3.fromRGB(50, 110, 70)
	end
	log("WATCH", "escucha activa de workspace y gui")

	table.insert(watchConnections, workspace.DescendantAdded:Connect(function(descendant)
		local score, matched = scoreInstance(descendant)
		if score > 0 then
			log("ADD_WORLD", string.format("score=%d keywords=%s class=%s path=%s", score, matched ~= "" and matched or "none", safeClassName(descendant), safePath(descendant)))
		end
	end))

	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		table.insert(watchConnections, playerGui.DescendantAdded:Connect(function(descendant)
			local score, matched = scoreInstance(descendant)
			if score > 0 then
				log("ADD_GUI", string.format("score=%d keywords=%s class=%s path=%s", score, matched ~= "" and matched or "none", safeClassName(descendant), safePath(descendant)))
			end
		end))
	end
end

local guiParent = pcall(function()
	return gethui()
end) and gethui() or game:GetService("CoreGui")

local oldGui = guiParent:FindFirstChild("PhantomScannerGui")
if oldGui then
	oldGui:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PhantomScannerGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = guiParent

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Parent = screenGui
frame.Size = UDim2.new(0, 460, 0, 360)
frame.Position = UDim2.new(0.04, 0, 0.18, 0)
frame.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
frame.Active = true
frame.Draggable = true
frame.BorderSizePixel = 0
Instance.new("UICorner", frame)

local title = Instance.new("TextLabel")
title.Parent = frame
title.Size = UDim2.new(1, -90, 0, 28)
title.Position = UDim2.new(0, 10, 0, 8)
title.BackgroundTransparency = 1
title.Text = "PHANTOM EVENT SCANNER " .. scannerVersion
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left

local closeButton = Instance.new("TextButton")
closeButton.Parent = frame
closeButton.Size = UDim2.new(0, 70, 0, 26)
closeButton.Position = UDim2.new(1, -80, 0, 9)
closeButton.BackgroundColor3 = Color3.fromRGB(120, 45, 45)
closeButton.Text = "CERRAR"
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 12
closeButton.BorderSizePixel = 0
Instance.new("UICorner", closeButton)

local statusLabel = Instance.new("TextLabel")
statusLabel.Parent = frame
statusLabel.Size = UDim2.new(1, -20, 0, 18)
statusLabel.Position = UDim2.new(0, 10, 0, 42)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Listo para escanear workspace, gui y prompts cercanos"
statusLabel.TextColor3 = Color3.fromRGB(215, 220, 225)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left

local buttonY = 68

local function makeButton(name, text, x, width)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Parent = frame
	button.Size = UDim2.new(0, width, 0, 28)
	button.Position = UDim2.new(0, x, 0, buttonY)
	button.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
	button.Text = text
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.BorderSizePixel = 0
	Instance.new("UICorner", button)
	return button
end

local worldButton = makeButton("WorldScan", "SCAN WORLD", 10, 100)
local guiButton = makeButton("GuiScan", "SCAN GUI", 116, 90)
local nearButton = makeButton("NearScan", "PROMPTS CERCA", 212, 110)
local watchButton = makeButton("Watch", "AUTO WATCH: OFF", 328, 122)

local copyButton = makeButton("Copy", "COPIAR LOGS (0)", 10, 140)
copyButton.Position = UDim2.new(0, 10, 0, buttonY + 34)

local fullButton = makeButton("FullScan", "FULL SCAN", 156, 92)
fullButton.Position = UDim2.new(0, 156, 0, buttonY + 34)

local clearButton = makeButton("Clear", "LIMPIAR", 254, 80)
clearButton.Position = UDim2.new(0, 254, 0, buttonY + 34)

local countLabel = Instance.new("TextLabel")
countLabel.Parent = frame
countLabel.Size = UDim2.new(0, 110, 0, 20)
countLabel.Position = UDim2.new(0, 340, 0, buttonY + 38)
countLabel.BackgroundTransparency = 1
countLabel.Text = "LOGS: 0"
countLabel.TextColor3 = Color3.fromRGB(215, 220, 225)
countLabel.Font = Enum.Font.GothamBold
countLabel.TextSize = 12
countLabel.TextXAlignment = Enum.TextXAlignment.Right

local keywordLabel = Instance.new("TextLabel")
keywordLabel.Parent = frame
keywordLabel.Size = UDim2.new(1, -20, 0, 34)
keywordLabel.Position = UDim2.new(0, 10, 0, buttonY + 68)
keywordLabel.BackgroundTransparency = 1
keywordLabel.Text = "Keywords: phantom, orb, sphere, spirit, ghost, boat, ship, dock, harbor, deliver, submit, return, deposit, collect"
keywordLabel.TextWrapped = true
keywordLabel.TextColor3 = Color3.fromRGB(180, 190, 200)
keywordLabel.Font = Enum.Font.Gotham
keywordLabel.TextSize = 11
keywordLabel.TextXAlignment = Enum.TextXAlignment.Left
keywordLabel.TextYAlignment = Enum.TextYAlignment.Top

local logBox = Instance.new("TextBox")
logBox.Parent = frame
logBox.Size = UDim2.new(1, -20, 1, -(buttonY + 118))
logBox.Position = UDim2.new(0, 10, 0, buttonY + 108)
logBox.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
logBox.TextColor3 = Color3.fromRGB(220, 225, 230)
logBox.Font = Enum.Font.Code
logBox.TextSize = 12
logBox.TextWrapped = false
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.Text = ""
logBox.BorderSizePixel = 0
Instance.new("UICorner", logBox)

worldButton.MouseButton1Click:Connect(scanWorkspace)
guiButton.MouseButton1Click:Connect(scanGui)
nearButton.MouseButton1Click:Connect(inspectNearestPrompts)
fullButton.MouseButton1Click:Connect(function()
	log("FULL", "iniciando escaneo completo")
	scanWorkspace()
	scanGui()
	inspectNearestPrompts()
end)
copyButton.MouseButton1Click:Connect(copyLogsToClipboard)
clearButton.MouseButton1Click:Connect(function()
	table.clear(storedLogs)
	appendStoredLog("[PHANTOM][0.000][RESET] logs limpiados")
end)
watchButton.MouseButton1Click:Connect(function()
	if autoWatch then
		clearWatchConnections()
		log("WATCH", "escucha desactivada")
	else
		armWatchers()
	end
end)

closeButton.MouseButton1Click:Connect(function()
	clearWatchConnections()
	screenGui:Destroy()
end)

log("BOOT", "scanner listo version=" .. scannerVersion)
log("TIP", "usa FULL SCAN cuando empiece el evento y luego AUTO WATCH")