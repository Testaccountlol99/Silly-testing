-- ============================================================
--  AIMBOT  |  Anti-Cheat Testing Tool
--  Modes: Blatant / Legit
-- ============================================================

-- ============================================================
-- [0] LOCALISED MATH  (avoids global table lookup in hot paths)
-- ============================================================
local mclamp  = math.clamp
local mhuge   = math.huge
local mrand   = math.random
local msqrt   = math.sqrt
local mmax    = math.max
local mmin    = math.min
local mlog    = math.log
local mcos    = math.cos
local mfloor  = math.floor
local mabs    = math.abs
local TAU   = math.pi * 2        -- 2π constant reused in Box-Muller
local ZERO3 = Vector3.new(0,0,0) -- shared zero vector (immutable)

-- Drawing / Vector shortcuts (avoid global table lookup in hot paths)
local newV2      = Vector2.new
local newC3      = Color3.new
local newDrawing = Drawing.new

-- ============================================================
-- [1] SERVICES
-- ============================================================
local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local RunService  = game:GetService("RunService")
local Workspace   = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Camera      = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- [2] CONFIGURATION
-- ============================================================
local Defaults = {
    Enabled          = false,
    EspEnabled       = false,
    PlayerEspEnabled = true,   -- player-specific esp toggle (sub-toggle of EspEnabled)
    EspTextEnabled   = false,  -- per-player name/hp/distance text overlay
    EspTeamCheck     = true,
    EspTeamColors    = false,  -- tint ESP drawings with each player's team color
    EspType          = "Box",
    WallCheck        = true,
    Mode             = "Legit",
    TeamCheck        = true,
    Prediction       = true,
    TargetPart       = "Head",
    -- General
    FOV                = 50,
    MaxDistance        = 100,
    PredictionFactor   = 1.0,
    Smoothness         = 0.4,
    AdaptivePrediction = true,
    -- Health Check
    HealthCheckEnabled = false,
    HealthMinHP        = 0,    -- minimum HP% to consider (0-100)
    HealthMaxHP        = 100,  -- maximum HP% to consider (0-100)
    -- Legit
    MinReactionTime  = 0.15,
    MaxReactionTime  = 0.35,
    MeanReactionTime = 0.22,
    TrackingError    = 0.8,
    ShakeIntensity   = 0.3,
    -- Target Override
    OverrideThreshold = 12,   -- mouse delta magnitude (px/frame) to trigger override
    OverrideCooldown  = 0.25, -- seconds the aimbot stays suppressed after a flick
    -- Whitelist
    -- Keyed by team Name (string) -> true.  O(1) lookup in isWhitelisted().
    WhitelistedTeams  = {},
}

local Settings = {}
for k, v in pairs(Defaults) do Settings[k] = v end

-- HardDefaults: immutable copy of the compiled defaults.
-- uiResets close over Defaults.X at call time, so they always reset to these
-- hardcoded values even after a save file has been loaded.
local HardDefaults = {}
for k, v in pairs(Defaults) do HardDefaults[k] = v end
-- WhitelistedTeams is a table; keep the original reference separate.
HardDefaults.WhitelistedTeams = {}

local uiResets = {}

-- ============================================================
-- [2.5] SAVE / LOAD SYSTEM
-- ============================================================
local SAVE_FILE = "AimbotSettings.json"

-- Keys whose values are plain primitives (bool / number / string).
-- WhitelistedTeams is handled separately as an array <-> set conversion.
local SAVE_KEYS = {
    "Enabled", "EspEnabled", "PlayerEspEnabled", "EspTextEnabled", "EspTeamCheck", "EspTeamColors", "EspType", "WallCheck", "Mode", "TeamCheck", "Prediction", "TargetPart",
    "FOV", "MaxDistance", "PredictionFactor", "Smoothness", "AdaptivePrediction",
    "HealthCheckEnabled", "HealthMinHP", "HealthMaxHP",
    "MinReactionTime", "MaxReactionTime", "MeanReactionTime",
    "TrackingError", "ShakeIntensity",
    "OverrideThreshold", "OverrideCooldown",
}

local function serializeSettings()
    local t = {}
    for _, k in ipairs(SAVE_KEYS) do
        t[k] = Settings[k]
    end
    -- WhitelistedTeams: set -> sorted array for stable JSON.
    local teams = {}
    for name in pairs(Settings.WhitelistedTeams) do
        teams[#teams + 1] = name
    end
    table.sort(teams)
    t.WhitelistedTeams = teams
    return t
end

-- saveSettings: writes current Settings to the JSON file.
-- Returns true on success, false + reason string on failure.
local function saveSettings()
    local ok, result = pcall(function()
        local encoded = HttpService:JSONEncode(serializeSettings())
        writefile(SAVE_FILE, encoded)
    end)
    return ok, ok or result
end

-- loadSettings: reads the JSON file (if it exists) and overwrites
-- the relevant keys in Settings.  Safe against malformed files.
-- Called BEFORE the UI is built so Kalman / reaction state starts correctly.
-- The UI visuals are synced separately via applySettingsToUI() after build.
local function loadSettings()
    if not isfile(SAVE_FILE) then return end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(SAVE_FILE))
    end)
    if not ok or type(data) ~= "table" then return end

    for _, k in ipairs(SAVE_KEYS) do
        local v = data[k]
        if v ~= nil and type(v) == type(HardDefaults[k]) then
            Settings[k] = v
        end
    end

    -- WhitelistedTeams: array -> set
    if type(data.WhitelistedTeams) == "table" then
        table.clear(Settings.WhitelistedTeams)
        for _, name in ipairs(data.WhitelistedTeams) do
            if type(name) == "string" then
                Settings.WhitelistedTeams[name] = true
            end
        end
    end
end

-- Load saved values into Settings immediately so runtime behaviour
-- reflects the file from the first frame, before the UI is built.
loadSettings()

-- ============================================================
-- [3] PLAYER CACHE
-- ============================================================

-- FIX: Declare the two per-character caches here, before playerCache is
-- populated, so the PlayerRemoving hook below can reference both tables
-- to evict entries the moment a player leaves.  In the original code these
-- were declared later (inside [4]) which meant PlayerRemoving could never
-- clean them, causing the leaving player's Character Model to be kept alive
-- as a table key long after the player had gone (memory leak).
local visCache        = {}   -- [char] = {visible:bool, lastCheck:number}
local targetPartCache = {}   -- [char] = "Head"|"HumanoidRootPart"
local espBoxPool       = {}   -- [player] = Drawing "Square" object
local espCharmPool     = {}   -- [player] = Drawing "Circle" object (Circle/Mark mode)
local espHighlightPool = {}   -- [player] = Highlight instance (Charm mode)
local espTextPool      = {}   -- [player] = { name=Drawing.Text, info=Drawing.Text }

-- ── ESP constants ─────────────────────────────────────────────────────────────
local ESP_COLOR_DEFAULT = Color3.fromRGB(255, 69, 0)  -- avoids alloc per frame

-- ── ESP render list (event-driven) ───────────────────────────────────────────
-- Only players who are currently alive with a loaded character live here.
-- CharacterAdded adds entries; Humanoid.Died and CharacterRemoving remove them.
-- The RenderStepped loop iterates ONLY this list — no health checks, no
-- FindFirstChild calls, no hide-pass for dead/gone players needed.
local espRenderList  = {}   -- [i] = { pl=Player, cc={ ch, hum, root, head, txt } }
local espCharCache   = {}   -- [player] = cc  (same table as renderList entry)
local espPlayerConns = {}   -- [player] = { charAddedConn, charRemovingConn, humConn, healthConn }

-- Forward-declared: body defined in features.lua after Drawing system is set up.
-- onCharacter calls this to pre-create text drawings at spawn time so the
-- render loop never needs to build or set them from scratch.
local getEspText

-- ── Helpers ───────────────────────────────────────────────────────────────────
-- Hide all ESP drawings for one player immediately.
local function espHidePlayer(pl)
    if espBoxPool[pl]       then espBoxPool[pl].Visible       = false end
    if espCharmPool[pl]     then espCharmPool[pl].Visible     = false end
    if espHighlightPool[pl] then espHighlightPool[pl].Enabled = false end
    if espTextPool[pl] then
        espTextPool[pl].name.Visible = false
        espTextPool[pl].info.Visible = false
    end
end

-- Swap-remove player from espRenderList in O(1).
local function espRemoveFromList(pl)
    for i = 1, #espRenderList do
        if espRenderList[i].pl == pl then
            espRenderList[i] = espRenderList[#espRenderList]
            espRenderList[#espRenderList] = nil
            return
        end
    end
end

-- Fully destroy all pool objects for a player and free memory.
local function espDestroyPools(pl)
    if espBoxPool[pl] then
        pcall(function() espBoxPool[pl]:Remove() end)
        espBoxPool[pl] = nil
    end
    if espCharmPool[pl] then
        pcall(function() espCharmPool[pl]:Remove() end)
        espCharmPool[pl] = nil
    end
    if espHighlightPool[pl] then
        pcall(function() espHighlightPool[pl]:Destroy() end)
        espHighlightPool[pl] = nil
    end
    if espTextPool[pl] then
        pcall(function() espTextPool[pl].name:Remove() end)
        pcall(function() espTextPool[pl].info:Remove() end)
        espTextPool[pl] = nil
    end
end

-- ── Per-player event wiring ───────────────────────────────────────────────────
-- Sets up CharacterAdded / CharacterRemoving / Humanoid.Died for one player.
-- Called for every existing player at startup and for each PlayerAdded.
local function setupEspPlayer(pl)
    if pl == LocalPlayer then return end

    local state = {}  -- holds the three live connections for this player

    local function onCharacter(ch)
        -- Disconnect previous per-character connections if the player respawned.
        if state.humConn    then state.humConn:Disconnect();    state.humConn    = nil end
        if state.healthConn then state.healthConn:Disconnect(); state.healthConn = nil end

        -- Humanoid may not be replicated yet — wait briefly rather than poll.
        local hum = ch:WaitForChild("Humanoid", 5)
        if not hum then return end  -- malformed character; skip

        -- Verify the character hasn't already been removed while we waited.
        if pl.Character ~= ch then return end

        local cc = {
            ch   = ch,
            hum  = hum,
            root = ch:FindFirstChild("HumanoidRootPart"),
            head = ch:FindFirstChild("Head"),
            -- ── Text state ──────────────────────────────────────────────────
            -- Pre-computed per-player text data so the render loop does zero
            -- health math, zero string building, and zero Color3 allocs except
            -- when health actually changes or the integer distance changes.
            txt = {
                hpStr      = "",     -- "♥ 100%" — rebuilt by HealthChanged
                r          = 0,      -- pre-computed colour components
                g          = 1,
                lastDist   = -1,     -- last integer distance; -1 forces first build
                colorDirty = true,   -- true whenever health changed since last rebuild
            },
        }
        espCharCache[pl] = cc

        -- Pre-create text drawings and set the player's name immediately.
        -- Name is static for the session — setting it once here means the
        -- render loop never needs to touch t.name.Text at all.
        local t = getEspText(pl)
        t.name.Text = pl.DisplayName

        -- ── HealthChanged ────────────────────────────────────────────────────
        -- Fires whenever Health changes. We pre-compute the health string and
        -- colour components here so the render loop is just a table read.
        -- newC3 is called only inside the render loop when it also needs to
        -- rebuild the info string (dist changed OR colorDirty), not here —
        -- that way one alloc covers both changes in the same frame.
        local function onHealth(newHealth)
            local maxHp = mmax(hum.MaxHealth, 1)
            local hpPct = mclamp(newHealth / maxHp, 0, 1)
            cc.txt.r          = hpPct < 0.5 and 1 or (2 - hpPct * 2)
            cc.txt.g          = hpPct > 0.5 and 1 or (hpPct * 2)
            cc.txt.hpStr      = "♥ " .. mfloor(hpPct * 100 + 0.5) .. "%"
            cc.txt.colorDirty = true
        end

        -- Seed the text state with the current health before any event fires.
        onHealth(hum.Health)

        state.healthConn = hum.HealthChanged:Connect(onHealth)

        -- Remove any stale entry (e.g. rapid respawn edge case) then add fresh.
        espRemoveFromList(pl)
        espRenderList[#espRenderList + 1] = { pl = pl, cc = cc }

        -- Immediately remove from render list when the humanoid dies so the
        -- render loop never sees a dead player.
        state.humConn = hum.Died:Connect(function()
            espRemoveFromList(pl)
            espHidePlayer(pl)
        end)
    end

    state.charAddedConn = pl.CharacterAdded:Connect(function(ch)
        -- Spawn so WaitForChild doesn't block the event thread.
        task.spawn(onCharacter, ch)
    end)

    state.charRemovingConn = pl.CharacterRemoving:Connect(function()
        if state.humConn    then state.humConn:Disconnect();    state.humConn    = nil end
        if state.healthConn then state.healthConn:Disconnect(); state.healthConn = nil end
        espRemoveFromList(pl)
        espHidePlayer(pl)
        espCharCache[pl] = nil
    end)

    espPlayerConns[pl] = state

    -- Bootstrap: if the player already has a living character (e.g. late-load).
    if pl.Character then
        task.spawn(onCharacter, pl.Character)
    end
end

-- ── Player cache + event wiring ───────────────────────────────────────────────
local playerCache = {}

do
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            playerCache[#playerCache + 1] = p
            setupEspPlayer(p)
        end
    end

    Players.PlayerAdded:Connect(function(p)
        playerCache[#playerCache + 1] = p
        setupEspPlayer(p)
    end)

    Players.PlayerRemoving:Connect(function(p)
        -- Remove from aimbot player cache (swap-remove, O(1)).
        for i = 1, #playerCache do
            if playerCache[i] == p then
                playerCache[i] = playerCache[#playerCache]
                playerCache[#playerCache] = nil
                break
            end
        end

        -- Evict aimbot per-character caches.
        local char = p.Character
        if char then
            visCache[char]        = nil
            targetPartCache[char] = nil
        end

        -- Disconnect all ESP event connections for this player.
        local state = espPlayerConns[p]
        if state then
            if state.charAddedConn    then state.charAddedConn:Disconnect()    end
            if state.charRemovingConn then state.charRemovingConn:Disconnect() end
            if state.humConn          then state.humConn:Disconnect()          end
            if state.healthConn       then state.healthConn:Disconnect()       end
            espPlayerConns[p] = nil
        end

        -- Remove from ESP render list and destroy all drawing objects.
        espRemoveFromList(p)
        espCharCache[p] = nil
        espDestroyPools(p)
    end)
end

-- ============================================================
-- [4] TARGET SYSTEM
-- ============================================================

-- Screen centre (cached, only recomputed on resize)
local cachedScreenCenter = Vector2.new(0, 0)
local lastViewportSize   = Vector2.new(0, 0)

local function getScreenCenter()
    local vp = Camera.ViewportSize
    if vp ~= lastViewportSize then
        cachedScreenCenter = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
        lastViewportSize   = vp
    end
    return cachedScreenCenter
end

-- ── RaycastParams ─────────────────────────────────────────────────────────────
-- Two SEPARATE param objects: one for visibility checks, one for pre-shot.
-- Sharing a single object caused FilterDescendantsInstances to be clobbered
-- between the two call sites on the same frame.
local visRayParams  = RaycastParams.new()
visRayParams.FilterType = Enum.RaycastFilterType.Blacklist

local shotRayParams = RaycastParams.new()
shotRayParams.FilterType = Enum.RaycastFilterType.Blacklist

local function refreshRayFilter()
    local char = LocalPlayer.Character
    local list = char and {char} or {}
    visRayParams.FilterDescendantsInstances  = list
    shotRayParams.FilterDescendantsInstances = list
end

refreshRayFilter()  -- initialise immediately

LocalPlayer.CharacterAdded:Connect(refreshRayFilter)
LocalPlayer.CharacterRemoving:Connect(function()
    visRayParams.FilterDescendantsInstances  = {}
    shotRayParams.FilterDescendantsInstances = {}
end)

-- ── Visibility cache ───────────────────────────────────────────────────────────
-- Entries are reused (mutated in-place) to avoid per-check table allocation.
-- Layout: visCache[char] = { [1]=result:bool, [2]=lastCheck:number }
-- (Table declared in [3] so PlayerRemoving can evict entries on disconnect.)

-- FIX: Accept pre-cached `now` from the caller so isVisible does not need
-- its own tick() call on every invocation inside the hot target-scan loop.
local function isVisible(targetPart, targetChar, now)
    local cached = visCache[targetChar]

    if cached and (now - cached[2]) < 0.1 then  -- 0.1 s cache window
        return cached[1]
    end

    local origin    = Camera.CFrame.Position
    local direction = targetPart.Position - origin
    local hit       = Workspace:Raycast(origin, direction, visRayParams)
    local visible   = not hit or hit.Instance:IsDescendantOf(targetChar)

    -- Reuse existing table if present, else create once
    if cached then
        cached[1] = visible
        cached[2] = now
    else
        visCache[targetChar] = {visible, now}
    end

    return visible
end

-- Periodic full flush: table.clear() in-place, no allocation.
-- Thread ref stored so it can be cancelled on ScreenGui.Destroying.
local visCacheFlushThread = task.spawn(function()
    while true do
        task.wait(5)
        table.clear(visCache)
    end
end)

-- ── Target-part resolution ────────────────────────────────────────────────────
-- "Random" assigns a part per character on first look and keeps it stable.
-- (Table declared in [3] so PlayerRemoving can evict entries on disconnect.)

local function clearTargetPartCache()
    table.clear(targetPartCache)
end

local function getTargetPart(character)
    local name = Settings.TargetPart
    if name == "Random" then
        if not targetPartCache[character] then
            targetPartCache[character] = mrand(1, 2) == 1 and "Head" or "HumanoidRootPart"
        end
        return character:FindFirstChild(targetPartCache[character])
    elseif name == "Torso" then
        return character:FindFirstChild("HumanoidRootPart")
    else
        return character:FindFirstChild(name)
    end
end

-- isWhitelisted returns true if this player should be SKIPPED (never targeted).
local function isWhitelisted(player)
    local playerTeam = player.Team

    -- Rule 1: classic same-team protection
    if Settings.TeamCheck then
        local myTeam = LocalPlayer.Team
        if myTeam ~= nil and playerTeam == myTeam then
            return true
        end
    end

    -- Rule 2: named-team whitelist (multi-select)
    if playerTeam and Settings.WhitelistedTeams[playerTeam.Name] then
        return true
    end

    return false
end

-- FIX: Accept pre-cached `now` so the 
