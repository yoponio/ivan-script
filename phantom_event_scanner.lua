if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local scannerVersion = "phantom-scanner-r1"
local maxStoredLogs = 2000
local storedLogs = {}
local autoWatch = false
local lastScanAt = 0
local watchConnections = {}
local statusLabel
local countLabel
local copyButton
local logBox
local watchButton
local candidateCopyButton
local saveButton
local highlightButton
local candidateLogs = {}
local candidateEntries = {}
local highlightObjects = {}
local highlightEnabled = false

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

local function trimArray(list, maxCount)
	while #list > maxCount do
		table.remove(list, 1)
	end
end

local function appendCandidateLog(message)
	table.insert(candidateLogs, message)
	trimArray(candidateLogs, maxStoredLogs)
	if candidateCopyButton then
		candidateCopyButton.Text = "COPIAR CAND. (" .. tostring(#candidateLogs) .. ")"
	end
end

local function appendCandidateEntry(entry)
	table.insert(candidateEntries, entry)
	trimArray(candidateEntries, 160)
end

local function clearHighlights()
	for _, highlight in ipairs(highlightObjects) do
		pcall(function()
			highlight:Destroy()
		end)
	end
	clearArray(highlightObjects)
end

local function resetCandidateState()
	clearArray(candidateLogs)
	clearArray(candidateEntries)
	clearHighlights()
	if candidateCopyButton then
		candidateCopyButton.Text = "COPIAR CAND. (0)"
	end
	if highlightButton then
		highlightButton.Text = highlightEnabled and "RESALTAR: ON" or "RESALTAR: OFF"
	end
end

local function copyPayloadToClipboard(payload)
	local copyFns = {setclipboard, toclipboard}
	for _, copyFn in ipairs(copyFns) do
		if type(copyFn) == "function" then
			local ok = pcall(copyFn, payload)
			if ok then
				return true
			end
		end
	end
	if type(Clipboard) == "table" and type(Clipboard.set) == "function" then
		local ok = pcall(function()
			Clipboard.set(payload)
		end)
		if ok then
			return true
		end
	end
	return false
end

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
		pcall(function()
			logBox.CursorPosition = #dump + 1
		end)
	end
end

local function log(eventName, details)
	local message = string.format("[PHANTOM][%.3f][%s] %s", os.clock(), tostring(eventName), tostring(details or ""))
	appendStoredLog(message)
end

local function copyLogsToClipboard()
	local payload = table.concat(storedLogs, "\n")
	if copyPayloadToClipboard(payload) then
		log("COPY", "logs copiados al portapapeles")
		return true
	end
	log("COPY_FAIL", "sin API de clipboard")
	return false
end

local function copyCandidatesToClipboard()
	if #candidateLogs == 0 then
		log("COPY_CAND_FAIL", "sin candidatos guardados")
		return false
	end
	local payload = table.concat(candidateLogs, "\n")
	if copyPayloadToClipboard(payload) then
		log("COPY_CAND", "candidatos copiados al portapapeles")
		return true
	end
	log("COPY_CAND_FAIL", "sin API de clipboard")
	return false
end

local function saveLogsToFile()
	if type(writefile) ~= "function" then
		log("SAVE_FAIL", "writefile no disponible en este ejecutor")
		return false
	end
	local timestamp = os.date("%Y%m%d_%H%M%S")
	local fileName = "phantom_scan_" .. tostring(timestamp) .. ".txt"
	local payload = table.concat(storedLogs, "\n")
	local ok, err = pcall(function()
		writefile(fileName, payload)
	end)
	if ok then
		log("SAVE", "archivo guardado: " .. fileName)
		return true
	end
	log("SAVE_FAIL", tostring(err or "error desconocido"))
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
		if safeIsA(instance, "BasePart") then
			return instance.Position
		end
		if safeIsA(instance, "Attachment") then
			return instance.WorldPosition
		end
		if safeIsA(instance, "Model") then
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

local function resolveHighlightAdornee(instance)
	if not instance then
		return nil
	end
	if safeIsA(instance, "Model") or safeIsA(instance, "BasePart") then
		return instance
	end
	local parent = instance.Parent
	if safeIsA(parent, "Model") or safeIsA(parent, "BasePart") then
		return parent
	end
	local ancestorModel = nil
	pcall(function()
		ancestorModel = instance:FindFirstAncestorWhichIsA("Model")
	end)
	if ancestorModel then
		return ancestorModel
	end
	local ancestorPart = nil
	pcall(function()
		ancestorPart = instance:FindFirstAncestorWhichIsA("BasePart")
	end)
	return ancestorPart
end

local function refreshHighlights()
	clearHighlights()
	if not highlightEnabled then
		return
	end
	local seen = {}
	for index = 1, math.min(12, #candidateEntries) do
		local entry = candidateEntries[index]
		local adornee = resolveHighlightAdornee(entry.instance)
		if adornee and not seen[adornee] then
			seen[adornee] = true
			local highlight = Instance.new("Highlight")
			highlight.Name = "PhantomScannerHighlight"
			highlight.FillColor = Color3.fromRGB(60, 190, 255)
			highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
			highlight.FillTransparency = 0.45
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Adornee = adornee
			highlight.Parent = workspace
			table.insert(highlightObjects, highlight)
		end
	end
	if highlightButton then
		highlightButton.Text = highlightEnabled and "RESALTAR: ON" or "RESALTAR: OFF"
		highlightButton.BackgroundColor3 = highlightEnabled and Color3.fromRGB(45, 100, 130) or Color3.fromRGB(45, 50, 55)
	end
	log("HIGHLIGHT", highlightEnabled and ("resaltados=" .. tostring(#highlightObjects)) or "resaltado desactivado")
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
	if safeIsA(instance, "ProximityPrompt") then
		score = score + 12
	end
	if safeIsA(instance, "ClickDetector") then
		score = score + 7
	end
	if safeIsA(instance, "Tool") then
		score = score + 4
	end
	if safeIsA(instance, "TextButton") then
		score = score + 6
	end
	if safeIsA(instance, "BillboardGui") or safeIsA(instance, "SurfaceGui") then
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

	local summary = string.format("[PHANTOM][%.3f][SCAN_%s] candidatos=%d", os.clock(), tostring(label), #results)
	appendCandidateLog(summary)
	log("SCAN_" .. label, "candidatos=" .. tostring(#results))
	for index = 1, math.min(limit or 30, #results) do
		local entry = results[index]
		appendCandidateEntry(entry)
		appendCandidateLog(
			string.format(
				"[PHANTOM][%.3f][%s] #%d score=%d class=%s keywords=%s %s path=%s",
				os.clock(),
				label,
				index,
				entry.score,
				entry.className,
				entry.matched ~= "" and entry.matched or "none",
				formatPosition(entry.position),
				entry.path
			)
		)
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

local function scanWorkspace(resetState)
	if resetState then
		resetCandidateState()
	end
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
	collectMatches(playerGui, "GUI", 40)
	local backpack = LP:FindFirstChildOfClass("Backpack")
	if backpack then
		collectMatches(backpack, "BACKPACK", 20)
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
	appendCandidateLog(string.format("[PHANTOM][%.3f][SCAN_NEAR] prompts=%d", os.clock(), #prompts))
	log("NEAR", "prompts encontrados=" .. tostring(#prompts))
	for index = 1, math.min(20, #prompts) do
		local entry = prompts[index]
		appendCandidateEntry({
			instance = entry.prompt,
			score = math.max(1, 100 - math.floor(entry.distance)),
			matched = tostring(entry.prompt.ActionText or "") .. "," .. tostring(entry.prompt.ObjectText or ""),
			className = "ProximityPrompt",
			path = entry.path,
			position = entry.position,
		})
		appendCandidateLog(
			string.format(
				"[PHANTOM][%.3f][NEAR] #%d dist=%.1f action=%s object=%s %s path=%s",
				os.clock(),
				index,
				entry.distance,
				tostring(entry.prompt.ActionText or ""),
				tostring(entry.prompt.ObjectText or ""),
				formatPosition(entry.position),
				entry.path
			)
		)
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
	refreshHighlights()
end

local function clearWatchConnections()
	for _, connection in ipairs(watchConnections) do
		connection:Disconnect()
	end
	clearArray(watchConnections)
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
			appendCandidateEntry({
				instance = descendant,
				score = score,
				matched = matched,
				className = safeClassName(descendant),
				path = safePath(descendant),
				position = safeWorldPosition(descendant),
			})
			appendCandidateLog(string.format("[PHANTOM][%.3f][ADD_WORLD] score=%d keywords=%s class=%s path=%s", os.clock(), score, matched ~= "" and matched or "none", safeClassName(descendant), safePath(descendant)))
			log("ADD_WORLD", string.format("score=%d keywords=%s class=%s path=%s", score, matched ~= "" and matched or "none", safeClassName(descendant), safePath(descendant)))
			refreshHighlights()
		end
	end))

	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		table.insert(watchConnections, playerGui.DescendantAdded:Connect(function(descendant)
			local score, matched = scoreInstance(descendant)
			if score > 0 then
				appendCandidateEntry({
					instance = descendant,
					score = score,
					matched = matched,
					className = safeClassName(descendant),
					path = safePath(descendant),
					position = safeWorldPosition(descendant),
				})
				appendCandidateLog(string.format("[PHANTOM][%.3f][ADD_GUI] score=%d keywords=%s class=%s path=%s", os.clock(), score, matched ~= "" and matched or "none", safeClassName(descendant), safePath(descendant)))
				log("ADD_GUI", string.format("score=%d keywords=%s class=%s path=%s", score, matched ~= "" and matched or "none", safeClassName(descendant), safePath(descendant)))
				refreshHighlights()
			end
		end))
	end
end

local guiParent = getGuiParent()

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
frame.Size = UDim2.new(0, 460, 0, 420)
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

statusLabel = Instance.new("TextLabel")
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
watchButton = makeButton("Watch", "AUTO WATCH: OFF", 328, 122)

copyButton = makeButton("Copy", "COPIAR LOGS (0)", 10, 140)
copyButton.Position = UDim2.new(0, 10, 0, buttonY + 34)

local fullButton = makeButton("FullScan", "FULL SCAN", 156, 92)
fullButton.Position = UDim2.new(0, 156, 0, buttonY + 34)

local clearButton = makeButton("Clear", "LIMPIAR", 254, 80)
clearButton.Position = UDim2.new(0, 254, 0, buttonY + 34)

candidateCopyButton = makeButton("CopyCandidates", "COPIAR CAND. (0)", 10, 140)
candidateCopyButton.Position = UDim2.new(0, 10, 0, buttonY + 68)

saveButton = makeButton("SaveLogs", "GUARDAR LOGS", 156, 110)
saveButton.Position = UDim2.new(0, 156, 0, buttonY + 68)

highlightButton = makeButton("Highlight", "RESALTAR: OFF", 272, 128)
highlightButton.Position = UDim2.new(0, 272, 0, buttonY + 68)

countLabel = Instance.new("TextLabel")
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
keywordLabel.Position = UDim2.new(0, 10, 0, buttonY + 104)
keywordLabel.BackgroundTransparency = 1
keywordLabel.Text = "Keywords: phantom, orb, sphere, spirit, ghost, boat, ship, dock, harbor, deliver, submit, return, deposit, collect"
keywordLabel.TextWrapped = true
keywordLabel.TextColor3 = Color3.fromRGB(180, 190, 200)
keywordLabel.Font = Enum.Font.Gotham
keywordLabel.TextSize = 11
keywordLabel.TextXAlignment = Enum.TextXAlignment.Left
keywordLabel.TextYAlignment = Enum.TextYAlignment.Top

logBox = Instance.new("TextBox")
logBox.Parent = frame
logBox.Size = UDim2.new(1, -20, 1, -(buttonY + 154))
logBox.Position = UDim2.new(0, 10, 0, buttonY + 144)
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
	log("FULL", "iniciando escaneo completo")
	resetCandidateState()
	scanWorkspace(false)
	scanGui(false)
	inspectNearestPrompts(false)
end)
copyButton.MouseButton1Click:Connect(copyLogsToClipboard)
candidateCopyButton.MouseButton1Click:Connect(copyCandidatesToClipboard)
saveButton.MouseButton1Click:Connect(saveLogsToFile)
clearButton.MouseButton1Click:Connect(function()
	clearArray(storedLogs)
	resetCandidateState()
	appendStoredLog("[PHANTOM][0.000][RESET] logs limpiados")
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

closeButton.MouseButton1Click:Connect(function()
	clearWatchConnections()
	clearHighlights()
	screenGui:Destroy()
end)

log("BOOT", "scanner listo version=" .. scannerVersion)
log("TIP", "usa FULL SCAN cuando empiece el evento y luego AUTO WATCH")
