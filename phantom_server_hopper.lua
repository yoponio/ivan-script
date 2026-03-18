if not game:IsLoaded() then
	game.Loaded:Wait()
end

local VERSION = "phantom-server-hopper-r1"

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local StarterGui = game:GetService("StarterGui")

local LP = Players.LocalPlayer

local PLACE_ID = game.PlaceId
local CURRENT_JOB_ID = game.JobId
local SERVER_PAGE_LIMIT = 100
local MAX_PAGE_FETCHES = 8
local MAX_SCAN_SECONDS = 14
local SCAN_INTERVAL = 1.5
local MIN_DETECTION_SCORE = 22
local MIN_TOTAL_SCORE = 42
local VISITED_KEY = "phantom_hopper_visited_servers"
local ACTIVE_KEY = "phantom_hopper_active"
local SOURCE_FILE = "phantom_server_hopper.lua"

local visitedServerIds = {}
local stopRequested = false
local hopperRunning = false
local manualSkipRequested = false
local uiStatusLabel
local uiLogBox
local uiActionButton
local uiSkipButton
local uiCopyButton
local storedLogs = {}
local maxStoredLogs = 220
local scanBatchSize = 250
local runHopper

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
	StringValue = true,
	NumberValue = true,
	ObjectValue = true,
}

local function safeNotify(title, text)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = title,
			Text = text,
			Duration = 6,
		})
	end)
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

local function appendLog(message)
	table.insert(storedLogs, message)
	trimArray(storedLogs, maxStoredLogs)
	print(message)
	if uiStatusLabel then
		uiStatusLabel.Text = message
	end
	if uiLogBox then
		local dump = table.concat(storedLogs, "\n")
		uiLogBox.Text = dump
		pcall(function()
			uiLogBox.CursorPosition = #dump + 1
		end)
	end
	if uiCopyButton then
		uiCopyButton.Text = "COPIAR LOGS (" .. tostring(#storedLogs) .. ")"
	end
	if uiActionButton then
		uiActionButton.Text = stopRequested and "INICIAR" or "DETENER"
	end
	if uiSkipButton then
		uiSkipButton.Text = hopperRunning and "SKIP SERVER" or "SKIP"
	end
	end

local function log(tag, details)
	appendLog(string.format("[PH_HOP][%.3f][%s] %s", os.clock(), tostring(tag), tostring(details or "")))
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

local function safeIsA(instance, className)
	local ok, result = pcall(function()
		return instance and instance:IsA(className)
	end)
	return ok and result or false
	end

local function safeClassName(instance)
	local ok, result = pcall(function()
		return instance.ClassName
	end)
	return ok and result or "Unknown"
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

local function yieldIfNeeded(index)
	if index % scanBatchSize == 0 then
		task.wait()
	end
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

local function collectMatches(root, limit)
	local results = {}
	if not root then
		return results
	end
	local descendants = root:GetDescendants()
	for index, descendant in ipairs(descendants) do
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
				})
			end
		end
		yieldIfNeeded(index)
	end
	table.sort(results, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.path < b.path
	end)
	if limit and #results > limit then
		for index = #results, limit + 1, -1 do
			results[index] = nil
		end
	end
	return results
	end

local function detectPhantomEvent()
	local allMatches = {}
	local roots = {
		{label = "workspace", root = workspace, limit = 16},
		{label = "brainrots", root = workspace:FindFirstChild("ActiveBrainrots"), limit = 10},
		{label = "boats", root = workspace:FindFirstChild("Boats") or workspace:FindFirstChild("Boat") or workspace:FindFirstChild("Ships"), limit = 10},
		{label = "gui", root = LP:FindFirstChildOfClass("PlayerGui"), limit = 12},
	}

	for _, item in ipairs(roots) do
		local matches = collectMatches(item.root, item.limit)
		for _, match in ipairs(matches) do
			match.label = item.label
			table.insert(allMatches, match)
		end
	end

	table.sort(allMatches, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.path < b.path
	end)

	local topScore = allMatches[1] and allMatches[1].score or 0
	local totalScore = 0
	for index = 1, math.min(5, #allMatches) do
		totalScore = totalScore + allMatches[index].score
	end

	local detected = topScore >= MIN_DETECTION_SCORE or totalScore >= MIN_TOTAL_SCORE
	return detected, allMatches, topScore, totalScore
	end

local function startHopperAsync()
	if hopperRunning or stopRequested then
		return
	end
	task.spawn(function()
		local ok, err = xpcall(runHopper, debug.traceback)
		hopperRunning = false
		if not ok then
			log("FATAL", tostring(err))
			safeNotify("Phantom Hopper", "Error en el hopper. Revisa el log.")
		end
	end)
	end

local function getGuiParent()
	local ok, guiParent = pcall(function()
		return gethui and gethui()
	end)
	if ok and guiParent then
		return guiParent
	end
	return game:GetService("CoreGui")
	end

local function buildUi()
	local guiParent = getGuiParent()
	local oldGui = guiParent:FindFirstChild("PhantomServerHopperGui")
	if oldGui then
		oldGui:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PhantomServerHopperGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = guiParent

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Parent = screenGui
	frame.Size = UDim2.new(0, 500, 0, 330)
	frame.Position = UDim2.new(0.04, 0, 0.18, 0)
	frame.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Draggable = true
	Instance.new("UICorner", frame)

	local title = Instance.new("TextLabel")
	title.Parent = frame
	title.Size = UDim2.new(1, -20, 0, 28)
	title.Position = UDim2.new(0, 10, 0, 8)
	title.BackgroundTransparency = 1
	title.Text = "PHANTOM SERVER HOPPER " .. VERSION
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left

	uiStatusLabel = Instance.new("TextLabel")
	uiStatusLabel.Parent = frame
	uiStatusLabel.Size = UDim2.new(1, -20, 0, 36)
	uiStatusLabel.Position = UDim2.new(0, 10, 0, 40)
	uiStatusLabel.BackgroundTransparency = 1
	uiStatusLabel.Text = "Listo para buscar evento phantom en servidores publicos"
	uiStatusLabel.TextWrapped = true
	uiStatusLabel.TextColor3 = Color3.fromRGB(215, 220, 225)
	uiStatusLabel.Font = Enum.Font.Gotham
	uiStatusLabel.TextSize = 12
	uiStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	uiStatusLabel.TextYAlignment = Enum.TextYAlignment.Top

	local function makeButton(name, text, x, width)
		local button = Instance.new("TextButton")
		button.Name = name
		button.Parent = frame
		button.Size = UDim2.new(0, width, 0, 30)
		button.Position = UDim2.new(0, x, 0, 82)
		button.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
		button.Text = text
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 12
		button.BorderSizePixel = 0
		Instance.new("UICorner", button)
		return button
	end

	uiActionButton = makeButton("Toggle", "DETENER", 10, 100)
	uiSkipButton = makeButton("Skip", "SKIP", 118, 120)
	uiCopyButton = makeButton("Copy", "COPIAR LOGS (0)", 246, 150)
	local closeButton = makeButton("Close", "CERRAR", 404, 86)

	local infoLabel = Instance.new("TextLabel")
	infoLabel.Parent = frame
	infoLabel.Size = UDim2.new(1, -20, 0, 30)
	infoLabel.Position = UDim2.new(0, 10, 0, 120)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Text = "Busca servidores del place actual, escanea workspace/gui y se queda si encuentra firma phantom."
	infoLabel.TextWrapped = true
	infoLabel.TextColor3 = Color3.fromRGB(180, 190, 200)
	infoLabel.Font = Enum.Font.Gotham
	infoLabel.TextSize = 11
	infoLabel.TextXAlignment = Enum.TextXAlignment.Left
	infoLabel.TextYAlignment = Enum.TextYAlignment.Top

	uiLogBox = Instance.new("TextBox")
	uiLogBox.Parent = frame
	uiLogBox.Size = UDim2.new(1, -20, 1, -162)
	uiLogBox.Position = UDim2.new(0, 10, 0, 150)
	uiLogBox.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
	uiLogBox.TextColor3 = Color3.fromRGB(220, 225, 230)
	uiLogBox.Font = Enum.Font.Code
	uiLogBox.TextSize = 12
	uiLogBox.MultiLine = true
	uiLogBox.ClearTextOnFocus = false
	uiLogBox.TextEditable = false
	uiLogBox.TextXAlignment = Enum.TextXAlignment.Left
	uiLogBox.TextYAlignment = Enum.TextYAlignment.Top
	uiLogBox.Text = ""
	uiLogBox.BorderSizePixel = 0
	Instance.new("UICorner", uiLogBox)

	uiActionButton.MouseButton1Click:Connect(function()
		stopRequested = not stopRequested
		log(stopRequested and "STOP" or "START", stopRequested and "bucle detenido" or "bucle reanudado")
		if not stopRequested then
			manualSkipRequested = false
			startHopperAsync()
		end
	end)

	uiSkipButton.MouseButton1Click:Connect(function()
		if hopperRunning then
			stopRequested = false
			manualSkipRequested = true
			log("SKIP", "salto manual solicitado")
		end
	end)

	uiCopyButton.MouseButton1Click:Connect(function()
		if copyPayloadToClipboard(table.concat(storedLogs, "\n")) then
			log("COPY", "logs copiados")
		else
			log("COPY_FAIL", "sin API de clipboard")
		end
	end)

	closeButton.MouseButton1Click:Connect(function()
		stopRequested = true
		screenGui:Destroy()
	end)
	end

local function getRequestFunction()
	local candidates = {
		syn and syn.request,
		http_request,
		request,
		fluxus and fluxus.request,
	}
	for _, candidate in ipairs(candidates) do
		if type(candidate) == "function" then
			return candidate
		end
	end
	return nil
	end

local function httpGet(url)
	local requestFn = getRequestFunction()
	if requestFn then
		local response = requestFn({
			Url = url,
			Method = "GET",
		})
		if not response then
			error("respuesta HTTP vacia")
		end
		local success = response.Success
		if success == nil then
			success = (response.StatusCode or 0) >= 200 and (response.StatusCode or 0) < 300
		end
		if not success then
			error("HTTP " .. tostring(response.StatusCode or "?") .. " en " .. url)
		end
		return response.Body or response.body or ""
	end

	if type(game.HttpGet) == "function" then
		return game:HttpGet(url)
	end

	error("tu ejecutor no tiene API HTTP compatible")
	end

local function getQueueOnTeleport()
	local candidates = {
		queue_on_teleport,
		syn and syn.queue_on_teleport,
		queueonteleport,
		fluxus and fluxus.queue_on_teleport,
	}
	for _, candidate in ipairs(candidates) do
		if type(candidate) == "function" then
			return candidate
		end
	end
	return nil
	end

local function queueSelfOnTeleport()
	local queueFn = getQueueOnTeleport()
	if not queueFn then
		log("QUEUE_WARN", "sin queue_on_teleport; no puedo continuar tras teleport")
		return false
	end
	local payload = string.format([[task.spawn(function()
	local ok, source = pcall(function()
		return readfile(%q)
	end)
	if ok and type(source) == "string" and source ~= "" then
		loadstring(source)()
	end
end)]], SOURCE_FILE)
	queueFn(payload)
	return true
	end

local function loadVisitedServerIds()
	local ok, value = pcall(function()
		return TeleportService:GetTeleportSetting(VISITED_KEY)
	end)
	if ok and type(value) == "table" then
		for serverId, seen in pairs(value) do
			if seen then
				visitedServerIds[serverId] = true
			end
		end
	end
	visitedServerIds[CURRENT_JOB_ID] = true
	TeleportService:SetTeleportSetting(VISITED_KEY, visitedServerIds)
	TeleportService:SetTeleportSetting(ACTIVE_KEY, true)
	end

local function fetchServerCandidates()
	local cursor = nil
	local results = {}
	for pageIndex = 1, MAX_PAGE_FETCHES do
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=%d&excludeFullGames=true%s",
			PLACE_ID,
			SERVER_PAGE_LIMIT,
			cursor and ("&cursor=" .. HttpService:UrlEncode(cursor)) or ""
		)
		local ok, bodyOrErr = pcall(function()
			return httpGet(url)
		end)
		if not ok then
			log("SERVER_HTTP_FAIL", tostring(bodyOrErr))
			break
		end
		local decodedOk, page = pcall(function()
			return HttpService:JSONDecode(bodyOrErr)
		end)
		if not decodedOk or type(page) ~= "table" then
			log("SERVER_JSON_FAIL", "no se pudo decodificar la lista de servidores")
			break
		end
		for _, server in ipairs(page.data or {}) do
			local serverId = server.id
			local playing = tonumber(server.playing or 0) or 0
			local maxPlayers = tonumber(server.maxPlayers or 0) or 0
			if serverId and serverId ~= CURRENT_JOB_ID and playing < maxPlayers and not visitedServerIds[serverId] then
				table.insert(results, server)
			end
		end
		cursor = page.nextPageCursor
		if not cursor or cursor == "" then
			break
		end
	end
	return results
	end

local function teleportToServer(server)
	if not server or not server.id then
		return false
	end
	visitedServerIds[server.id] = true
	TeleportService:SetTeleportSetting(VISITED_KEY, visitedServerIds)
	TeleportService:SetTeleportSetting(ACTIVE_KEY, true)
	queueSelfOnTeleport()
	log("TELEPORT", string.format("server=%s players=%s/%s", tostring(server.id), tostring(server.playing), tostring(server.maxPlayers)))
	safeNotify("Phantom Hopper", "Saltando a otro servidor...")
	TeleportService:TeleportToPlaceInstance(PLACE_ID, server.id, LP)
	return true
	end

local function formatTopMatches(matches)
	if #matches == 0 then
		return "sin coincidencias"
	end
	local parts = {}
	for index = 1, math.min(3, #matches) do
		local entry = matches[index]
		table.insert(parts, string.format("#%d score=%d %s", index, entry.score, entry.path))
	end
	return table.concat(parts, " | ")
	end

local function scanCurrentServer()
	local startedAt = os.clock()
	local attempt = 0
	while os.clock() - startedAt < MAX_SCAN_SECONDS do
		if stopRequested then
			log("SCAN_STOP", "scan detenido por usuario")
			return false
		end
		if manualSkipRequested then
			manualSkipRequested = false
			log("SCAN_SKIP", "se omitio el servidor actual")
			return false
		end
		attempt = attempt + 1
		local detected, matches, topScore, totalScore = detectPhantomEvent()
		log("SCAN", string.format("attempt=%d hits=%d top=%d total=%d", attempt, #matches, topScore, totalScore))
		if detected then
			local summary = formatTopMatches(matches)
			log("PHANTOM_FOUND", summary)
			safeNotify("Phantom detectado", "Servidor encontrado. No haré más hops.")
			copyPayloadToClipboard("JobId=" .. tostring(CURRENT_JOB_ID) .. "\n" .. summary)
			TeleportService:SetTeleportSetting(ACTIVE_KEY, false)
			return true
		end
		task.wait(SCAN_INTERVAL)
	end
	log("SCAN_EMPTY", "no se detecto firma phantom en este servidor")
	return false
	end

runHopper = function()
	if stopRequested then
		log("IDLE", "hopper detenido por usuario")
		return
	end

	hopperRunning = true
	local found = scanCurrentServer()
	if found then
		hopperRunning = false
		stopRequested = true
		return
	end

	local servers = fetchServerCandidates()
	if #servers == 0 then
		clearArray(storedLogs)
		log("SERVER_NONE", "sin servidores nuevos; limpio cache y reintento")
		visitedServerIds = {}
		visitedServerIds[CURRENT_JOB_ID] = true
		TeleportService:SetTeleportSetting(VISITED_KEY, visitedServerIds)
		servers = fetchServerCandidates()
		if #servers == 0 then
			hopperRunning = false
			log("STOP", "no pude obtener servidores para saltar")
			return
		end
	end

	teleportToServer(servers[1])
	hopperRunning = false
	end

buildUi()
loadVisitedServerIds()
log("BOOT", string.format("version=%s placeId=%s jobId=%s", VERSION, tostring(PLACE_ID), tostring(CURRENT_JOB_ID)))
log("TIP", "deja el script corriendo; se queda cuando detecta phantom y copia el JobId")
safeNotify("Phantom Hopper", "Escaneando servidor actual...")
startHopperAsync()