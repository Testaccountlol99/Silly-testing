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

-- ── ESP optimisation state ────────────────────────────────────────────────────
-- Single Color3 constant for the default orange tint.  Avoids a newC3() call
-- per player per frame when EspTeamColors is OFF.
local ESP_COLOR_DEFAULT = Color3.fromRGB(255, 69, 0)

-- Reused "which players were rendered this frame" table.
-- Cleared with table.clear() at the top of each RenderStepped so the GC
-- never sees 4 fresh table allocations every frame.
local espActiveSet = {}

-- Per-player character part cache { ch, hum, root, head }.
-- Rebuilt only when pl.Character changes, so FindFirstChildOfClass /
-- FindFirstChild are never called inside the hot render loop.
local espCharCache = {}

-- Text throttle: label content (string concat, Color3 alloc, viewport math)
-- is expensive and 60 fps resolution is imperceptible — update every N frames.
local espTextTick    = 0
local ESP_TEXT_EVERY = 4   -- ~15 fps text refresh at 60 fps

local playerCache = {}

do
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            playerCache[#playerCache + 1] = p
        end
    end

    Players.PlayerAdded:Connect(function(p)
        playerCache[#playerCache + 1] = p
    end)

    Players.PlayerRemoving:Connect(function(p)
        -- Swap-remove: O(1) instead of table.remove's O(n) element shift.
        -- Moves the last element into the vacated slot then trims the tail.
        -- Order is not preserved, but playerCache is never iterated in order.
        for i = 1, #playerCache do
            if playerCache[i] == p then
                playerCache[i] = playerCache[#playerCache]
                playerCache[#playerCache] = nil
                break
            end
        end

        -- FIX: Immediately evict stale per-character cache entries so the
        -- Character Model is no longer held alive by the table keys.
        local char = p.Character
        if char then
            visCache[char]        = nil
            targetPartCache[char] = nil
        end

        -- Remove the player's ESP Drawing object (if one was created) so it
        -- doesn't linger on screen after the player disconnects.
        if espBoxPool[p] then
            pcall(function() espBoxPool[p]:Remove() end)
            espBoxPool[p] = nil
        end
        if espCharmPool[p] then
            pcall(function() espCharmPool[p]:Remove() end)
            espCharmPool[p] = nil
        end
        if espHighlightPool[p] then
            pcall(function() espHighlightPool[p]:Destroy() end)
            espHighlightPool[p] = nil
        end
        if espTextPool[p] then
            pcall(function() espTextPool[p].name:Remove() end)
            pcall(function() espTextPool[p].info:Remove() end)
            espTextPool[p] = nil
        end
        espCharCache[p] = nil
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

-- FIX: Accept pre-cached `now` so the single tick() call at the top of the
-- render loop is shared across getClosestTarget -> isVisible, avoiding
-- redundant OS calls in what is already a per-frame hot path.
--
-- FIX (performance): Replace Vector2.new() + .Magnitude for the screen-space
-- distance cull with a raw squared-distance check (dsx^2 + dsy^2 < fovSq).
-- This eliminates one Vector2 allocation and one sqrt() per candidate per
-- frame.  The actual pixel distance (for scoring) is only computed once, on
-- the candidate that already passed the cheaper squared cull.
local function getClosestTarget(now)
    local myChar = LocalPlayer.Character
    if not myChar then return nil, nil, nil, nil end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return nil, nil, nil, nil end

    local myPos        = myRoot.Position
    local screenCenter = getScreenCenter()
    local scX          = screenCenter.X
    local scY          = screenCenter.Y
    local healthMode   = Settings.HealthCheckEnabled

    -- Pre-compute squared thresholds once per call
    local maxDist   = Settings.MaxDistance
    local maxDistSq = maxDist * maxDist
    local fov       = Settings.FOV
    local fovSq     = fov * fov

    local bestScore  = mhuge
    local bestPlayer, bestPart, bestRoot, bestHumanoid = nil, nil, nil, nil

    for _, player in ipairs(playerCache) do
        if isWhitelisted(player) then continue end

        local char = player.Character
        if not char then continue end

        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then continue end

        -- Health range filter
        if healthMode then
            local maxHp = humanoid.MaxHealth
            local hpPct = maxHp > 0 and (humanoid.Health / maxHp * 100) or 0
            if hpPct < Settings.HealthMinHP or hpPct > Settings.HealthMaxHP then continue end
        end

        local targetPart = getTargetPart(char)
        local rootPart   = char:FindFirstChild("HumanoidRootPart")
        if not targetPart or not rootPart then continue end

        -- World-distance cull: squared comparison avoids sqrt (cheap guard)
        local dp = targetPart.Position - myPos
        if dp.X*dp.X + dp.Y*dp.Y + dp.Z*dp.Z > maxDistSq then continue end

        local screenPos, onScreen = Camera:WorldToViewportPoint(targetPart.Position)
        if not onScreen then continue end

        -- Screen-space cull: squared comparison avoids Vector2 allocation + sqrt
        local dsx = screenPos.X - scX
        local dsy = screenPos.Y - scY
        local screenDistSq = dsx*dsx + dsy*dsy
        if screenDistSq >= fovSq then continue end

        -- Scoring (only sqrt when this candidate has passed all cheaper filters)
        local score = healthMode and humanoid.Health or msqrt(screenDistSq)

        -- HYSTERESIS: the current target gets a virtual score discount so a
        -- challenger must be measurably closer before we switch, eliminating
        -- frame-to-frame flicker between near-equidistant candidates.
        local effectiveScore = (player == currentTarget and not healthMode)
            and (score - 15) or score

        if effectiveScore < bestScore
        and (not Settings.WallCheck or isVisible(targetPart, char, now)) then
            bestPlayer   = player
            bestPart     = targetPart
            bestRoot     = rootPart
            bestHumanoid = humanoid
            bestScore    = effectiveScore
        end
    end

    return bestPlayer, bestPart, bestRoot, bestHumanoid
end

-- ============================================================
-- [5] AIM STATE  (reaction, spring smoother, humanised tracking)
-- ============================================================

local currentTarget   = nil
local isReacting      = false
local reactionEndTime = 0
local alertnessLevel  = 0.5

-- ── Player override state ─────────────────────────────────────────────────────
local overrideActive = false
local overrideUntil  = 0

-- Spring-damper state: all fields in one table so only one chunk-level slot
-- is used instead of five.  Field names are abbreviated for inner-loop speed.
--   pos   = current look-at point the camera is being dragged toward
--   vel   = spring velocity in world-space (metres/s)
--   k     = cached stiffness  (recomputed when Smoothness changes)
--   d     = cached damping
--   lastS = the Smoothness value k/d were computed for (change detector)
local Spr = {pos=nil, vel=ZERO3, k=0, d=0, lastS=-1}

local function refreshSpringConstants()
    local s = Settings.Smoothness
    Spr.k   = 18 + (s ^ 1.6) * 560
    -- Damping ratio 0.70 -> lightly underdamped
    Spr.d   = 0.70 * 2 * msqrt(Spr.k)
    Spr.lastS = s
end

local function resetSpring()
    Spr.pos = nil
    Spr.vel = ZERO3
end

-- ── Kalman filter: constant-velocity model, one independent filter per axis ──
-- Replaces the old magic-alpha EMA.  The filter tracks position + velocity and
-- produces principled noise rejection.
--   State:  s = [pos, vel]   Transition (dt): F = [[1,dt],[0,1]]
--   Observation: H = [1,0]   Process noise: Q = diag(1e-3, 0.6)
--   Measurement noise: R = 0.08
--
-- All four state arrays (pos, vel, covariance P, initialised flag) live in
-- one table so only a single chunk-level slot is needed.
-- K.P[i] = flat {P11,P12,P21,P22} for axis i.
local K = {
    pos  = {0, 0, 0},
    vel  = {0, 0, 0},
    P    = {{1,0,0,1}, {1,0,0,1}, {1,0,0,1}},
    init = false,
}

local predSmoothedVel   = ZERO3  -- Kalman-estimated velocity  (used by render loop)
local predSmoothedAccel = ZERO3  -- finite-difference accel from Kalman vel

local function resetPrediction()
    K.pos  = {0, 0, 0}
    K.vel  = {0, 0, 0}
    K.P    = {{1,0,0,1}, {1,0,0,1}, {1,0,0,1}}
    K.init = false
    predSmoothedVel   = ZERO3
    predSmoothedAccel = ZERO3
end

-- Returns estimated velocity and acceleration vectors.
-- `meas` is the observed Vector3 position of the target part this frame.
local function updateKalman(meas, dt)
    local mx = {meas.X, meas.Y, meas.Z}

    if not K.init then
        K.pos  = {mx[1], mx[2], mx[3]}
        K.vel  = {0, 0, 0}
        K.init = true
        return ZERO3, ZERO3
    end

    local prevVel = {K.vel[1], K.vel[2], K.vel[3]}

    for i = 1, 3 do
        local p   = K.pos[i]
        local v   = K.vel[i]
        local P11 = K.P[i][1]; local P12 = K.P[i][2]
        local P21 = K.P[i][3]; local P22 = K.P[i][4]

        -- ── Predict ──────────────────────────────────────────────────────────
        local pPred = p + v * dt
        local vPred = v
        -- P_pred = F*P*F' + Q  (Q_POS=1e-3, Q_VEL=0.6 inlined)
        local PP11 = P11 + dt*(P12 + P21) + dt*dt*P22 + 1e-3
        local PP12 = P12 + dt*P22
        local PP21 = P21 + dt*P22
        local PP22 = P22 + 0.6

        -- ── Update (observe position) ─────────────────────────────────────
        local S  = PP11 + 0.08  -- R_POS inlined
        local K1 = PP11 / S
        local K2 = PP21 / S
        local innov = mx[i] - pPred

        K.pos[i] = pPred + K1 * innov
        K.vel[i] = vPred + K2 * innov

        -- Covariance update  (Joseph form: (I-KH)*P for numerical stability)
        K.P[i][1] = (1 - K1) * PP11
        K.P[i][2] = (1 - K1) * PP12
        K.P[i][3] = PP21 - K2 * PP11
        K.P[i][4] = PP22 - K2 * PP21
    end

    local estVel = Vector3.new(K.vel[1], K.vel[2], K.vel[3])
    local estAccel = Vector3.new(
        (K.vel[1] - prevVel[1]) / dt,
        (K.vel[2] - prevVel[2]) / dt,
        (K.vel[3] - prevVel[3]) / dt
    )
    return estVel, estAccel
end

-- ── Seeded fBm value noise ────────────────────────────────────────────────────
-- NOISE_TABLE, hashLookup, catmullRom, valueNoise1D are all confined to this
-- do block.  Only `smoothNoise` escapes as a chunk-level upvalue, saving four
-- chunk-level local slots (NOISE_TABLE + 3 helper functions).
local smoothNoise
do
    local NOISE_TABLE = {}
    for i = 1, 256 do
        NOISE_TABLE[i] = mrand() * 2 - 1  -- uniform in [-1, 1]
    end

    local function hashLookup(i)
        return NOISE_TABLE[(i % 256) + 1]
    end

    local function catmullRom(v0, v1, v2, v3, t)
        local t2 = t * t
        local t3 = t2 * t
        return 0.5 * ( (2*v1)
                     + (-v0 + v2)                * t
                     + (2*v0 - 5*v1 + 4*v2 - v3) * t2
                     + (-v0 + 3*v1 - 3*v2 + v3)  * t3 )
    end

    local function valueNoise1D(x)
        local i    = mfloor(x)
        local frac = x - i
        return mclamp(catmullRom(
            hashLookup(i-1), hashLookup(i),
            hashLookup(i+1), hashLookup(i+2), frac), -1, 1)
    end

    -- 4-octave fBm: persistence 0.5, lacunarity 2.0.
    -- Total weight sum = 0.9375; normalised to [-1, 1].
    smoothNoise = function(x)
        return mclamp(
            ( valueNoise1D(x)       * 0.5
            + valueNoise1D(x * 2.0) * 0.25
            + valueNoise1D(x * 4.0) * 0.125
            + valueNoise1D(x * 8.0) * 0.0625 ) * (1 / 0.9375),
        -1, 1)
    end
end

-- ── Improved alertness system ─────────────────────────────────────────────────
-- Tracks engagement duration, distance, and a fatigue component rather than a
-- simple ±constant per-second tick.  Updates 10× per second for smoother ramp.
local trackingStartTime  = 0     -- tick() when current target was first locked
local lastTargetLostTime = 0     -- tick() when we last had a target (for decay rate)
local trackingDistance   = 200   -- world distance to current target (updated per frame)

-- FIX: Store the thread reference so it can be cancelled when the GUI is
-- destroyed (prevents orphaned threads accumulating on re-runs / resets).
local alertnessThread = task.spawn(function()
    while true do
        task.wait(0.1)   -- 10 Hz for smooth ramp
        if currentTarget == nil then
            -- Fast post-combat decay for a couple of seconds, then slow idle decay.
            local timeSinceLost = tick() - lastTargetLostTime
            local decayRate = timeSinceLost < 3.0 and 0.02 or 0.008
            alertnessLevel = mmax(0.2, alertnessLevel - decayRate)
        else
            -- Ramp is faster for nearby targets and accelerates over the first 5 s.
            local distFactor    = mclamp(1.0 - trackingDistance / mmax(Settings.MaxDistance, 1), 0.2, 1.0)
            local engageSecs    = tick() - trackingStartTime
            local durationBoost = mclamp(engageSecs / 5.0, 0, 0.5)
            local rampRate      = 0.015 * distFactor * (1.0 + durationBoost)
            -- Fatigue: very long continuous engagement slightly dulls alertness.
            if engageSecs > 30 then
                rampRate = rampRate * mclamp(1.0 - (engageSecs - 30) * 0.01, 0.6, 1.0)
            end
            alertnessLevel = mmin(1.0, alertnessLevel + rampRate)
        end
    end
end)

-- ── Reaction time (Box-Muller) ────────────────────────────────────────────────
-- Std dev now scales with alertness: an alert player reacts consistently;
-- a drowsy one is both slower AND more variable.
local function generateReactionTime()
    local u1 = mmax(mrand(), 1e-10)
    local u2 = mrand()
    local stdNormal = msqrt(-2.0 * mlog(u1)) * mcos(TAU * u2)
    -- σ in [0.03 s, 0.07 s] — widest spread when alertness is at floor (0.2).
    local stdDev  = 0.03 + (1.0 - alertnessLevel) * 0.05
    local reaction  = Settings.MeanReactionTime + (stdNormal * stdDev)
    local modifier  = 1.0 - (alertnessLevel * 0.3)
    return mclamp(reaction * modifier, Settings.MinReactionTime, Settings.MaxReactionTime)
end

-- Re-acquisition: switching back to a target seen in the last 2 s is faster.
local recentTargetPlayer  = nil
local recentTargetLostAt  = -math.huge

local function onNewTargetAcquired(newTarget, now)
    if newTarget ~= currentTarget then
        local isReacq = (newTarget == recentTargetPlayer)
            and (now - recentTargetLostAt < 2.0)

        currentTarget      = newTarget
        recentTargetPlayer = newTarget
        trackingStartTime  = now
        isReacting         = true

        local baseReact = generateReactionTime()
        -- Re-acquisitions are ~45% faster (muscle memory / still on-screen)
        reactionEndTime = now + (isReacq and baseReact * 0.55 or baseReact)

        resetSpring()
        resetPrediction()
    end
end

-- FIX: Accept pre-cached `now` to avoid a redundant tick() call per frame.
local function shouldWaitForReaction(now)
    if Settings.Mode ~= "Legit" then return false end
    if isReacting then
        if now < reactionEndTime then
            return true
        else
            isReacting = false
        end
    end
    return false
end

-- ── Humanised tracking: Ornstein-Uhlenbeck bias + fBm shake ──────────────────
-- The old code lerped aimOffset back to ZERO3 every frame so bias always
-- collapsed to centre.  Real grip/wrist bias has a non-zero mean that
-- wanders slowly.  We model this as an Ornstein-Uhlenbeck process: a random
-- walk with weak mean-reversion so it drifts without diverging.
local aimBiasCenter     = ZERO3  -- the wandering "resting point" of the bias
local aimOffset         = ZERO3  -- current bias (chases aimBiasCenter with lag)
local targetVelocityLag = ZERO3
local shakeTime         = 0

-- OU parameters (inlined below as 0.005 / 0.004 to save two chunk-level slots)
local function generateAimError(targetVelocity, distanceToTarget, dt)
    local df   = mclamp(distanceToTarget / Settings.MaxDistance, 0, 1)
    local dErr = df * df * Settings.TrackingError

    -- Velocity lag
    local velMag = targetVelocity.Magnitude
    if velMag > 0.1 then
        targetVelocityLag = targetVelocityLag:Lerp(
            targetVelocity * mclamp(velMag / 50, 0, 1) * 0.15, 0.1)
    else
        targetVelocityLag = targetVelocityLag:Lerp(ZERO3, 0.2)
    end

    -- fBm shake (4-octave seeded noise, unique per session)
    shakeTime = shakeTime + dt * Settings.ShakeIntensity
    local shake = Vector3.new(
        smoothNoise(shakeTime * 6.5)       * dErr * 0.5,
        smoothNoise(shakeTime * 7.3 + 100) * dErr * 0.5,
        smoothNoise(shakeTime * 5.8 + 200) * dErr * 0.3
    )

    -- Ornstein-Uhlenbeck bias center: drifts randomly with weak pull to origin.
    -- Scaled by dErr so bias is larger at long range (harder to hold aim).
    -- OU_REVERSION=0.005, OU_DIFFUSION=0.004 inlined.
    local diff = 0.004 * dErr
    aimBiasCenter = aimBiasCenter * (1 - 0.005) + Vector3.new(
        (mrand() - 0.5) * diff,
        (mrand() - 0.5) * diff,
        (mrand() - 0.5) * diff * 0.4  -- smaller Z drift (depth axis)
    )

    -- aimOffset lags behind the wandering centre — simulates muscle inertia.
    aimOffset = aimOffset:Lerp(aimBiasCenter, 0.06)

    return shake + aimOffset - targetVelocityLag
end

-- ============================================================
-- [6] PING CACHE
-- ============================================================
local cachedPing = 0

-- FIX: Store thread reference for cleanup (see ScreenGui.Destroying in [7]).
local pingThread = task.spawn(function()
    while true do
        task.wait(0.5)
        cachedPing = LocalPlayer:GetNetworkPing()
    end
end)

