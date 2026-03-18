if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LP = Players.LocalPlayer

local scannerVersion = "phantom-boat-scanner-r1"
local maxStoredLogs = 1200
local nearRadius = 140
local watchEnabled = false
local watchConnections = {}
local storedLogs = {}
local trackedPaths = {}

local statusLabel
local logBox
local copyButton
local watchButton
local radiusButton

local radiusModes = {80, 140, 220}
local radiusIndex = 2

local interestingKeywords = {
	"phantom",
	"boat",
	"ship",
	"dock",
	"harbor",
	"harbour",
	"port",
	"raft",
	"deliver",
	"deposit",
	"submit",
	"turn in",
	"return",
	"orb",
	"coin",
	"wave",
	"ghost",
}

local allowedClasses = {
	Model = true,
	Folder = true,
	Part = true,
	MeshPart = true,
	UnionOperation = true,
	Attachment = true,
	ProximityPrompt = true,
	ClickDetector = true,
	BillboardGui = true,
	SurfaceGui = true,
	TextLabel = true,
	TextButton = true,
	StringValue = true,
	NumberValue = true,
	ObjectValue = true,
	Trail = true,
	ParticleEmitter = true,
	Beam = true,
	Highlight = true,
}

local function safeIsA(instance, className)
	local ok, result = pcall(function()
		return instance and instance:IsA(className)
	end)
	return ok and result or false
end

local function clearArray(list)
	for index = #list, 1, -1 do
		list[index] = nil
	end
end

local function getGuiParent()
	local ok, result = pcall(function()
		return gethui and gethui()
	end)
	if ok and result then
		return result
	end
	return game:GetService("CoreGui")
end

local function getRoot()
	local character = LP.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
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

local function getWorldPosition(instance)
	if not instance then
		return nil
	end
	local ok, position = pcall(function()
		if safeIsA(instance, "BasePart") then
			return instance.Position
		end
		if safeIsA(instance, "Attachment") then
			return instance.WorldPosition
		end
		if safeIsA(instance, "Model") then
			return instance:GetPivot().Position
		end
		local model = instance:FindFirstAncestorWhichIsA("Model")
		if model then
			return model:GetPivot().Position
		end
		local part = instance:FindFirstAncestorWhichIsA("BasePart")
		if part then
			return part.Position
		end
		return nil
	end)
	return ok and position or nil
end

local function formatPosition(position)
	if not position then
		return "pos=nil"
	end
	return string.format("pos=(%.1f, %.1f, %.1f)", position.X, position.Y, position.Z)
end

local function appendStoredLog(message)
	table.insert(storedLogs, message)
	if #storedLogs > maxStoredLogs then
		table.remove(storedLogs, 1)
	end
	print(message)
	if statusLabel then
		statusLabel.Text = message
	end
	if copyButton then
		copyButton.Text = "COPIAR LOGS (" .. tostring(#storedLogs) .. ")"
	end
	if logBox then
		local dump = table.concat(storedLogs, "\n")
		logBox.Text = dump
		pcall(function()
			logBox.CursorPosition = #dump + 1
		end)
	end
end

local function log(eventName, details)
	appendStoredLog(string.format("[BOAT][%.3f][%s] %s", os.clock(), tostring(eventName), tostring(details or "")))
end

local function copyLogsToClipboard()
	local payload = table.concat(storedLogs, "\n")
	local copyFns = {setclipboard, toclipboard}
	for _, copyFn in ipairs(copyFns) do
		if type(copyFn) == "function" then
			local ok = pcall(copyFn, payload)
			if ok then
				log("COPY", "logs copiados")
				return true
			end
		end
	end
	if type(Clipboard) == "table" and type(Clipboard.set) == "function" then
		local ok = pcall(function()
			Clipboard.set(payload)
		end)
		if ok then
			log("COPY", "logs copiados")
			return true
		end
	end
	log("COPY_FAIL", "sin API de clipboard")
	return false
end

local function scoreText(text)
	if type(text) ~= "string" or text == "" then
		return 0, ""
	end
	local lowered = string.lower(text)
	local score = 0
	local hits = {}
	for _, keyword in ipairs(interestingKeywords) do
		if lowered:find(keyword, 1, true) then
			score = score + 5
			table.insert(hits, keyword)
		end
	end
	return score, table.concat(hits, ",")
end

local function getInstanceText(instance)
	if not instance then
		return ""
	end
	local parts = {}
	pcall(function()
		table.insert(parts, tostring(instance.Name or ""))
	end)
	pcall(function()
		if type(instance.Text) == "string" then
			table.insert(parts, instance.Text)
		end
	end)
	pcall(function()
		if type(instance.ActionText) == "string" then
			table.insert(parts, instance.ActionText)
		end
	end)
	pcall(function()
		if type(instance.ObjectText) == "string" then
			table.insert(parts, instance.ObjectText)
		end
	end)
	pcall(function()
		local parent = instance.Parent
		if parent then
			table.insert(parts, tostring(parent.Name or ""))
		end
	end)
	return table.concat(parts, " | ")
end

local function scoreInstance(instance)
	local score = 0
	local textScore, hits = scoreText(getInstanceText(instance) .. " | " .. safePath(instance))
	score = score + textScore
	if safeIsA(instance, "ProximityPrompt") then
		score = score + 12
	end
	if safeIsA(instance, "ClickDetector") then
		score = score + 8
	end
	if safeIsA(instance, "BillboardGui") or safeIsA(instance, "SurfaceGui") then
		score = score + 3
	end
	return score, hits
end

local function isNearPlayer(instance)
	local root = getRoot()
	if not root then
		return false, nil
	end
	local position = getWorldPosition(instance)
	if not position then
		return false, nil
	end
	local distance = (root.Position - position).Magnitude
	return distance <= nearRadius, distance
end

local function shouldTrackInstance(instance)
	local className = safeClassName(instance)
	if not allowedClasses[className] then
		return false, 0, "", nil
	end
	local score, hits = scoreInstance(instance)
	local nearOk, distance = isNearPlayer(instance)
	if nearOk then
		score = score + 6
	end
	if score <= 0 and not nearOk then
		return false, score, hits, distance
	end
	return true, score, hits, distance
end

local function logInstance(prefix, instance)
	local track, score, hits, distance = shouldTrackInstance(instance)
	if not track then
		return
	end
	local path = safePath(instance)
	local dedupeKey = prefix .. ":" .. path
	if trackedPaths[dedupeKey] then
		return
	end
	trackedPaths[dedupeKey] = true
	log(prefix, string.format("score=%d hits=%s dist=%s class=%s %s path=%s", score, hits ~= "" and hits or "none", distance and string.format("%.1f", distance) or "nil", safeClassName(instance), formatPosition(getWorldPosition(instance)), path))
	if safeIsA(instance, "ProximityPrompt") then
		log(prefix .. "_PROMPT", string.format("action=%s object=%s path=%s", tostring(instance.ActionText or ""), tostring(instance.ObjectText or ""), path))
	end
	local parent = instance.Parent
	if parent and safePath(parent) ~= "nil" then
		local parentPath = safePath(parent)
		if not trackedPaths[prefix .. ":PARENT:" .. parentPath] then
			trackedPaths[prefix .. ":PARENT:" .. parentPath] = true
			log(prefix .. "_PARENT", string.format("class=%s %s path=%s", safeClassName(parent), formatPosition(getWorldPosition(parent)), parentPath))
		end
	end
end

local function scanNearbyWorld()
	clearArray(storedLogs)
	trackedPaths = {}
	log("SCAN", "escaneando radio=" .. tostring(nearRadius))
	local descendants = workspace:GetDescendants()
	for index, descendant in ipairs(descendants) do
		logInstance("WORLD", descendant)
		yieldIfNeeded(index)
	end
	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		for index, descendant in ipairs(playerGui:GetDescendants()) do
			logInstance("GUI", descendant)
			yieldIfNeeded(index)
		end
	end
	log("SCAN_OK", "escaneo barco completado")
end

local function scanNearestPrompts()
	trackedPaths = {}
	local root = getRoot()
	if not root then
		log("NEAR_FAIL", "sin HumanoidRootPart")
		return
	end
	local prompts = {}
	for index, descendant in ipairs(workspace:GetDescendants()) do
		if safeIsA(descendant, "ProximityPrompt") then
			local position = getWorldPosition(descendant) or getWorldPosition(descendant.Parent)
			if position then
				table.insert(prompts, {
					instance = descendant,
					distance = (root.Position - position).Magnitude,
					position = position,
				})
			end
		end
		yieldIfNeeded(index)
	end
	table.sort(prompts, function(a, b)
		return a.distance < b.distance
	end)
	log("NEAR", "prompts=" .. tostring(#prompts))
	for index = 1, math.min(25, #prompts) do
		local entry = prompts[index]
		log("NEAR", string.format("#%d dist=%.1f action=%s object=%s %s path=%s", index, entry.distance, tostring(entry.instance.ActionText or ""), tostring(entry.instance.ObjectText or ""), formatPosition(entry.position), safePath(entry.instance)))
	end
end

local function clearWatchConnections()
	for _, connection in ipairs(watchConnections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	clearArray(watchConnections)
	watchEnabled = false
	if watchButton then
		watchButton.Text = "WATCH BARCO: OFF"
		watchButton.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
	end
end

local function armWatchers()
	clearWatchConnections()
	trackedPaths = {}
	watchEnabled = true
	if watchButton then
		watchButton.Text = "WATCH BARCO: ON"
		watchButton.BackgroundColor3 = Color3.fromRGB(55, 110, 70)
	end
	log("WATCH", "vigilando zona cercana del barco")

	table.insert(watchConnections, workspace.DescendantAdded:Connect(function(descendant)
		task.spawn(function()
			local ok, err = xpcall(function()
				logInstance("ADD_WORLD", descendant)
			end, debug.traceback)
			if not ok then
				log("WATCH_ERR", tostring(err))
			end
		end)
	end))

	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		table.insert(watchConnections, playerGui.DescendantAdded:Connect(function(descendant)
			task.spawn(function()
				local ok, err = xpcall(function()
					logInstance("ADD_GUI", descendant)
				end, debug.traceback)
				if not ok then
					log("WATCH_ERR", tostring(err))
				end
			end)
		end))
	end

	table.insert(watchConnections, RunService.Heartbeat:Connect(function()
		local root = getRoot()
		if root and statusLabel then
			statusLabel.Text = string.format("Boat watch | radio=%d | pos=(%.1f, %.1f, %.1f)", nearRadius, root.Position.X, root.Position.Y, root.Position.Z)
		end
	end))
end

local guiParent = getGuiParent()
local oldGui = guiParent:FindFirstChild("PhantomBoatScannerGui")
if oldGui then
	oldGui:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PhantomBoatScannerGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = guiParent

local frame = Instance.new("Frame")
frame.Parent = screenGui
frame.Size = UDim2.new(0, 470, 0, 390)
frame.Position = UDim2.new(0.05, 0, 0.18, 0)
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
title.Text = "PHANTOM BOAT SCANNER " .. scannerVersion
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

statusLabel = Instance.new("TextLabel")
statusLabel.Parent = frame
statusLabel.Size = UDim2.new(1, -20, 0, 20)
statusLabel.Position = UDim2.new(0, 10, 0, 42)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Acercate al barco con un orbe y usa WATCH BARCO"
statusLabel.TextColor3 = Color3.fromRGB(215, 220, 225)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left

local function makeButton(text, x, y, width)
	local button = Instance.new("TextButton")
	button.Parent = frame
	button.Size = UDim2.new(0, width, 0, 28)
	button.Position = UDim2.new(0, x, 0, y)
	button.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
	button.Text = text
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.BorderSizePixel = 0
	Instance.new("UICorner", button)
	return button
end

local scanButton = makeButton("SCAN CERCA", 10, 70, 100)
local promptButton = makeButton("PROMPTS CERCA", 116, 70, 120)
watchButton = makeButton("WATCH BARCO: OFF", 242, 70, 140)
radiusButton = makeButton("RADIO: 140", 388, 70, 72)
copyButton = makeButton("COPIAR LOGS (0)", 10, 104, 140)

local info = Instance.new("TextLabel")
info.Parent = frame
info.Size = UDim2.new(1, -20, 0, 34)
info.Position = UDim2.new(0, 10, 0, 140)
info.BackgroundTransparency = 1
info.TextWrapped = true
info.Text = "Uso: 1) Ve al barco. 2) Activa WATCH BARCO. 3) Lleva un orbe Phantom. 4) Sueltalo/entregalo encima del barco. 5) Copia logs."
info.TextColor3 = Color3.fromRGB(185, 190, 198)
info.Font = Enum.Font.Gotham
info.TextSize = 11
info.TextXAlignment = Enum.TextXAlignment.Left
info.TextYAlignment = Enum.TextYAlignment.Top

logBox = Instance.new("TextBox")
logBox.Parent = frame
logBox.Size = UDim2.new(1, -20, 1, -186)
logBox.Position = UDim2.new(0, 10, 0, 176)
logBox.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
logBox.TextColor3 = Color3.fromRGB(220, 225, 230)
logBox.Font = Enum.Font.Code
logBox.TextSize = 12
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.TextWrapped = false
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.BorderSizePixel = 0
logBox.Text = ""
Instance.new("UICorner", logBox)

scanButton.MouseButton1Click:Connect(scanNearbyWorld)
promptButton.MouseButton1Click:Connect(scanNearestPrompts)
watchButton.MouseButton1Click:Connect(function()
	if watchEnabled then
		clearWatchConnections()
		log("WATCH", "desactivado")
	else
		armWatchers()
	end
end)
radiusButton.MouseButton1Click:Connect(function()
	radiusIndex = radiusIndex + 1
	if radiusIndex > #radiusModes then
		radiusIndex = 1
	end
	nearRadius = radiusModes[radiusIndex]
	radiusButton.Text = "RADIO: " .. tostring(nearRadius)
	log("RADIUS", tostring(nearRadius))
end)
copyButton.MouseButton1Click:Connect(copyLogsToClipboard)
closeButton.MouseButton1Click:Connect(function()
	clearWatchConnections()
	screenGui:Destroy()
end)

log("BOOT", "scanner de barco listo")
