local gameLoaded = true
pcall(function()
	if type(game.IsLoaded) == "function" then
		gameLoaded = game:IsLoaded()
	end
end)
if not gameLoaded then
	pcall(function()
		if game.Loaded and type(game.Loaded.Wait) == "function" then
			game.Loaded:Wait()
		end
	end)
end

local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local scannerVersion = "tower-tsunami-ready-scanner-r1"
local maxStoredLogs = 1500
local storedLogs = {}
local candidateLogs = {}
local candidateEntries = {}
local watchConnections = {}
local highlightObjects = {}
local highlightEnabled = false
local autoWatch = false
local scanInProgress = false

local statusLabel
local countLabel
local copyLogsButton
local copyCandidatesButton
local watchButton
local highlightButton
local logBox

local sharedEnv = nil
pcall(function()
	sharedEnv = type(getgenv) == "function" and getgenv() or _G
end)
if type(sharedEnv) ~= "table" then
	sharedEnv = _G
end

sharedEnv.TowerTsunamiState = sharedEnv.TowerTsunamiState or {}
local tsunamiState = sharedEnv.TowerTsunamiState
tsunamiState.useReadyGate = true
tsunamiState.scannerVersion = scannerVersion
tsunamiState.scannerActive = true
if tsunamiState.ready == nil then
	tsunamiState.ready = false
end
if tsunamiState.cooldownUntil == nil then
	tsunamiState.cooldownUntil = 0
end

local keywords = {
	"tower tsunami",
	"tower",
	"tsunami",
	"brainrot",
	"brainrots",
	"claim",
	"reward",
	"redeem",
	"submit",
	"deliver",
	"deposit",
	"exchange",
	"activate",
	"altar",
	"collector",
	"collect",
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

local function trimArray(list, maxCount)
	while #list > maxCount do
		table.remove(list, 1)
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

local function safeText(instance)
	if not instance then
		return ""
	end
	local chunks = {}
	pcall(function()
		if type(instance.Name) == "string" then
			table.insert(chunks, instance.Name)
		end
	end)
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

local function safeWorldPosition(instance)
	if not instance then
		return nil
	end
	local ok, value = pcall(function()
		if safeIsA(instance, "BasePart") then
			return instance.Position
		end
		if safeIsA(instance, "Attachment") then
			return instance.WorldPosition
		end
		if safeIsA(instance, "Model") then
			return instance:GetPivot().Position
		end
		local ancestorModel = instance:FindFirstAncestorWhichIsA("Model")
		if ancestorModel then
			return ancestorModel:GetPivot().Position
		end
		local ancestorPart = instance:FindFirstAncestorWhichIsA("BasePart")
		if ancestorPart then
			return ancestorPart.Position
		end
		return nil
	end)
	return ok and value or nil
end

local function formatPosition(position)
	if not position then
		return "pos=nil"
	end
	return string.format("pos=(%.1f, %.1f, %.1f)", position.X, position.Y, position.Z)
end

local function copyPayloadToClipboard(payload)
	local copyFns = {setclipboard, toclipboard}
	for _, copyFn in ipairs(copyFns) do
		if type(copyFn) == "function" and pcall(copyFn, payload) then
			return true
		end
	end
	return false
end

local function refreshLogUi()
	if countLabel then
		countLabel.Text = "LOGS: " .. tostring(#storedLogs)
	end
	if copyLogsButton then
		copyLogsButton.Text = "COPIAR LOGS (" .. tostring(#storedLogs) .. ")"
	end
	if copyCandidatesButton then
		copyCandidatesButton.Text = "COPIAR CAND. (" .. tostring(#candidateLogs) .. ")"
	end
	if logBox then
		local dump = table.concat(storedLogs, "\n")
		logBox.Text = dump
		pcall(function()
			logBox.CursorPosition = #dump + 1
		end)
	end
end

local function appendStoredLog(message)
	table.insert(storedLogs, message)
	trimArray(storedLogs, maxStoredLogs)
	print(message)
	if statusLabel then
		statusLabel.Text = message
	end
	refreshLogUi()
end

local function appendCandidateLog(message)
	table.insert(candidateLogs, message)
	trimArray(candidateLogs, maxStoredLogs)
	refreshLogUi()
end

local function log(eventName, details)
	appendStoredLog(string.format("[TSUNAMI][%.3f][%s] %s", os.clock(), tostring(eventName), tostring(details or "")))
end

local function hasKeyword(haystack, keyword)
	return haystack:find(keyword, 1, true) ~= nil
end

local function scoreInstance(instance)
	if not instance then
		return 0, ""
	end
	local haystack = safeText(instance) .. " | " .. string.lower(safePath(instance))
	local score = 0
	local matched = {}
	for _, keyword in ipairs(keywords) do
		if hasKeyword(haystack, keyword) then
			score = score + 5
			table.insert(matched, keyword)
		end
	end
	if safeIsA(instance, "ProximityPrompt") then
		score = score + 12
	end
	if safeIsA(instance, "TextButton") then
		score = score + 6
	end
	if safeIsA(instance, "TextLabel") then
		score = score + 4
	end
	if safeIsA(instance, "ClickDetector") then
		score = score + 7
	end
	return score, table.concat(matched, ",")
end

local function resolveHighlightAdornee(instance)
	if not instance then
		return nil
	end
	if safeIsA(instance, "Model") or safeIsA(instance, "BasePart") then
		return instance
	end
	local model = nil
	pcall(function()
		model = instance:FindFirstAncestorWhichIsA("Model")
	end)
	if model then
		return model
	end
	local part = nil
	pcall(function()
		part = instance:FindFirstAncestorWhichIsA("BasePart")
	end)
	return part
end

local function clearHighlights()
	for _, highlight in ipairs(highlightObjects) do
		pcall(function()
			highlight:Destroy()
		end)
	end
	clearArray(highlightObjects)
end

local function refreshHighlights()
	clearHighlights()
	if not highlightEnabled then
		if highlightButton then
			highlightButton.Text = "RESALTAR: OFF"
			highlightButton.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
		end
		return
	end
	local seen = {}
	for index = 1, math.min(12, #candidateEntries) do
		local entry = candidateEntries[index]
		local adornee = resolveHighlightAdornee(entry.instance)
		if adornee and not seen[adornee] then
			seen[adornee] = true
			local highlight = Instance.new("Highlight")
			highlight.Name = "TowerTsunamiReadyScannerHighlight"
			highlight.FillColor = Color3.fromRGB(40, 180, 255)
			highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
			highlight.FillTransparency = 0.45
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Adornee = adornee
			highlight.Parent = workspace
			table.insert(highlightObjects, highlight)
		end
	end
	if highlightButton then
		highlightButton.Text = "RESALTAR: ON"
		highlightButton.BackgroundColor3 = Color3.fromRGB(45, 100, 130)
	end
end

local function setSharedReadyState(ready, entry, sourceLabel, reason)
	tsunamiState.ready = ready == true
	tsunamiState.lastSeenAt = os.clock()
	tsunamiState.lastSource = sourceLabel or "unknown"
	tsunamiState.lastReason = reason or ""
	if entry then
		tsunamiState.bestScore = entry.score
		tsunamiState.bestPath = entry.path
		tsunamiState.bestMatched = entry.matched
		tsunamiState.bestClass = entry.className
		tsunamiState.bestPosition = entry.position
	end
end

local function isReadyCandidate(entry)
	if not entry then
		return false, nil
	end
	local haystack = safeText(entry.instance) .. " | " .. string.lower(entry.path)
	local hasTower = hasKeyword(haystack, "tower tsunami") or hasKeyword(haystack, "tower") or hasKeyword(haystack, "tsunami")
	if not hasTower then
		return false, nil
	end
	local hasAction = hasKeyword(haystack, "claim")
		or hasKeyword(haystack, "reward")
		or hasKeyword(haystack, "redeem")
		or hasKeyword(haystack, "submit")
		or hasKeyword(haystack, "deliver")
		or hasKeyword(haystack, "deposit")
		or hasKeyword(haystack, "exchange")
		or hasKeyword(haystack, "brainrot")
		or hasKeyword(haystack, "activate")
	if safeIsA(entry.instance, "ProximityPrompt") and (hasAction or entry.score >= 18) then
		return true, "prompt_ready"
	end
	if (safeIsA(entry.instance, "TextButton") or safeIsA(entry.instance, "TextLabel")) and hasAction and entry.score >= 16 then
		return true, "gui_ready"
	end
	return false, nil
	end

local function rememberCandidate(entry, sourceLabel)
	if not entry then
		return
	end
	table.insert(candidateEntries, entry)
	trimArray(candidateEntries, 160)
	if type(tsunamiState.bestScore) ~= "number" or entry.score >= tsunamiState.bestScore then
		tsunamiState.bestScore = entry.score
		tsunamiState.bestPath = entry.path
		tsunamiState.bestMatched = entry.matched
		tsunamiState.bestClass = entry.className
		tsunamiState.bestPosition = entry.position
	end
	local ready, reason = isReadyCandidate(entry)
	if ready then
		local summary = string.format("%s|%s|%d|%s", tostring(sourceLabel), tostring(entry.path), entry.score, tostring(reason))
		setSharedReadyState(true, entry, sourceLabel, reason)
		if tsunamiState.lastReadySummary ~= summary then
			tsunamiState.lastReadySummary = summary
			log("READY", string.format("source=%s score=%d reason=%s path=%s", tostring(sourceLabel), entry.score, tostring(reason), tostring(entry.path)))
		end
	end
end

local function resetCandidateState()
	clearArray(candidateEntries)
	clearArray(candidateLogs)
	clearHighlights()
	setSharedReadyState(false, nil, "reset", "reset_candidate_state")
	if statusLabel then
		statusLabel.Text = "Scanner reiniciado. Esperando activar la torre..."
	end
	refreshLogUi()
end

local function collectMatches(root, label, limit)
	local results = {}
	local descendants = root:GetDescendants()
	for _, descendant in ipairs(descendants) do
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

	appendCandidateLog(string.format("[TSUNAMI][%.3f][SCAN_%s] candidatos=%d", os.clock(), tostring(label), #results))
	log("SCAN_" .. label, "candidatos=" .. tostring(#results))
	for index = 1, math.min(limit or 30, #results) do
		local entry = results[index]
		rememberCandidate(entry, label)
		appendCandidateLog(string.format("[TSUNAMI][%.3f][%s] #%d score=%d class=%s keywords=%s %s path=%s", os.clock(), label, index, entry.score, entry.className, entry.matched ~= "" and entry.matched or "none", formatPosition(entry.position), entry.path))
		log(label, string.format("#%d score=%d class=%s keywords=%s %s path=%s", index, entry.score, entry.className, entry.matched ~= "" and entry.matched or "none", formatPosition(entry.position), entry.path))
	end
end

local function scanWorkspace(resetState)
	if resetState then
		resetCandidateState()
	end
	collectMatches(workspace, "WORLD", 40)
	local activeBrainrots = workspace:FindFirstChild("ActiveBrainrots")
	if activeBrainrots then
		collectMatches(activeBrainrots, "BRAINROTS", 20)
	end
	local towers = workspace:FindFirstChild("Towers") or workspace:FindFirstChild("Tower") or workspace:FindFirstChild("Events") or workspace:FindFirstChild("Event")
	if towers then
		collectMatches(towers, "TOWERS", 25)
	end
	refreshHighlights()
end

local function scanGui(resetState)
	if resetState then
		resetCandidateState()
	end
	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		log("SCAN_GUI", "sin PlayerGui")
		return
	end
	collectMatches(playerGui, "GUI", 30)
	local backpack = LP:FindFirstChildOfClass("Backpack")
	if backpack then
		collectMatches(backpack, "BACKPACK", 15)
	end
	refreshHighlights()
end

local function inspectNearestPrompts(resetState)
	if resetState then
		resetCandidateState()
	end
	local character = LP.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		log("NEAR", "sin HumanoidRootPart")
		return
	end
	local prompts = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if safeIsA(descendant, "ProximityPrompt") then
			local position = safeWorldPosition(descendant.Parent) or safeWorldPosition(descendant)
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
	appendCandidateLog(string.format("[TSUNAMI][%.3f][SCAN_NEAR] prompts=%d", os.clock(), #prompts))
	log("NEAR", "prompts encontrados=" .. tostring(#prompts))
	for index = 1, math.min(20, #prompts) do
		local entry = prompts[index]
		local candidate = {
			instance = entry.prompt,
			score = math.max(1, 100 - math.floor(entry.distance)),
			matched = tostring(entry.prompt.ActionText or "") .. "," .. tostring(entry.prompt.ObjectText or ""),
			className = "ProximityPrompt",
			path = entry.path,
			position = entry.position,
		}
		rememberCandidate(candidate, "NEAR")
		appendCandidateLog(string.format("[TSUNAMI][%.3f][NEAR] #%d dist=%.1f action=%s object=%s %s path=%s", os.clock(), index, entry.distance, tostring(entry.prompt.ActionText or ""), tostring(entry.prompt.ObjectText or ""), formatPosition(entry.position), entry.path))
		log("NEAR", string.format("#%d dist=%.1f action=%s object=%s %s path=%s", index, entry.distance, tostring(entry.prompt.ActionText or ""), tostring(entry.prompt.ObjectText or ""), formatPosition(entry.position), entry.path))
	end
	refreshHighlights()
end

local function processWatchedDescendant(sourceLabel, descendant)
	local className = safeClassName(descendant)
	if not includeClasses[className] then
		return
	end
	local score, matched = scoreInstance(descendant)
	if score <= 0 then
		return
	end
	local entry = {
		instance = descendant,
		score = score,
		matched = matched,
		className = className,
		path = safePath(descendant),
		position = safeWorldPosition(descendant),
	}
	rememberCandidate(entry, sourceLabel)
	appendCandidateLog(string.format("[TSUNAMI][%.3f][%s] score=%d keywords=%s class=%s path=%s", os.clock(), sourceLabel, score, matched ~= "" and matched or "none", className, entry.path))
	log(sourceLabel, string.format("score=%d keywords=%s class=%s path=%s", score, matched ~= "" and matched or "none", className, entry.path))
	refreshHighlights()
end

local function clearWatchConnections()
	for _, connection in ipairs(watchConnections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	clearArray(watchConnections)
	autoWatch = false
	tsunamiState.scannerActive = false
	if watchButton then
		watchButton.Text = "AUTO WATCH: OFF"
		watchButton.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
	end
end

local function armWatchers()
	clearWatchConnections()
	autoWatch = true
	tsunamiState.scannerActive = true
	if watchButton then
		watchButton.Text = "AUTO WATCH: ON"
		watchButton.BackgroundColor3 = Color3.fromRGB(50, 110, 70)
	end
	log("WATCH", "escucha activa de workspace y gui")
	table.insert(watchConnections, workspace.DescendantAdded:Connect(function(descendant)
		task.spawn(function()
			processWatchedDescendant("ADD_WORLD", descendant)
		end)
	end))
	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		table.insert(watchConnections, playerGui.DescendantAdded:Connect(function(descendant)
			task.spawn(function()
				processWatchedDescendant("ADD_GUI", descendant)
			end)
		end))
	end
end

local guiParent = getGuiParent()
local oldGui = guiParent:FindFirstChild("TowerTsunamiReadyScannerGui")
if oldGui then
	oldGui:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TowerTsunamiReadyScannerGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = guiParent

local frame = Instance.new("Frame")
frame.Parent = screenGui
frame.Size = UDim2.new(0, 500, 0, 420)
frame.Position = UDim2.new(0.04, 0, 0.16, 0)
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
title.Text = "TOWER TSUNAMI READY SCANNER " .. scannerVersion
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
statusLabel.Size = UDim2.new(1, -20, 0, 18)
statusLabel.Position = UDim2.new(0, 10, 0, 42)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Activa la torre una vez, luego usa FULL SCAN y AUTO WATCH"
statusLabel.TextColor3 = Color3.fromRGB(215, 220, 225)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left

local function makeButton(name, text, x, y, width)
	local button = Instance.new("TextButton")
	button.Name = name
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

local worldButton = makeButton("WorldScan", "SCAN WORLD", 10, 70, 100)
local guiButton = makeButton("GuiScan", "SCAN GUI", 116, 70, 90)
local nearButton = makeButton("NearScan", "PROMPTS CERCA", 212, 70, 120)
watchButton = makeButton("Watch", "AUTO WATCH: OFF", 338, 70, 148)
local fullButton = makeButton("FullScan", "FULL SCAN", 10, 104, 100)
copyLogsButton = makeButton("CopyLogs", "COPIAR LOGS (0)", 116, 104, 140)
copyCandidatesButton = makeButton("CopyCandidates", "COPIAR CAND. (0)", 262, 104, 150)
highlightButton = makeButton("Highlight", "RESALTAR: OFF", 418, 104, 68)
local resetButton = makeButton("Reset", "RESET", 418, 138, 68)

countLabel = Instance.new("TextLabel")
countLabel.Parent = frame
countLabel.Size = UDim2.new(0, 120, 0, 18)
countLabel.Position = UDim2.new(1, -130, 0, 144)
countLabel.BackgroundTransparency = 1
countLabel.Text = "LOGS: 0"
countLabel.TextColor3 = Color3.fromRGB(215, 220, 225)
countLabel.Font = Enum.Font.GothamBold
countLabel.TextSize = 12
countLabel.TextXAlignment = Enum.TextXAlignment.Right

local keywordLabel = Instance.new("TextLabel")
keywordLabel.Parent = frame
keywordLabel.Size = UDim2.new(1, -20, 0, 34)
keywordLabel.Position = UDim2.new(0, 10, 0, 138)
keywordLabel.BackgroundTransparency = 1
keywordLabel.Text = "Keywords: tower, tsunami, brainrot, claim, reward, redeem, submit, deliver, deposit, exchange, activate"
keywordLabel.TextWrapped = true
keywordLabel.TextColor3 = Color3.fromRGB(180, 190, 200)
keywordLabel.Font = Enum.Font.Gotham
keywordLabel.TextSize = 11
keywordLabel.TextXAlignment = Enum.TextXAlignment.Left
keywordLabel.TextYAlignment = Enum.TextYAlignment.Top

logBox = Instance.new("TextBox")
logBox.Parent = frame
logBox.Size = UDim2.new(1, -20, 1, -182)
logBox.Position = UDim2.new(0, 10, 0, 172)
logBox.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
logBox.TextColor3 = Color3.fromRGB(220, 225, 230)
logBox.Font = Enum.Font.Code
logBox.TextSize = 12
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.Text = ""
logBox.BorderSizePixel = 0
Instance.new("UICorner", logBox)

worldButton.MouseButton1Click:Connect(function()
	scanWorkspace(true)
end)

guiButton.MouseButton1Click:Connect(function()
	scanGui(true)
end)

nearButton.MouseButton1Click:Connect(function()
	inspectNearestPrompts(true)
end)

fullButton.MouseButton1Click:Connect(function()
	if scanInProgress then
		log("FULL_BUSY", "ya hay un full scan en curso")
		return
	end
	scanInProgress = true
	fullButton.Text = "ESCANEANDO..."
	fullButton.BackgroundColor3 = Color3.fromRGB(90, 80, 45)
	task.spawn(function()
		local ok, err = xpcall(function()
			resetCandidateState()
			scanWorkspace(false)
			task.wait()
			scanGui(false)
			task.wait()
			inspectNearestPrompts(false)
			log("FULL_OK", "escaneo completo terminado")
		end, debug.traceback)
		scanInProgress = false
		fullButton.Text = "FULL SCAN"
		fullButton.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
		if not ok then
			log("FULL_ERR", tostring(err))
		end
	end)
end)

copyLogsButton.MouseButton1Click:Connect(function()
	if copyPayloadToClipboard(table.concat(storedLogs, "\n")) then
		log("COPY", "logs copiados")
	else
		log("COPY_FAIL", "clipboard no disponible")
	end
end)

copyCandidatesButton.MouseButton1Click:Connect(function()
	if copyPayloadToClipboard(table.concat(candidateLogs, "\n")) then
		log("COPY_CAND", "candidatos copiados")
	else
		log("COPY_CAND_FAIL", "clipboard no disponible")
	end
end)

highlightButton.MouseButton1Click:Connect(function()
	highlightEnabled = not highlightEnabled
	refreshHighlights()
end)

watchButton.MouseButton1Click:Connect(function()
	if autoWatch then
		clearWatchConnections()
		log("WATCH", "escucha desactivada")
	else
		armWatchers()
	end
end)

resetButton.MouseButton1Click:Connect(function()
	clearArray(storedLogs)
	resetCandidateState()
	appendStoredLog("[TSUNAMI][0.000][RESET] logs limpiados")
end)

closeButton.MouseButton1Click:Connect(function()
	clearWatchConnections()
	clearHighlights()
	tsunamiState.scannerActive = false
	screenGui:Destroy()
end)

refreshLogUi()
log("BOOT", "scanner listo version=" .. scannerVersion)
log("TIP", "activa la torre, usa FULL SCAN y luego AUTO WATCH para dejar el ready gate armado")
