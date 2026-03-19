if not game:IsLoaded() then
	game.Loaded:Wait()
end

local function safeGetService(serviceName)
	local service = nil
	pcall(function()
		local getter = game and game.GetService
		if type(getter) == "function" then
			service = getter(game, serviceName)
		end
	end)
	if service then
		return service
	end
	pcall(function()
		service = game[serviceName]
	end)
	return service
end

local Players = safeGetService("Players")
local RunService = safeGetService("RunService")
local ProximityPromptService = safeGetService("ProximityPromptService")
local CoreGui = safeGetService("CoreGui")
if not Players or not RunService or not CoreGui then
	return
end

local LP = Players.LocalPlayer
if not LP then
	return
end

local observerGuiName = "EscanerObserver"
local scannerVersion = "escaner-r3-godtrace"
local maxStoredLogs = 1200
local maxVisibleLogs = 180
local clipboardChunkSize = 90000
local storedLogs = {}
local storedCharCount = 0
local observerEnabled = true
local observerClosed = false
local captureMode = "ALL"
local pollInterval = 0.35
local guiPollInterval = 1.10
local nearbyScanInterval = 3.50
local moveThreshold = 6
local logBox
local statusLabel
local countLabel
local copyButton
local copyChunkButton
local copyRecentButton
local clearButton
local saveButton
local watchButton
local filterButton
local closeButton
local sharedStateLabel
local exportPageLabel
local mainLoopThread
local activeBrainrotsConn
local characterAddedConn
local healthConn
local stateConn
local characterToolAddedConn
local characterToolRemovedConn
local backpackToolAddedConn
local backpackToolRemovedConn
local characterDescendantAddedConn
local promptConnections = {}
local godTraceConnections = {}
local hazardTouchConnections = {}
local lastMovePosition = nil
local lastMoveAt = 0
local lastGuiSnapshot = ""
local lastNearbyPromptSnapshot = ""
local lastInventorySnapshot = ""
local lastSharedSnapshot = ""
local lastActivePromptState = {}
local exportChunkIndex = 1
local uiRefreshQueued = false
local nearbyPromptScanEnabled = false
local lastGodHumanoidSnapshot = ""
local lastGodRootSnapshot = ""
local lastCharacterPartsSnapshot = ""
local lastHazardSnapshot = ""
local lastHazardTouchSignature = ""

local sharedEnv = nil
pcall(function()
	sharedEnv = type(getgenv) == "function" and getgenv() or _G
end)
if type(sharedEnv) ~= "table" then
	sharedEnv = _G
end

local interestingKeywords = {
	"tower",
	"tsunami",
	"brainrot",
	"submit",
	"deliver",
	"deposit",
	"reward",
	"claim",
	"redeem",
	"confirm",
	"yes",
	"collector",
	"altar",
	"ready",
	"cooldown",
	"trial",
	"wave",
}

local hazardKeywords = {
	"wave",
	"water",
	"tsunami",
	"acid",
	"lava",
	"kill",
	"damage",
	"dead",
	"void",
	"storm",
	"flood",
}

local captureModes = {
	{"ALL", "todo"},
	{"CORE", "sin MOVE"},
	{"TOWER", "tower puro"},
	{"GODTRACE", "vida y estados"},
}

local captureModeAllow = {
	ALL = {
		FLOW = true,
		PROMPT = true,
		GUI = true,
		INV = true,
		STATE = true,
		MOVE = true,
		WORLD = true,
		HEALTH = true,
		ERROR = true,
	},
	CORE = {
		FLOW = true,
		PROMPT = true,
		GUI = true,
		INV = true,
		STATE = true,
		WORLD = true,
		HEALTH = true,
		ERROR = true,
	},
	TOWER = {
		FLOW = true,
		PROMPT = true,
		GUI = true,
		INV = true,
		STATE = true,
		WORLD = true,
		ERROR = true,
	},
	GODTRACE = {
		FLOW = true,
		HEALTH = true,
		STATE = true,
		MOVE = true,
		INV = true,
		ERROR = true,
		GOD = true,
		HAZARD = true,
	},
}

local function clamp(value, minValue, maxValue)
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

local function safeIsA(instance, className)
	local ok, result = pcall(function()
		return instance and instance:IsA(className)
	end)
	return ok and result or false
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
	return CoreGui
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

local function safeName(instance)
	if not instance then
		return "nil"
	end
	local ok, name = pcall(function()
		return instance.Name
	end)
	return ok and tostring(name) or "unknown"
end

local function safeText(instance)
	if not instance then
		return ""
	end
	local chunks = {}
	pcall(function()
		if type(instance.Name) == "string" and instance.Name ~= "" then
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
	return table.concat(chunks, " | ")
end

local function isInsideObserverGui(instance)
	local current = instance
	while current do
		if safeName(current) == observerGuiName then
			return true
		end
		current = current.Parent
	end
	return false
end

local function lowerText(instance)
	return string.lower(safeText(instance))
end

local function containsInterestingKeyword(text)
	if type(text) ~= "string" or text == "" then
		return false, nil
	end
	local lowered = string.lower(text)
	for _, keyword in ipairs(interestingKeywords) do
		if lowered:find(keyword, 1, true) then
			return true, keyword
		end
	end
	return false, nil
end

local function getCharacter()
	return LP.Character or LP.CharacterAdded:Wait()
end

local function getHumanoid()
	local character = LP.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
	local character = LP.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

local function formatVector(position)
	if not position then
		return "nil"
	end
	return string.format("%.1f,%.1f,%.1f", position.X, position.Y, position.Z)
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

local function getDistanceToPlayer(instance)
	local root = getRoot()
	local position = getWorldPosition(instance)
	if not root or not position then
		return nil
	end
	return (root.Position - position).Magnitude
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

local function getCaptureModeLabel()
	for _, entry in ipairs(captureModes) do
		if entry[1] == captureMode then
			return entry[1] .. " | " .. entry[2]
		end
	end
	return captureMode
end

local function shouldCaptureCategory(category)
	if category == nil then
		return true
	end
	local allow = captureModeAllow[captureMode]
	if not allow then
		return true
	end
	return allow[tostring(category)] == true
end

local function cycleCaptureMode()
	local currentIndex = 1
	for index, entry in ipairs(captureModes) do
		if entry[1] == captureMode then
			currentIndex = index
			break
		end
	end
	currentIndex = currentIndex + 1
	if currentIndex > #captureModes then
		currentIndex = 1
	end
	captureMode = captureModes[currentIndex][1]
end

local function refreshUi()
	if observerClosed then
		return
	end
	uiRefreshQueued = false
	local payloadLength = storedCharCount
	local chunkCount = math.max(1, math.ceil(payloadLength / clipboardChunkSize))
	exportChunkIndex = clamp(exportChunkIndex, 1, chunkCount)
	if countLabel then
		countLabel.Text = "LOGS: " .. tostring(#storedLogs)
	end
	if copyButton then
		copyButton.Text = "COPIAR LOGS (" .. tostring(#storedLogs) .. ")"
	end
	if copyChunkButton then
		copyChunkButton.Text = "COPIAR PARTE"
	end
	if copyRecentButton then
		copyRecentButton.Text = "COPIAR 200"
	end
	if exportPageLabel then
		exportPageLabel.Text = "PARTE " .. tostring(exportChunkIndex) .. "/" .. tostring(chunkCount)
	end
	if watchButton then
		watchButton.Text = observerEnabled and "ESCUCHA: ON" or "ESCUCHA: OFF"
		watchButton.BackgroundColor3 = observerEnabled and Color3.fromRGB(60, 135, 80) or Color3.fromRGB(85, 85, 95)
	end
	if filterButton then
		filterButton.Text = "FILTRO: " .. getCaptureModeLabel()
	end
	if logBox then
		local startIndex = math.max(1, #storedLogs - maxVisibleLogs + 1)
		local visibleLogs = {}
		for index = startIndex, #storedLogs do
			table.insert(visibleLogs, storedLogs[index])
		end
		local dump = table.concat(visibleLogs, "\n")
		logBox.Text = dump
		pcall(function()
			logBox.CursorPosition = #dump + 1
		end)
	end
	if sharedStateLabel and lastSharedSnapshot ~= "" then
		sharedStateLabel.Text = "STATE: " .. lastSharedSnapshot
	elseif sharedStateLabel then
		sharedStateLabel.Text = "STATE: sin shared state"
	end
	if statusLabel and #storedLogs > 0 then
		statusLabel.Text = storedLogs[#storedLogs]
	end
end

local function scheduleUiRefresh()
	if uiRefreshQueued or observerClosed then
		return
	end
	uiRefreshQueued = true
	task.delay(0.12, function()
		if observerClosed then
			return
		end
		local ok, err = xpcall(refreshUi, debug.traceback)
		if not ok then
			warn("[ESCANER][UI_REFRESH_ERR] " .. tostring(err))
			uiRefreshQueued = false
		end
	end)
end

local function getStoredLogDump()
	return table.concat(storedLogs, "\n")
end

local function getRecentLogDump(limit)
	local startIndex = math.max(1, #storedLogs - (limit or 200) + 1)
	local lines = {}
	for index = startIndex, #storedLogs do
		table.insert(lines, storedLogs[index])
	end
	return table.concat(lines, "\n")
end

local function getClipboardChunkCount()
	local payloadLength = storedCharCount
	return math.max(1, math.ceil(payloadLength / clipboardChunkSize))
end

local function getClipboardChunk(index)
	local payload = getStoredLogDump()
	if payload == "" then
		return "", 1, 1
	end
	local chunkCount = getClipboardChunkCount()
	local safeIndex = clamp(index or 1, 1, chunkCount)
	local startPos = ((safeIndex - 1) * clipboardChunkSize) + 1
	local endPos = math.min(startPos + clipboardChunkSize - 1, #payload)
	local header = string.format("[ESCANER_EXPORT part=%d/%d chars=%d-%d]\n", safeIndex, chunkCount, startPos, endPos)
	return header .. string.sub(payload, startPos, endPos), safeIndex, chunkCount
end

local function appendStoredLog(message)
	table.insert(storedLogs, message)
	storedCharCount = storedCharCount + #message + 1
	while #storedLogs > maxStoredLogs do
		local removed = table.remove(storedLogs, 1)
		storedCharCount = math.max(0, storedCharCount - (#removed + 1))
	end
	print(message)
	scheduleUiRefresh()
end

local function log(category, action, entity, details)
	if observerClosed then
		return
	end
	if not shouldCaptureCategory(category) then
		return
	end
	local message = string.format(
		"[ESCANER][%.3f][%s][%s] %s | %s",
		os.clock(),
		tostring(category or "GEN"),
		tostring(action or "EVENT"),
		tostring(entity or "-"),
		tostring(details or "")
	)
	appendStoredLog(message)
	return message
end

local function disconnectConnection(conn)
	if conn then
		conn:Disconnect()
	end
	return nil
end

local function clearConnectionList(list)
	for index = #list, 1, -1 do
		local conn = list[index]
		if conn then
			conn:Disconnect()
		end
		list[index] = nil
	end
end

local function clearPromptConnections()
	for index = #promptConnections, 1, -1 do
		local conn = promptConnections[index]
		if conn then
			conn:Disconnect()
		end
		promptConnections[index] = nil
	end
end

local function clearHazardTouchConnections()
	clearConnectionList(hazardTouchConnections)
end

local function serializeToolCounts(counts)
	local parts = {}
	for name, count in pairs(counts) do
		table.insert(parts, tostring(name) .. "=" .. tostring(count))
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ",") or "vacio"
end

local function getToolCounts()
	local counts = {}
	local backpack = LP:FindFirstChildOfClass("Backpack")
	local character = LP.Character
	local equipped = 0

	local function collect(container, prefix)
		if not container then
			return
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				counts[prefix .. child.Name] = (counts[prefix .. child.Name] or 0) + 1
				if prefix == "character:" then
					equipped = equipped + 1
				end
			end
		end
	end

	collect(backpack, "backpack:")
	collect(character, "character:")
	return counts, equipped
end

local function logInventoryIfChanged(reason)
	local counts, equipped = getToolCounts()
	local snapshot = serializeToolCounts(counts) .. " | equipped=" .. tostring(equipped)
	if snapshot ~= lastInventorySnapshot then
		lastInventorySnapshot = snapshot
		log("INV", "SNAPSHOT", reason or "tools", snapshot)
	end
end

local function getCharacterPartsSnapshot(character)
	if not character then
		return ""
	end
	local totalParts = 0
	local nonCollideCount = 0
	local nonTouchCount = 0
	local anchoredCount = 0
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			totalParts = totalParts + 1
			if not descendant.CanCollide then
				nonCollideCount = nonCollideCount + 1
			end
			if not descendant.CanTouch then
				nonTouchCount = nonTouchCount + 1
			end
			if descendant.Anchored then
				anchoredCount = anchoredCount + 1
			end
		end
	end
	return string.format("parts=%d nocollide=%d notouch=%d anchored=%d", totalParts, nonCollideCount, nonTouchCount, anchoredCount)
end

local function containsKeyword(list, text)
	if type(text) ~= "string" or text == "" then
		return false, nil
	end
	local lowered = string.lower(text)
	for _, keyword in ipairs(list) do
		if lowered:find(keyword, 1, true) then
			return true, keyword
		end
	end
	return false, nil
end

local function isHazardPart(part)
	if not part or not part:IsA("BasePart") then
		return false, nil
	end
	local matched, keyword = containsKeyword(hazardKeywords, safeName(part) .. " | " .. safePath(part))
	if matched then
		return true, keyword
	end
	local materialName = ""
	pcall(function()
		materialName = part.Material.Name
	end)
	if materialName ~= "" then
		matched, keyword = containsKeyword(hazardKeywords, materialName)
		if matched then
			return true, keyword
		end
	end
	return false, nil
end

local function getNearbyHazardSnapshot(root)
	if not root then
		return ""
	end
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Blacklist
	overlapParams.FilterDescendantsInstances = {LP.Character}
	overlapParams.MaxParts = 40
	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInBox(root.CFrame, Vector3.new(18, 12, 18), overlapParams)
	end)
	if not ok or type(parts) ~= "table" then
		return ""
	end
	local matches = {}
	for _, part in ipairs(parts) do
		local hazard, keyword = isHazardPart(part)
		if hazard then
			table.insert(matches, string.format("path=%s keyword=%s dist=%s", safePath(part), tostring(keyword or "unknown"), tostring(getDistanceToPlayer(part) and string.format("%.1f", getDistanceToPlayer(part)) or "nil")))
		end
	end
	table.sort(matches)
	if #matches > 6 then
		while #matches > 6 do
			table.remove(matches)
		end
	end
	return table.concat(matches, " || ")
end

local function logHazardSnapshot(reason)
	if captureMode ~= "GODTRACE" then
		return
	end
	local snapshot = getNearbyHazardSnapshot(getRoot())
	if snapshot ~= "" then
		lastHazardSnapshot = snapshot
		log("HAZARD", "NEAR", reason or "scan", snapshot)
	else
		log("HAZARD", "NEAR", reason or "scan", "sin hazards cercanos detectados")
	end
end

local function attachHazardTouchHooks(character)
	clearHazardTouchConnections()
	if not character then
		return
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(hazardTouchConnections, descendant.Touched:Connect(function(otherPart)
				if observerClosed or not observerEnabled or captureMode ~= "GODTRACE" then
					return
				end
				local hazard, keyword = isHazardPart(otherPart)
				if not hazard then
					return
				end
				local signature = safePath(descendant) .. "->" .. safePath(otherPart)
				if signature == lastHazardTouchSignature then
					return
				end
				lastHazardTouchSignature = signature
				log("HAZARD", "TOUCH", safeName(descendant), string.format("other=%s keyword=%s", safePath(otherPart), tostring(keyword or "unknown")))
			end))
		end
	end
end

local function attachGodTracePropertyHook(instance, propertyName, category, action)
	if not instance then
		return
	end
	table.insert(godTraceConnections, instance:GetPropertyChangedSignal(propertyName):Connect(function()
		if observerClosed or not observerEnabled or captureMode ~= "GODTRACE" then
			return
		end
		local value = nil
		pcall(function()
			value = instance[propertyName]
		end)
		log(category, action, safeName(instance), propertyName .. "=" .. tostring(value) .. " path=" .. safePath(instance))
	end))
end

local function attachGodTracePartHooks(part)
	if not part or not part:IsA("BasePart") then
		return
	end
	attachGodTracePropertyHook(part, "CanCollide", "GOD", "PART_PROP")
	attachGodTracePropertyHook(part, "CanTouch", "GOD", "PART_PROP")
	attachGodTracePropertyHook(part, "Anchored", "GOD", "PART_PROP")
end

local function attachGodTraceHooks(character, humanoid)
	clearConnectionList(godTraceConnections)
	characterDescendantAddedConn = disconnectConnection(characterDescendantAddedConn)

	if humanoid then
		attachGodTracePropertyHook(humanoid, "WalkSpeed", "GOD", "HUM_PROP")
		attachGodTracePropertyHook(humanoid, "JumpPower", "GOD", "HUM_PROP")
		attachGodTracePropertyHook(humanoid, "UseJumpPower", "GOD", "HUM_PROP")
		attachGodTracePropertyHook(humanoid, "HipHeight", "GOD", "HUM_PROP")
		attachGodTracePropertyHook(humanoid, "PlatformStand", "GOD", "HUM_PROP")
		attachGodTracePropertyHook(humanoid, "Sit", "GOD", "HUM_PROP")
		attachGodTracePropertyHook(humanoid, "BreakJointsOnDeath", "GOD", "HUM_PROP")
		attachGodTracePropertyHook(humanoid, "AutoRotate", "GOD", "HUM_PROP")
	end

	local root = character and character:FindFirstChild("HumanoidRootPart") or nil
	if root then
		attachGodTracePropertyHook(root, "Anchored", "GOD", "ROOT_PROP")
		attachGodTracePropertyHook(root, "CanCollide", "GOD", "ROOT_PROP")
		attachGodTracePropertyHook(root, "CanTouch", "GOD", "ROOT_PROP")
	end

	if character then
		for _, descendant in ipairs(character:GetDescendants()) do
			attachGodTracePartHooks(descendant)
		end

		characterDescendantAddedConn = character.DescendantAdded:Connect(function(descendant)
			if observerClosed then
				return
			end
			if descendant:IsA("BasePart") then
				attachGodTracePartHooks(descendant)
				if captureMode == "GODTRACE" and observerEnabled then
					log("GOD", "PART_ADD", safeName(descendant), safePath(descendant))
				end
			end
		end)
	end
end

local function pollGodTraceSignals()
	local character = LP.Character
	local humanoid = getHumanoid()
	local root = getRoot()

	if humanoid then
		local humanoidSnapshot = string.format(
			"hp=%.1f/%.1f ws=%.1f jp=%.1f useJump=%s hip=%.1f platform=%s state=%s sit=%s breakOnDeath=%s autoRotate=%s",
			humanoid.Health,
			humanoid.MaxHealth,
			humanoid.WalkSpeed,
			humanoid.JumpPower,
			tostring(humanoid.UseJumpPower),
			humanoid.HipHeight,
			tostring(humanoid.PlatformStand),
			humanoid:GetState().Name,
			tostring(humanoid.Sit),
			tostring(humanoid.BreakJointsOnDeath),
			tostring(humanoid.AutoRotate)
		)
		if humanoidSnapshot ~= lastGodHumanoidSnapshot then
			lastGodHumanoidSnapshot = humanoidSnapshot
			log("GOD", "HUMANOID", "Humanoid", humanoidSnapshot)
		end
	end

	if root then
		local rootSnapshot = string.format(
			"pos=(%s) vel=%.2f anchored=%s canCollide=%s canTouch=%s",
			formatVector(root.Position),
			root.AssemblyLinearVelocity.Magnitude,
			tostring(root.Anchored),
			tostring(root.CanCollide),
			tostring(root.CanTouch)
		)
		if rootSnapshot ~= lastGodRootSnapshot then
			lastGodRootSnapshot = rootSnapshot
			log("GOD", "ROOT", "HumanoidRootPart", rootSnapshot)
		end
	end

	if character then
		local partsSnapshot = getCharacterPartsSnapshot(character)
		if partsSnapshot ~= lastCharacterPartsSnapshot then
			lastCharacterPartsSnapshot = partsSnapshot
			log("GOD", "PARTS", safeName(character), partsSnapshot)
		end
	end

	local hazardSnapshot = getNearbyHazardSnapshot(root)
	if hazardSnapshot ~= "" and hazardSnapshot ~= lastHazardSnapshot then
		lastHazardSnapshot = hazardSnapshot
		log("HAZARD", "NEAR", "HumanoidRootPart", hazardSnapshot)
	end
end

local function serializeScalar(value)
	local valueType = typeof and typeof(value) or type(value)
	if valueType == "Vector3" then
		return formatVector(value)
	end
	if valueType == "CFrame" then
		local pos = value.Position
		return formatVector(pos)
	end
	if type(value) == "Instance" then
		return safePath(value)
	end
	if type(value) == "table" then
		return "table"
	end
	return tostring(value)
end

local function pollSharedState()
	local state = sharedEnv and sharedEnv.TowerTsunamiState
	if type(state) ~= "table" then
		if lastSharedSnapshot ~= "" then
			lastSharedSnapshot = ""
			refreshUi()
		end
		return
	end

	local keys = {}
	for key, value in pairs(state) do
		if type(value) ~= "function" and type(value) ~= "userdata" and type(value) ~= "thread" then
			table.insert(keys, tostring(key) .. "=" .. serializeScalar(value))
		end
	end
	table.sort(keys)
	local snapshot = #keys > 0 and table.concat(keys, " ; ") or "vacio"
	if snapshot ~= lastSharedSnapshot then
		lastSharedSnapshot = snapshot
		log("STATE", "SHARED", "TowerTsunamiState", snapshot)
	end
	scheduleUiRefresh()
end

local function buildPromptDetails(prompt)
	local distance = getDistanceToPlayer(prompt)
	return string.format(
		"path=%s action=%s object=%s enabled=%s hold=%.2f max=%.1f dist=%s",
		safePath(prompt),
		tostring(prompt and prompt.ActionText or ""),
		tostring(prompt and prompt.ObjectText or ""),
		tostring(prompt and prompt.Enabled),
		prompt and prompt.HoldDuration or -1,
		prompt and prompt.MaxActivationDistance or -1,
		distance and string.format("%.1f", distance) or "nil"
	)
end

local function shouldLogPrompt(prompt)
	if not prompt then
		return false
	end
	local combined = lowerText(prompt)
	local matched = containsInterestingKeyword(combined)
	if matched then
		return true
	end
	return false
end

local function attachPromptHooks()
	if not ProximityPromptService then
		return
	end
	clearPromptConnections()

	local function register(name, handler)
		local signal = ProximityPromptService[name]
		if signal then
			table.insert(promptConnections, signal:Connect(handler))
		end
	end

	register("PromptShown", function(prompt, inputType)
		if not observerEnabled or not shouldLogPrompt(prompt) then
			return
		end
		lastActivePromptState[safePath(prompt)] = true
		log("PROMPT", "SHOWN", safeName(prompt), buildPromptDetails(prompt) .. " input=" .. tostring(inputType))
	end)

	register("PromptHidden", function(prompt)
		if not observerEnabled or not shouldLogPrompt(prompt) then
			return
		end
		lastActivePromptState[safePath(prompt)] = nil
		log("PROMPT", "HIDDEN", safeName(prompt), buildPromptDetails(prompt))
	end)

	register("PromptTriggered", function(prompt, player)
		if not observerEnabled or not shouldLogPrompt(prompt) then
			return
		end
		log("PROMPT", "TRIGGERED", safeName(prompt), buildPromptDetails(prompt) .. " player=" .. tostring(player and player.Name or "nil"))
	end)

	register("PromptTriggerEnded", function(prompt, player)
		if not observerEnabled or not shouldLogPrompt(prompt) then
			return
		end
		log("PROMPT", "TRIGGER_END", safeName(prompt), buildPromptDetails(prompt) .. " player=" .. tostring(player and player.Name or "nil"))
	end)

	register("PromptButtonHoldBegan", function(prompt, player)
		if not observerEnabled or not shouldLogPrompt(prompt) then
			return
		end
		log("PROMPT", "HOLD_BEGIN", safeName(prompt), buildPromptDetails(prompt) .. " player=" .. tostring(player and player.Name or "nil"))
	end)

	register("PromptButtonHoldEnded", function(prompt, player)
		if not observerEnabled or not shouldLogPrompt(prompt) then
			return
		end
		log("PROMPT", "HOLD_END", safeName(prompt), buildPromptDetails(prompt) .. " player=" .. tostring(player and player.Name or "nil"))
	end)
	end

local function isGuiVisible(instance)
	if not instance or not safeIsA(instance, "GuiObject") then
		return false
	end
	local current = instance
	while current do
		if safeIsA(current, "ScreenGui") then
			local enabled = true
			pcall(function()
				enabled = current.Enabled
			end)
			if not enabled then
				return false
			end
		elseif safeIsA(current, "GuiObject") then
			local visible = true
			pcall(function()
				visible = current.Visible
			end)
			if not visible then
				return false
			end
		end
		current = current.Parent
	end
	return true
end

local function getGuiArea(instance)
	local area = 0
	pcall(function()
		area = instance.AbsoluteSize.X * instance.AbsoluteSize.Y
	end)
	return area
end

local function collectGuiMatches(rootGui, results)
	if not rootGui then
		return
	end
	for _, descendant in ipairs(rootGui:GetDescendants()) do
		if not isInsideObserverGui(descendant)
		if (safeIsA(descendant, "TextLabel") or safeIsA(descendant, "TextButton")) and isGuiVisible(descendant) then
			local text = safeText(descendant)
			local matched, keyword = containsInterestingKeyword(text)
			if matched then
				table.insert(results, {
					path = safePath(descendant),
					text = text,
					keyword = keyword,
					area = getGuiArea(descendant),
				})
			end
		end
		end
	end
	end

local function pollGuiSignals()
	local results = {}
	local playerGui = LP:FindFirstChildOfClass("PlayerGui")
	collectGuiMatches(playerGui, results)
	collectGuiMatches(CoreGui, results)
	table.sort(results, function(a, b)
		if a.area ~= b.area then
			return a.area > b.area
		end
		return a.path < b.path
	end)

	local parts = {}
	for index, entry in ipairs(results) do
		if index > 10 then
			break
		end
		table.insert(parts, entry.keyword .. "|" .. entry.path .. "|" .. entry.text)
	end
	local snapshot = table.concat(parts, " || ")
	if snapshot ~= lastGuiSnapshot then
		lastGuiSnapshot = snapshot
		if snapshot ~= "" then
			log("GUI", "VISIBLE", "matches", snapshot)
		else
			log("GUI", "VISIBLE", "matches", "sin coincidencias activas")
		end
	end
	end

local function isInterestingBrainrot(descendant)
	if not descendant then
		return false
	end
	local name = string.lower(safeName(descendant))
	return name == "renderedbrainrot" or name:find("brainrot", 1, true) ~= nil
	end

local function bindActiveBrainrots()
	activeBrainrotsConn = disconnectConnection(activeBrainrotsConn)
	local activeBrainrots = workspace:FindFirstChild("ActiveBrainrots")
	if not activeBrainrots then
		log("WORLD", "BRAINROTS", "ActiveBrainrots", "carpeta no encontrada")
		return
	end
	activeBrainrotsConn = activeBrainrots.DescendantAdded:Connect(function(descendant)
		if observerClosed or not observerEnabled then
			return
		end
		if isInterestingBrainrot(descendant) then
			log("WORLD", "SPAWN", safeName(descendant), safePath(descendant))
		end
	end)
	end

local function bindToolHooks(character)
	characterToolAddedConn = disconnectConnection(characterToolAddedConn)
	characterToolRemovedConn = disconnectConnection(characterToolRemovedConn)
	backpackToolAddedConn = disconnectConnection(backpackToolAddedConn)
	backpackToolRemovedConn = disconnectConnection(backpackToolRemovedConn)

	local backpack = LP:FindFirstChildOfClass("Backpack")
	if character then
		characterToolAddedConn = character.ChildAdded:Connect(function(child)
			if observerEnabled and child:IsA("Tool") then
				logInventoryIfChanged("character+" .. child.Name)
			end
		end)
		characterToolRemovedConn = character.ChildRemoved:Connect(function(child)
			if observerEnabled and child:IsA("Tool") then
				logInventoryIfChanged("character-" .. child.Name)
			end
		end)
	end
	if backpack then
		backpackToolAddedConn = backpack.ChildAdded:Connect(function(child)
			if observerEnabled and child:IsA("Tool") then
				logInventoryIfChanged("backpack+" .. child.Name)
			end
		end)
		backpackToolRemovedConn = backpack.ChildRemoved:Connect(function(child)
			if observerEnabled and child:IsA("Tool") then
				logInventoryIfChanged("backpack-" .. child.Name)
			end
		end)
	end
	logInventoryIfChanged("bind")
	end

local function bindCharacterHooks(character)
	healthConn = disconnectConnection(healthConn)
	stateConn = disconnectConnection(stateConn)
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if not humanoid then
		log("HEALTH", "MISSING", "Humanoid", "no encontrado")
		return
	end

	local lastHealth = humanoid.Health
	healthConn = humanoid.HealthChanged:Connect(function(health)
		if observerClosed or not observerEnabled then
			lastHealth = health
			return
		end
		local delta = health - lastHealth
		if math.abs(delta) >= 5 or health <= 0 then
			log("HEALTH", "CHANGE", "Humanoid", string.format("hp=%.1f delta=%.1f max=%.1f", health, delta, humanoid.MaxHealth))
			if captureMode == "GODTRACE" then
				logHazardSnapshot(health <= 0 and "death" or "damage")
			end
		end
		lastHealth = health
	end)

	stateConn = humanoid.StateChanged:Connect(function(oldState, newState)
		if observerClosed or not observerEnabled then
			return
		end
		log("STATE", "HUMANOID", "Humanoid", oldState.Name .. " -> " .. newState.Name .. " platform=" .. tostring(humanoid.PlatformStand))
	end)

	bindToolHooks(character)
	attachGodTraceHooks(character, humanoid)
	attachHazardTouchHooks(character)
	lastMovePosition = nil
	lastGodHumanoidSnapshot = ""
	lastGodRootSnapshot = ""
	lastCharacterPartsSnapshot = ""
	lastHazardSnapshot = ""
	lastHazardTouchSignature = ""
	log("FLOW", "CHARACTER", safeName(character), safePath(character))
	end

local function pollMovement(now)
	local root = getRoot()
	if not root then
		return
	end
	if not lastMovePosition then
		lastMovePosition = root.Position
		lastMoveAt = now
		return
	end
	local distance = (root.Position - lastMovePosition).Magnitude
	if distance >= moveThreshold then
		if captureMode == "GODTRACE" and distance >= 20 and root.AssemblyLinearVelocity.Magnitude <= 1 then
			log(
				"GOD",
				"STEP_PATTERN",
				"HumanoidRootPart",
				string.format("teleport_like=true dist=%.1f vel=%.2f from=(%s) to=(%s)", distance, root.AssemblyLinearVelocity.Magnitude, formatVector(lastMovePosition), formatVector(root.Position))
			)
		end
		log(
			"MOVE",
			"STEP",
			"HumanoidRootPart",
			string.format("from=(%s) to=(%s) dist=%.1f dt=%.2f", formatVector(lastMovePosition), formatVector(root.Position), distance, now - lastMoveAt)
		)
		lastMovePosition = root.Position
		lastMoveAt = now
	end
	end

local function pollNearbyPrompts()
	local prompts = {}
	local seen = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			local keywordMatch = containsInterestingKeyword(lowerText(descendant))
			local distance = getDistanceToPlayer(descendant)
			if keywordMatch or (distance and distance <= 20) then
				local key = safePath(descendant)
				if not seen[key] then
					seen[key] = true
					table.insert(prompts, key .. "@" .. (distance and string.format("%.1f", distance) or "nil"))
				end
			end
		end
	end
	table.sort(prompts)
	local snapshot = table.concat(prompts, " || ")
	if snapshot ~= lastNearbyPromptSnapshot then
		lastNearbyPromptSnapshot = snapshot
		if snapshot ~= "" then
			log("PROMPT", "NEARBY", "scan", snapshot)
		end
	end
	end

local function createUi()
	local parent = getGuiParent()
	local oldGui = parent:FindFirstChild("EscanerObserver")
	local oldGui = parent:FindFirstChild(observerGuiName)
	if oldGui then
		oldGui:Destroy()
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = observerGuiName
	sg.ResetOnSpawn = false
	sg.Parent = parent

	local frame = Instance.new("Frame")
	frame.Parent = sg
	frame.Size = UDim2.new(0, 360, 0, 260)
	frame.Position = UDim2.new(0.05, 0, 0.18, 0)
	frame.BackgroundColor3 = Color3.fromRGB(16, 18, 22)
	frame.Active = true
	frame.Draggable = true
	Instance.new("UICorner", frame)

	local title = Instance.new("TextLabel")
	title.Parent = frame
	title.Size = UDim2.new(1, -12, 0, 22)
	title.Position = UDim2.new(0, 6, 0, 4)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "ESCANER | OBSERVER READ-ONLY | " .. scannerVersion

	statusLabel = Instance.new("TextLabel")
	statusLabel.Parent = frame
	statusLabel.Size = UDim2.new(1, -12, 0, 34)
	statusLabel.Position = UDim2.new(0, 6, 0, 28)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 11
	statusLabel.TextColor3 = Color3.new(1, 1, 1)
	statusLabel.TextWrapped = true
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.Text = "iniciando observer"

	sharedStateLabel = Instance.new("TextLabel")
	sharedStateLabel.Parent = frame
	sharedStateLabel.Size = UDim2.new(1, -12, 0, 26)
	sharedStateLabel.Position = UDim2.new(0, 6, 0, 62)
	sharedStateLabel.BackgroundTransparency = 1
	sharedStateLabel.Font = Enum.Font.Gotham
	sharedStateLabel.TextSize = 10
	sharedStateLabel.TextColor3 = Color3.fromRGB(190, 205, 220)
	sharedStateLabel.TextWrapped = true
	sharedStateLabel.TextXAlignment = Enum.TextXAlignment.Left
	sharedStateLabel.TextYAlignment = Enum.TextYAlignment.Top
	sharedStateLabel.Text = "STATE: sin shared state"

	countLabel = Instance.new("TextLabel")
	countLabel.Parent = frame
	countLabel.Size = UDim2.new(0.3, 0, 0, 18)
	countLabel.Position = UDim2.new(0, 6, 0, 92)
	countLabel.BackgroundTransparency = 1
	countLabel.Font = Enum.Font.GothamBold
	countLabel.TextSize = 11
	countLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
	countLabel.TextXAlignment = Enum.TextXAlignment.Left
	countLabel.Text = "LOGS: 0"

	watchButton = Instance.new("TextButton")
	watchButton.Parent = frame
	watchButton.Size = UDim2.new(0, 86, 0, 24)
	watchButton.Position = UDim2.new(0, 6, 0, 114)
	watchButton.Font = Enum.Font.GothamBold
	watchButton.TextSize = 11
	watchButton.TextColor3 = Color3.new(1, 1, 1)
	watchButton.BorderSizePixel = 0
	Instance.new("UICorner", watchButton)

	copyButton = Instance.new("TextButton")
	copyButton.Parent = frame
	copyButton.Size = UDim2.new(0, 102, 0, 24)
	copyButton.Position = UDim2.new(0, 98, 0, 114)
	copyButton.Font = Enum.Font.GothamBold
	copyButton.TextSize = 11
	copyButton.TextColor3 = Color3.new(1, 1, 1)
	copyButton.BackgroundColor3 = Color3.fromRGB(65, 90, 140)
	copyButton.BorderSizePixel = 0
	Instance.new("UICorner", copyButton)

	copyChunkButton = Instance.new("TextButton")
	copyChunkButton.Parent = frame
	copyChunkButton.Size = UDim2.new(0, 82, 0, 24)
	copyChunkButton.Position = UDim2.new(0, 206, 0, 114)
	copyChunkButton.Font = Enum.Font.GothamBold
	copyChunkButton.TextSize = 11
	copyChunkButton.TextColor3 = Color3.new(1, 1, 1)
	copyChunkButton.BackgroundColor3 = Color3.fromRGB(90, 115, 150)
	copyChunkButton.BorderSizePixel = 0
	Instance.new("UICorner", copyChunkButton)

	exportPageLabel = Instance.new("TextLabel")
	exportPageLabel.Parent = frame
	exportPageLabel.Size = UDim2.new(0, 70, 0, 16)
	exportPageLabel.Position = UDim2.new(0, 228, 0, 96)
	exportPageLabel.BackgroundTransparency = 1
	exportPageLabel.Font = Enum.Font.GothamBold
	exportPageLabel.TextSize = 10
	exportPageLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
	exportPageLabel.TextXAlignment = Enum.TextXAlignment.Right
	exportPageLabel.Text = "PARTE 1/1"

	copyRecentButton = Instance.new("TextButton")
	copyRecentButton.Parent = frame
	copyRecentButton.Size = UDim2.new(0, 62, 0, 24)
	copyRecentButton.Position = UDim2.new(0, 294, 0, 114)
	copyRecentButton.Font = Enum.Font.GothamBold
	copyRecentButton.TextSize = 11
	copyRecentButton.TextColor3 = Color3.new(1, 1, 1)
	copyRecentButton.BackgroundColor3 = Color3.fromRGB(90, 105, 120)
	copyRecentButton.BorderSizePixel = 0
	Instance.new("UICorner", copyRecentButton)

	filterButton = Instance.new("TextButton")
	filterButton.Parent = frame
	filterButton.Size = UDim2.new(0, 236, 0, 24)
	filterButton.Position = UDim2.new(0, 6, 0, 86)
	filterButton.Font = Enum.Font.GothamBold
	filterButton.TextSize = 10
	filterButton.TextColor3 = Color3.new(1, 1, 1)
	filterButton.BackgroundColor3 = Color3.fromRGB(50, 68, 96)
	filterButton.BorderSizePixel = 0
	Instance.new("UICorner", filterButton)

	clearButton = Instance.new("TextButton")
	clearButton.Parent = frame
	clearButton.Size = UDim2.new(0, 72, 0, 24)
	clearButton.Position = UDim2.new(0, 248, 0, 86)
	clearButton.Font = Enum.Font.GothamBold
	clearButton.TextSize = 11
	clearButton.TextColor3 = Color3.new(1, 1, 1)
	clearButton.Text = "LIMPIAR"
	clearButton.BackgroundColor3 = Color3.fromRGB(110, 55, 55)
	clearButton.BorderSizePixel = 0
	Instance.new("UICorner", clearButton)

	saveButton = Instance.new("TextButton")
	saveButton.Parent = frame
	saveButton.Size = UDim2.new(0, 52, 0, 24)
	saveButton.Position = UDim2.new(0, 326, 0, 86)
	saveButton.Font = Enum.Font.GothamBold
	saveButton.TextSize = 11
	saveButton.TextColor3 = Color3.new(1, 1, 1)
	saveButton.Text = "SAVE"
	saveButton.BackgroundColor3 = Color3.fromRGB(85, 85, 100)
	saveButton.BorderSizePixel = 0
	Instance.new("UICorner", saveButton)

	logBox = Instance.new("TextBox")
	logBox.Parent = frame
	logBox.Size = UDim2.new(1, -12, 1, -150)
	logBox.Position = UDim2.new(0, 6, 0, 146)
	logBox.BackgroundColor3 = Color3.fromRGB(10, 11, 14)
	logBox.BorderSizePixel = 0
	logBox.ClearTextOnFocus = false
	logBox.MultiLine = true
	logBox.TextEditable = false
	logBox.Font = Enum.Font.Code
	logBox.TextSize = 11
	logBox.TextXAlignment = Enum.TextXAlignment.Left
	logBox.TextYAlignment = Enum.TextYAlignment.Top
	logBox.TextWrapped = false
	logBox.TextColor3 = Color3.fromRGB(230, 230, 230)
	logBox.Text = ""
	Instance.new("UICorner", logBox)

	closeButton = Instance.new("TextButton")
	closeButton.Parent = frame
	closeButton.Size = UDim2.new(0, 24, 0, 20)
	closeButton.Position = UDim2.new(1, -28, 0, 4)
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 11
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.Text = "X"
	closeButton.BackgroundColor3 = Color3.fromRGB(125, 45, 45)
	closeButton.BorderSizePixel = 0
	Instance.new("UICorner", closeButton)

	watchButton.MouseButton1Click:Connect(function()
		observerEnabled = not observerEnabled
		log("FLOW", observerEnabled and "WATCH_ON" or "WATCH_OFF", "observer", "manual toggle")
		scheduleUiRefresh()
	end)

	copyButton.MouseButton1Click:Connect(function()
		local payload = getStoredLogDump()
		if copyPayloadToClipboard(payload) then
			log("FLOW", "COPY", "logs", "copiados al portapapeles")
		else
			log("ERROR", "COPY_FAIL", "logs", "sin API clipboard")
		end
	end)

	copyChunkButton.MouseButton1Click:Connect(function()
		local payload, chunkIndex, chunkCount = getClipboardChunk(exportChunkIndex)
		if payload == "" then
			log("ERROR", "COPY_PART_FAIL", "logs", "sin logs para exportar")
			return
		end
		if copyPayloadToClipboard(payload) then
			log("FLOW", "COPY_PART", "logs", "parte=" .. tostring(chunkIndex) .. "/" .. tostring(chunkCount))
			exportChunkIndex = chunkIndex >= chunkCount and 1 or (chunkIndex + 1)
			scheduleUiRefresh()
		else
			log("ERROR", "COPY_PART_FAIL", "logs", "sin API clipboard")
		end
	end)

	copyRecentButton.MouseButton1Click:Connect(function()
		local payload = getRecentLogDump(200)
		if payload == "" then
			log("ERROR", "COPY_RECENT_FAIL", "logs", "sin logs para exportar")
			return
		end
		if copyPayloadToClipboard(payload) then
			log("FLOW", "COPY_RECENT", "logs", "ultimos=200")
		else
			log("ERROR", "COPY_RECENT_FAIL", "logs", "sin API clipboard")
		end
	end)

	filterButton.MouseButton1Click:Connect(function()
		cycleCaptureMode()
		nearbyPromptScanEnabled = captureMode == "ALL"
		if captureMode == "GODTRACE" then
			lastGuiSnapshot = ""
			lastNearbyPromptSnapshot = ""
		end
		scheduleUiRefresh()
		log("FLOW", "FILTER", "observer", "mode=" .. captureMode)
	end)

	clearButton.MouseButton1Click:Connect(function()
		storedCharCount = 0
		storedLogs = {}
		lastGuiSnapshot = ""
		lastNearbyPromptSnapshot = ""
		lastInventorySnapshot = ""
		exportChunkIndex = 1
		scheduleUiRefresh()
		log("FLOW", "CLEAR", "logs", "buffer reiniciado")
	end)

	saveButton.MouseButton1Click:Connect(function()
		if type(writefile) ~= "function" then
			log("ERROR", "SAVE_FAIL", "logs", "writefile no disponible")
			return
		end
		local fileName = "escaner_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
		local ok, err = pcall(function()
			writefile(fileName, table.concat(storedLogs, "\n"))
		end)
		if ok then
			log("FLOW", "SAVE", "logs", fileName)
		else
			log("ERROR", "SAVE_FAIL", "logs", tostring(err or "error desconocido"))
		end
	end)

	closeButton.MouseButton1Click:Connect(function()
		observerClosed = true
		observerEnabled = false
		activeBrainrotsConn = disconnectConnection(activeBrainrotsConn)
		characterAddedConn = disconnectConnection(characterAddedConn)
		healthConn = disconnectConnection(healthConn)
		stateConn = disconnectConnection(stateConn)
		characterToolAddedConn = disconnectConnection(characterToolAddedConn)
		characterToolRemovedConn = disconnectConnection(characterToolRemovedConn)
		backpackToolAddedConn = disconnectConnection(backpackToolAddedConn)
		backpackToolRemovedConn = disconnectConnection(backpackToolRemovedConn)
		characterDescendantAddedConn = disconnectConnection(characterDescendantAddedConn)
		clearConnectionList(godTraceConnections)
		clearHazardTouchConnections()
		clearPromptConnections()
		if mainLoopThread then
			pcall(function()
				task.cancel(mainLoopThread)
			end)
			mainLoopThread = nil
		end
		sg:Destroy()
	end)

	nearbyPromptScanEnabled = captureMode == "ALL"
	refreshUi()
	return sg
	end

createUi()
attachPromptHooks()
bindActiveBrainrots()
bindCharacterHooks(getCharacter())

characterAddedConn = LP.CharacterAdded:Connect(function(character)
	if observerClosed then
		return
	end
	log("FLOW", "RESPAWN", safeName(character), safePath(character))
	task.wait(0.5)
	if observerClosed then
		return
	end
	bindCharacterHooks(character)
	bindActiveBrainrots()
	end)

mainLoopThread = task.spawn(function()
	local lastGuiPollAt = 0
	local lastNearbyScanAt = 0
	while task.wait(pollInterval) do
		if observerClosed then
			break
		end
		if observerEnabled then
			local now = os.clock()
			pollSharedState()
			pollMovement(now)
			logInventoryIfChanged("poll")
			if captureMode == "GODTRACE" then
				pollGodTraceSignals()
			end
			if captureMode ~= "GODTRACE" and now - lastGuiPollAt >= guiPollInterval then
				lastGuiPollAt = now
				pollGuiSignals()
			end
			if now - lastNearbyScanAt >= nearbyScanInterval then
				lastNearbyScanAt = now
				if nearbyPromptScanEnabled then
					pollNearbyPrompts()
				end
			end
		end
	end
	end)

log("FLOW", "BOOT", "observer", "version=" .. scannerVersion .. " read_only=true")
