-- [11] DRAWING SYSTEM
-- ============================================================

-- RenderProperty: creates a Drawing object of `drawType` and bulk-applies
-- every key/value pair from `props`, then returns the object.
-- Uses the module-level `newDrawing` shortcut to avoid repeated global lookups.
-- All colour values should be passed as Color3 (newC3 / Color3.fromRGB).
-- All 2-D positions/sizes should be passed as Vector2 (newV2).
local function RenderProperty(drawType, props)
    local obj = newDrawing(drawType)
    for k, v in pairs(props) do
        obj[k] = v
    end
    return obj
end

-- ── FOV circle ────────────────────────────────────────────────────────────────
-- Rendered every frame while the aimbot step is running.
local fovCircle = RenderProperty("Circle", {
    Thickness = 1,
    NumSides  = 64,
    Filled    = false,
    Visible   = false,
    Color     = newC3(1, 1, 0),   -- yellow
})

-- ── ESP box pool ──────────────────────────────────────────────────────────────
-- One Drawing "Square" per player, created on first sight and reused every
-- frame.  Indexed by Player object so PlayerRemoving can evict entries.
-- The pool table itself is declared in [10] so toggle callbacks can reach it.
local function getEspBox(player)
    if not espBoxPool[player] then
        espBoxPool[player] = RenderProperty("Square", {
            Thickness = 1,
            Filled    = false,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),  -- orange
        })
    end
    return espBoxPool[player]
end

-- ── ESP circle/mark pool ──────────────────────────────────────────────────────
-- One Drawing "Circle" per player for "Circle/Mark" ESP mode.
-- Renders as a small filled dot at the player's on-screen position.
local function getEspCharm(player)
    if not espCharmPool[player] then
        espCharmPool[player] = RenderProperty("Circle", {
            Thickness = 1,
            NumSides  = 32,
            Radius    = 5,
            Filled    = true,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),  -- orange (matches box colour)
        })
    end
    return espCharmPool[player]
end

-- ── ESP highlight pool ────────────────────────────────────────────────────────
-- One Highlight instance per player for "Charm" ESP mode.
-- Parented to EspHighlightHandler (inside MainFrame) so they live and die
-- with the GUI without needing explicit cleanup on every type switch.
local function getEspHighlight(player)
    if not espHighlightPool[player] then
        local hl = Instance.new("Highlight")
        hl.Name               = "EspHighlight_" .. player.Name
        hl.FillColor          = Color3.fromRGB(255, 69, 0)   -- orange fill
        hl.OutlineColor       = Color3.fromRGB(255, 255, 255) -- white outline
        hl.FillTransparency   = 0.5
        hl.OutlineTransparency = 0
        hl.Enabled            = false
        hl.Parent             = EspHighlightHandler
        espHighlightPool[player] = hl
    end
    return espHighlightPool[player]
end

-- ── Character part cache ──────────────────────────────────────────────────────
-- Returns a table { ch, hum, root, head } for pl, or nil if the character is
-- absent / has no Humanoid.  The table is rebuilt only when pl.Character differs
-- from the last cached value, so FindFirstChildOfClass / FindFirstChild are
-- never called inside the hot RenderStepped loop on a cache hit.
local function getEspChar(pl)
    local ch = pl.Character
    if not ch then espCharCache[pl] = nil; return nil end
    local c = espCharCache[pl]
    if c and c.ch == ch then return c end       -- cache hit — no child searches
    -- Cache miss: character changed or first sight. Rebuild.
    local hum  = ch:FindFirstChildOfClass("Humanoid")
    if not hum then espCharCache[pl] = nil; return nil end
    local root = ch:FindFirstChild("HumanoidRootPart")
    local head = ch:FindFirstChild("Head")
    -- Pre-bake foot and head-top offsets so box rendering never touches
    -- HipHeight or part.Size inside the hot RenderStepped loop.
    -- feetOffset: world-space Y delta from root centre down to the ground plane.
    -- headHalfY:  world-space Y delta from head centre up to the top of the head.
    local feetOffset = root and -(hum.HipHeight + root.Size.Y * 0.5) or 0
    local headHalfY  = head and  (head.Size.Y * 0.5)                 or 0.25
    c = { ch         = ch,
          hum        = hum,
          root       = root,
          head       = head,
          feetOffset = feetOffset,
          headHalfY  = headHalfY }
    espCharCache[pl] = c
    return c
end

-- ── ESP text pool ─────────────────────────────────────────────────────────────
-- Two Drawing "Text" objects per player:
--   name  → DisplayName, white, drawn ~22 px above the projected head top
--   info  → "♥ HP%  dist m", health-coloured, drawn ~11 px above head top
-- Both are centred horizontally on the head screen position.
local function getEspText(player)
    if not espTextPool[player] then
        espTextPool[player] = {
            name = RenderProperty("Text", {
                Text         = "",
                Size         = 11,
                Font         = Drawing.Fonts.UI,
                Color        = newC3(1, 1, 1),
                Outline      = true,
                OutlineColor = newC3(0, 0, 0),
                Center       = true,
                Visible      = false,
            }),
            info = RenderProperty("Text", {
                Text         = "",
                Size         = 10,
                Font         = Drawing.Fonts.UI,
                Color        = newC3(0.4, 1, 0.4),
                Outline      = true,
                OutlineColor = newC3(0, 0, 0),
                Center       = true,
                Visible      = false,
            }),
        }
    end
    return espTextPool[player]
end

-- Cleanup: remove all Drawing objects on GUI teardown so they don't outlive
-- the script on executor reset.
ScreenGui.Destroying:Connect(function()
    pcall(function() fovCircle:Remove() end)
    for _, box in pairs(espBoxPool) do
        pcall(function() box:Remove() end)
    end
    for _, charm in pairs(espCharmPool) do
        pcall(function() charm:Remove() end)
    end
    -- Highlights are parented to EspHighlightHandler which is inside MainFrame /
    -- ScreenGui, so they are auto-destroyed. Explicit destroy here handles any
    -- that may have been re-parented or pools that outlive the hierarchy.
    for _, hl in pairs(espHighlightPool) do
        pcall(function() hl:Destroy() end)
    end
    for _, t in pairs(espTextPool) do
        pcall(function() t.name:Remove() end)
        pcall(function() t.info:Remove() end)
    end
end)

-- ============================================================
-- [12] AIMBOT STEP  (only runs while Enabled = true)
-- ============================================================

local aimbotConnection = nil  -- RenderStepped connection; nil when stopped

-- stopAimbot: disconnects the step, hides the FOV circle, and wipes all
-- transient aim state so nothing leaks when the aimbot is re-enabled later.
stopAimbot = function()
    if aimbotConnection then
        aimbotConnection:Disconnect()
        aimbotConnection = nil
    end
    fovCircle.Visible = false
    currentTarget     = nil
    isReacting         = false
    overrideActive     = false
    recentTargetPlayer = nil
    recentTargetLostAt = -math.huge
    lastTargetLostTime = 0
    trackingDistance   = 200
    resetSpring()
    resetPrediction()
end

-- startAimbot: connects the step. Guard against double-connect.
startAimbot = function()
    if aimbotConnection then return end
    -- Ensure spring constants are fresh before the first frame.
    refreshSpringConstants()

    aimbotConnection = RunService.RenderStepped:Connect(function(dt)
        local camCF  = Camera.CFrame
        local camPos = camCF.Position
        local now    = tick()

        -- FOV circle tracks screen centre and current FOV setting.
        local sc = getScreenCenter()
        fovCircle.Position = newV2(sc.X, sc.Y)
        fovCircle.Radius   = Settings.FOV
        fovCircle.Visible  = true

        -- ── Target acquisition ────────────────────────────────────────────────
        local targetPlayer, targetPart, rootPart, targetHumanoid =
            getClosestTarget(now)

        if targetPlayer and targetPlayer ~= currentTarget then
            onNewTargetAcquired(targetPlayer, now)
        elseif not targetPlayer then
            if currentTarget ~= nil then
                recentTargetPlayer = currentTarget
                recentTargetLostAt = now
                lastTargetLostTime = now
            end
            currentTarget = nil
            isReacting    = false
            resetSpring()
            resetPrediction()
        end

        if shouldWaitForReaction(now) then return end
        if not (targetPlayer and targetPart and rootPart and targetHumanoid) then return end

        -- ── Player override detection ─────────────────────────────────────────
        local mouseDelta = UIS:GetMouseDelta()
        if mouseDelta.Magnitude >= Settings.OverrideThreshold then
            overrideActive = true
            overrideUntil  = now + Settings.OverrideCooldown
            currentTarget  = nil
            resetSpring()
            resetPrediction()
        end

        if overrideActive then
            if now < overrideUntil then return end
            overrideActive = false
        end

        local safeDt = mclamp(dt, 0.001, 0.05)

        -- ── Kalman-filter prediction ──────────────────────────────────────────
        local rawPos = rootPart.Position
        predSmoothedVel, predSmoothedAccel = updateKalman(rawPos, safeDt)
        trackingDistance = (rawPos - camPos).Magnitude

        local velMag    = predSmoothedVel.Magnitude
        local accelMag  = predSmoothedAccel.Magnitude

        local targetWalkSpeed = mmax(targetHumanoid.WalkSpeed, 1)
        local velScale   = mclamp(velMag / targetWalkSpeed, 0, 1)
        local changeRate = accelMag / mmax(velMag, 1)
        local stability  = mclamp(1 - changeRate * 0.12, 0.35, 1.0)

        local adaptiveFactor = Settings.AdaptivePrediction
            and (velScale * stability) or 1.0

        -- Latency penalty: smoothly reduces prediction horizon at high ping.
        local latencyPenalty = 1.0
        if cachedPing > 0.1 then
            if cachedPing < 0.15 then
                latencyPenalty = 1.0 - (cachedPing - 0.1) * 3.0
            elseif cachedPing < 0.2 then
                latencyPenalty = 0.85 - (cachedPing - 0.15) * 4.0
            else
                latencyPenalty = mmax(0.65 - (cachedPing - 0.2) * 4.0, 0.45)
            end
        end

        local predTime = cachedPing * adaptiveFactor * latencyPenalty
            * Settings.PredictionFactor

        -- Damp the acceleration term at large look-aheads to avoid overshoot.
        local accelDamping = predTime > 0.15
            and mclamp(1.0 - (predTime - 0.15) * 5.0, 0.25, 1.0) or 1.0

        local aimPos = Settings.Prediction
            and (targetPart.Position
                + predSmoothedVel   * predTime
                + predSmoothedAccel * (0.5 * predTime * predTime * accelDamping))
            or  targetPart.Position

        if Settings.Mode == "Legit" then
            local dist = (targetPart.Position - camPos).Magnitude
            aimPos = aimPos + generateAimError(predSmoothedVel, dist, dt)
        end

        -- ── Occlusion correction ──────────────────────────────────────────────
        local aimDir  = (aimPos - camPos).Unit
        local aimDist = (aimPos - camPos).Magnitude
        local preShotCheck = Workspace:Raycast(camPos, aimDir * aimDist, shotRayParams)

        if preShotCheck and preShotCheck.Instance then
            local hitPart = preShotCheck.Instance
            local hitChar = hitPart:FindFirstAncestorOfClass("Model")
            if hitChar == targetPlayer.Character and hitPart ~= targetPart then
                aimPos = aimPos:Lerp(targetPart.Position, 0.7)
            end
        end

        -- ── Spring-damper smoothing ───────────────────────────────────────────
        if Spr.pos == nil then
            Spr.pos = camPos + camCF.LookVector * 200
        end

        if Settings.Smoothness ~= Spr.lastS then
            refreshSpringConstants()
        end

        local springForce = (aimPos - Spr.pos) * Spr.k
                          - Spr.vel * Spr.d
        -- ±3% jitter simulates natural wrist inconsistency
        springForce = springForce * (1 + (mrand() - 0.5) * 0.06)

        Spr.vel = Spr.vel + springForce * safeDt
        Spr.pos = Spr.pos + Spr.vel    * safeDt

        Camera.CFrame = CFrame.new(camPos, Spr.pos)
    end)
end

-- ============================================================
-- [12b] ESP STEP  (independent of aimbot — own connection)
-- ============================================================

local espConnection = nil

stopEsp = function()
    if espConnection then
        espConnection:Disconnect()
        espConnection = nil
    end
    for _, box   in pairs(espBoxPool)       do box.Visible   = false end
    for _, charm in pairs(espCharmPool)     do charm.Visible = false end
    for _, hl    in pairs(espHighlightPool) do hl.Enabled    = false end
    for _, t     in pairs(espTextPool)      do
        t.name.Visible = false
        t.info.Visible = false
    end
end

startEsp = function()
    if espConnection then return end  -- guard against double-connect

    espConnection = RunService.RenderStepped:Connect(function()

        -- ── Hoist all frame-constant reads before the player loop ─────────────
        -- Every Settings / Camera / team read inside the loop is a table lookup;
        -- hoisting them pays that cost exactly once per frame regardless of lobby size.
        local playerEspOn = Settings.PlayerEspEnabled
        local espType     = Settings.EspType
        local textOn      = Settings.EspTextEnabled
        local teamCheck   = Settings.EspTeamCheck
        local teamColors  = Settings.EspTeamColors
        local myTeam      = LocalPlayer.Team
        local camPos      = Camera.CFrame.Position

        -- Reuse the active-set table instead of allocating 4 new ones each frame.
        -- At 100 players × 60 fps that eliminates ~24 000 table GC events/minute.
        table.clear(espActiveSet)

        -- ── Bulk early-exit when player sub-toggle is OFF ─────────────────────
        if not playerEspOn then
            for _, box   in pairs(espBoxPool)       do box.Visible   = false end
            for _, charm in pairs(espCharmPool)     do charm.Visible = false end
            for _, hl    in pairs(espHighlightPool) do hl.Enabled    = false end
            for _, t     in pairs(espTextPool) do
                t.name.Visible = false ; t.info.Visible = false
            end
            return
        end

        -- ── Text throttle ─────────────────────────────────────────────────────
        -- String concatenation, newC3 allocation, and an extra viewport call are
        -- expensive per visible player.  At 60 fps the human eye can't perceive
        -- HP / distance changing faster than ~15 fps, so we skip the heavy work
        -- 3 out of every 4 frames.  Screen position is still updated every frame.
        local doTextUpdate = (espTextTick % ESP_TEXT_EVERY == 0)
        espTextTick = espTextTick + 1

        -- ── Main player loop ──────────────────────────────────────────────────
        for i = 1, #playerCache do
            local pl = playerCache[i]

            -- Team filter (frame-constant teamCheck / myTeam used here)
            if teamCheck and myTeam and pl.Team == myTeam then continue end

            -- Character cache lookup — zero FindFirstChild calls on a cache hit.
            -- The cache rebuilds automatically whenever pl.Character changes
            -- (respawn, character swap), catching the new parts in one go.
            local cc = getEspChar(pl)
            if not cc or cc.hum.Health <= 0 then continue end

            local root = cc.root
            if not root then continue end

            -- ── Single cheap root viewport check ─────────────────────────────
            -- If the root is behind the camera (rsp.Z ≤ 0) we skip all further
            -- work for this player.  For Box mode this alone saves 8 extra
            -- WorldToViewportPoint calls per off-screen player — at 80 players
            -- that's up to 640 avoided calls/frame when facing away from the crowd.
            local rsp         = Camera:WorldToViewportPoint(root.Position)
            local rootVisible = rsp.Z > 0

            -- Resolve draw colour once — ESP_COLOR_DEFAULT is a cached constant
            -- so no Color3 allocation occurs when team colours are OFF.
            local drawColor = (teamColors and pl.Team)
                and pl.Team.TeamColor.Color
                or  ESP_COLOR_DEFAULT

            espActiveSet[pl] = true

            -- ── ESP type rendering ────────────────────────────────────────────
            if espType == "Box" then
                -- ── 2-point head/feet projection (replaces 8-corner OBB) ──────────
                -- Projects only the top of the head and the ground beneath the root,
                -- then derives box width from screen height via a fixed humanoid
                -- aspect ratio (~0.45).  Cost: 2 WorldToViewportPoint instead of 8,
                -- no GetBoundingBox() model traversal.  Accurately fits limbs for
                -- standard Roblox R6/R15 rigs; large side-extending accessories/tools
                -- may slightly overflow but this is imperceptible at normal play distances.
                if rootVisible and cc.head then
                    local headTopPos = cc.head.Position + Vector3.new(0, cc.headHalfY, 0)
                    local feetPos    = root.Position    + Vector3.new(0, cc.feetOffset, 0)

                    local spTop = Camera:WorldToViewportPoint(headTopPos)
                    local spBot = Camera:WorldToViewportPoint(feetPos)

                    if spTop.Z > 0 and spBot.Z > 0 then
                        local h    = spBot.Y - spTop.Y               -- screen height
                        local w    = h * 0.45                        -- humanoid aspect ratio
                        local midX = (spTop.X + spBot.X) * 0.5      -- lean-corrected centre

                        if h > 1 then  -- skip sub-pixel boxes
                            local box = getEspBox(pl)
                            box.Size     = newV2(w, h)
                            box.Position = newV2(midX - w * 0.5, spTop.Y)
                            box.Color    = drawColor
                            box.Visible  = true
                        else
                            if espBoxPool[pl] then espBoxPool[pl].Visible = false end
                        end
                    else
                        if espBoxPool[pl] then espBoxPool[pl].Visible = false end
                    end
                else
                    if espBoxPool[pl] then espBoxPool[pl].Visible = false end
                end
                if espCharmPool[pl]     then espCharmPool[pl].Visible     = false end
                if espHighlightPool[pl] then espHighlightPool[pl].Enabled = false end

            elseif espType == "Circle/Mark" then
                -- rsp already computed above — no second WorldToViewportPoint needed.
                if rootVisible then
                    local charm = getEspCharm(pl)
                    charm.Position = newV2(rsp.X, rsp.Y)
                    charm.Color    = drawColor
                    charm.Visible  = true
                else
                    if espCharmPool[pl] then espCharmPool[pl].Visible = false end
                end
                if espBoxPool[pl]       then espBoxPool[pl].Visible       = false end
                if espHighlightPool[pl] then espHighlightPool[pl].Enabled = false end

            elseif espType == "Charm" then
                local hl = getEspHighlight(pl)
                hl.Adornee   = cc.ch
                hl.FillColor = drawColor
                hl.Enabled   = true
                if espBoxPool[pl]   then espBoxPool[pl].Visible   = false end
                if espCharmPool[pl] then espCharmPool[pl].Visible = false end
            end

            -- ── Text overlay ──────────────────────────────────────────────────
            local head = cc.head
            if textOn and head then
                local headTop = head.Position + Vector3.new(0, cc.headHalfY, 0)
                local sp, onScreen = Camera:WorldToViewportPoint(headTop)

                if onScreen and sp.Z > 0 then
                    local t  = getEspText(pl)
                    -- Screen position updated every frame — cheap, just two V2 writes.
                    t.name.Position = newV2(sp.X, sp.Y - 22)
                    t.info.Position = newV2(sp.X, sp.Y - 11)
                    t.name.Visible  = true
                    t.info.Visible  = true

                    -- Heavy work (string concat, newC3, sqrt) only every N frames.
                    if doTextUpdate then
                        local hum   = cc.hum
                        local maxHp = mmax(hum.MaxHealth, 1)
                        local hpPct = mclamp(hum.Health / maxHp, 0, 1)
                        local r     = hpPct < 0.5 and 1 or (2 - hpPct * 2)
                        local g     = hpPct > 0.5 and 1 or (hpPct * 2)
                        local dist  = mfloor((root.Position - camPos).Magnitude + 0.5)

                        t.name.Text  = pl.DisplayName
                        t.info.Text  = "♥ " .. mfloor(hpPct * 100 + 0.5)
                                    .. "%  •  " .. dist .. "m"
                        t.info.Color = newC3(r, g, 0)
                    end
                else
                    if espTextPool[pl] then
                        espTextPool[pl].name.Visible = false
                        espTextPool[pl].info.Visible = false
                    end
                end
            elseif espTextPool[pl] then
                espTextPool[pl].name.Visible = false
                espTextPool[pl].info.Visible = false
            end
        end

        -- ── Hide-pass: pool entries for players not active this frame ─────────
        for pl, box   in pairs(espBoxPool)       do
            if not espActiveSet[pl] then box.Visible   = false end
        end
        for pl, charm in pairs(espCharmPool)     do
            if not espActiveSet[pl] then charm.Visible = false end
        end
        for pl, hl    in pairs(espHighlightPool) do
            if not espActiveSet[pl] then hl.Enabled    = false end
        end
        for pl, t     in pairs(espTextPool)      do
            if not espActiveSet[pl] then
                t.name.Visible = false ; t.info.Visible = false
            end
        end
    end)
end

-- Also disconnect both connections on GUI destroy.
ScreenGui.Destroying:Connect(stopAimbot)
ScreenGui.Destroying:Connect(stopEsp)

-- ============================================================
-- [13] BOOT  — apply saved settings to UI and start if enabled
-- ============================================================
-- All sections (including startAimbot/stopAimbot in [12]) are now defined,
-- so it is safe to call applySettingsToUI which fires widget callbacks.
applySettingsToUI()

