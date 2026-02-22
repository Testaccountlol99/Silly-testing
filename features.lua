-- [11] DRAWING SYSTEM
-- ============================================================

local function RenderProperty(drawType, props)
    local obj = newDrawing(drawType)
    for k, v in pairs(props) do
        obj[k] = v
    end
    return obj
end

local fovCircle = RenderProperty("Circle", {
    Thickness = 1,
    NumSides  = 64,
    Filled    = false,
    Visible   = false,
    Color     = newC3(1, 1, 0),
})

local function getEspBox(player)
    if not espBoxPool[player] then
        espBoxPool[player] = RenderProperty("Square", {
            Thickness = 1,
            Filled    = false,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),
        })
    end
    return espBoxPool[player]
end

local function getEspCharm(player)
    if not espCharmPool[player] then
        espCharmPool[player] = RenderProperty("Circle", {
            Thickness = 1,
            NumSides  = 32,
            Radius    = 5,
            Filled    = true,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),
        })
    end
    return espCharmPool[player]
end

local function getEspHighlight(player)
    if not espHighlightPool[player] then
        local hl = Instance.new("Highlight")
        hl.Name               = "EspHighlight_" .. player.Name
        hl.FillColor          = Color3.fromRGB(255, 69, 0)
        hl.OutlineColor       = Color3.fromRGB(255, 255, 255)
        hl.FillTransparency   = 0.5
        hl.OutlineTransparency = 0
        hl.Enabled            = false
        hl.Parent             = EspHighlightHandler
        espHighlightPool[player] = hl
    end
    return espHighlightPool[player]
end

getEspText = function(player)
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

ScreenGui.Destroying:Connect(function()
    pcall(function() fovCircle:Remove() end)
    for _, box in pairs(espBoxPool) do
        pcall(function() box:Remove() end)
    end
    for _, charm in pairs(espCharmPool) do
        pcall(function() charm:Remove() end)
    end
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

local aimbotConnection = nil

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
    resetCameraVelocity()
    resetPartOffset()
end

startAimbot = function()
    if aimbotConnection then return end
    refreshSpringConstants()

    aimbotConnection = RunService.RenderStepped:Connect(function(dt)
        local camCF  = Camera.CFrame
        local camPos = camCF.Position
        local now    = tick()

        local sc = getScreenCenter()
        fovCircle.Position = newV2(sc.X, sc.Y)
        fovCircle.Radius   = Settings.FOV
        fovCircle.Visible  = true

        -- ── Camera velocity (client motion compensation) ──────────────────────
        local camVel = updateCameraVelocity(camPos, dt)

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
            resetCameraVelocity()
            resetPartOffset()
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
            resetCameraVelocity()
            resetPartOffset()
        end

        if overrideActive then
            if now < overrideUntil then return end
            overrideActive = false
        end

        local safeDt = mclamp(dt, 0.001, 0.05)

        -- ── Kalman-filter update (jerk model, feeds ROOT position) ────────────
        local rootPos = rootPart.Position
        predSmoothedVel, predSmoothedAccel, predSmoothedJerk = updateKalman(rootPos, safeDt)
        trackingDistance = (rootPos - camPos).Magnitude

        -- ── Part offset tracking (head/target relative to root) ───────────────
        local partOffset = updatePartOffset(rootPos, targetPart.Position)

        -- ── Prediction horizon computation ────────────────────────────────────
        local velMag   = predSmoothedVel.Magnitude
        local accelMag = predSmoothedAccel.Magnitude

        local targetWalkSpeed = mmax(targetHumanoid.WalkSpeed, 1)
        local velScale   = mclamp(velMag / targetWalkSpeed, 0, 1)
        local changeRate = accelMag / mmax(velMag, 1)
        local stability  = mclamp(1 - changeRate * 0.08, 0.4, 1.0)

        local adaptiveFactor = Settings.AdaptivePrediction
            and (velScale * stability) or 1.0

        local basePing = mmax(cachedPing, Settings.MinPredictionTime)

        -- Latency penalty: smoothly reduces prediction horizon at high ping
        local latencyPenalty = 1.0
        if basePing > 0.1 then
            if basePing < 0.15 then
                latencyPenalty = 1.0 - (basePing - 0.1) * 2.0
            elseif basePing < 0.25 then
                latencyPenalty = 0.9 - (basePing - 0.15) * 2.0
            else
                latencyPenalty = mmax(0.7 - (basePing - 0.25) * 1.5, 0.5)
            end
        end

        local predTime = basePing * adaptiveFactor * latencyPenalty
            * Settings.PredictionFactor

        -- ── Kalman extrapolation (full jerk-model Taylor series) ──────────────
        local predictedRootPos = Settings.Prediction
            and kalmanExtrapolate(predTime)
            or  rootPos

        -- ── Camera compensation ───────────────────────────────────────────────
        local camCompensation = ZERO3
        if Settings.Prediction then
            local camSpeed = camVel.Magnitude
            if camSpeed > 2.0 then
                camCompensation = camVel * predTime * 0.65
            end
        end

        -- ── Final aim position ────────────────────────────────────────────────
        local aimPos = predictedRootPos + partOffset + camCompensation

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
                aimPos = aimPos:Lerp(targetPart.Position, 0.6)
            elseif hitChar ~= targetPlayer.Character then
                aimPos = aimPos:Lerp(targetPart.Position, 0.85)
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
        springForce = springForce * (1 + (mrand() - 0.5) * 0.06)

        Spr.vel = Spr.vel + springForce * safeDt
        Spr.pos = Spr.pos + Spr.vel    * safeDt

        Camera.CFrame = CFrame.new(camPos, Spr.pos)
    end)
end

-- ============================================================
-- [12b] ESP STEP  (independent of aimbot — own connection)
-- ============================================================

-- Pre-baked sign table for the 8 corners of an axis-aligned bounding box.
-- Stored as flat scalar pairs rather than sub-tables to avoid two levels of
-- table indexing per corner in the inner loop.
local CORNER_SIGNS = {
     1, 1, 1,    1, 1,-1,    1,-1, 1,    1,-1,-1,
    -1, 1, 1,   -1, 1,-1,   -1,-1, 1,   -1,-1,-1,
}

local espConnection = nil

stopEsp = function()
    if espConnection then
        espConnection:Disconnect()
        espConnection = nil
    end
    for _, entry in ipairs(espRenderList) do
        espHidePlayer(entry.pl)
    end
    for _, box   in pairs(espBoxPool)       do box.Visible   = false end
    for _, charm in pairs(espCharmPool)     do charm.Visible = false end
    for _, hl    in pairs(espHighlightPool) do hl.Enabled    = false end
    for _, t     in pairs(espTextPool) do
        t.name.Visible = false ; t.info.Visible = false
    end
end

startEsp = function()
    if espConnection then return end

    espConnection = RunService.RenderStepped:Connect(function()

        local playerEspOn = Settings.PlayerEspEnabled
        local espType     = Settings.EspType
        local textOn      = Settings.EspTextEnabled
        local teamCheck   = Settings.EspTeamCheck
        local teamColors  = Settings.EspTeamColors
        local myTeam      = LocalPlayer.Team
        local camCF       = Camera.CFrame
        local camPos      = camCF.Position

        if not playerEspOn then
            for _, entry in ipairs(espRenderList) do
                espHidePlayer(entry.pl)
            end
            return
        end

        for i = 1, #espRenderList do
            local entry = espRenderList[i]
            local pl    = entry.pl
            local cc    = entry.cc

            -- Guard: if already hidden and team-skipped, avoid redundant
            -- Drawing property writes by tracking dirty state in cc.espHidden.
            if teamCheck and myTeam and pl.Team == myTeam then
                if not cc.espHidden then
                    espHidePlayer(pl)
                    cc.espHidden = true
                end
                continue
            end
            cc.espHidden = false

            local root = cc.root
            if not root then continue end

            local rsp         = Camera:WorldToViewportPoint(root.Position)
            local rootVisible = rsp.Z > 0

            local drawColor = (teamColors and pl.Team)
                and pl.Team.TeamColor.Color
                or  ESP_COLOR_DEFAULT

            if espType == "Box" then
                if rootVisible then
                    -- Use cc.bodyParts (cached at character spawn, kept in sync via
                    -- ChildAdded/ChildRemoved) instead of calling GetChildren() per frame.
                    -- GetChildren() allocates a new Lua table on every call; caching
                    -- eliminates that allocation entirely for the ESP hot path.
                    local bodyParts = cc.bodyParts
                    local minSX, minSY =  mhuge,  mhuge
                    local maxSX, maxSY = -mhuge, -mhuge
                    local frontCount   = 0

                    for _, part in ipairs(bodyParts) do
                        local cf   = part.CFrame
                        local size = part.Size
                        local hx   = size.X * 0.5
                        local hy   = size.Y * 0.5
                        local hz   = size.Z * 0.5

                        -- Precompute the CFrame's rotation columns as scalars.
                        -- This lets us compute each corner's world position using
                        -- pure scalar arithmetic, avoiding cf:PointToWorldSpace()
                        -- which would create an intermediate Vector3 per corner.
                        -- We still need one Vector3.new per corner for
                        -- WorldToViewportPoint, but the intermediate allocation
                        -- from PointToWorldSpace is eliminated.
                        local px = cf.X;  local py = cf.Y;  local pz = cf.Z
                        local rx = cf.XVector.X; local ry = cf.XVector.Y; local rz = cf.XVector.Z
                        local ux = cf.YVector.X; local uy = cf.YVector.Y; local uz = cf.YVector.Z
                        local lx = cf.ZVector.X; local ly = cf.ZVector.Y; local lz = cf.ZVector.Z

                        local cs = CORNER_SIGNS
                        for ci = 1, 24, 3 do
                            local sx = cs[ci] * hx
                            local sy = cs[ci+1] * hy
                            local sz = cs[ci+2] * hz
                            local sp = Camera:WorldToViewportPoint(Vector3.new(
                                px + rx*sx + ux*sy + lx*sz,
                                py + ry*sx + uy*sy + ly*sz,
                                pz + rz*sx + uz*sy + lz*sz
                            ))
                            if sp.Z > 0 then
                                frontCount = frontCount + 1
                                if sp.X < minSX then minSX = sp.X end
                                if sp.X > maxSX then maxSX = sp.X end
                                if sp.Y < minSY then minSY = sp.Y end
                                if sp.Y > maxSY then maxSY = sp.Y end
                            end
                        end
                    end

                    if frontCount > 0 and maxSY > minSY then
                        local box = getEspBox(pl)
                        box.Size     = newV2(maxSX - minSX, maxSY - minSY)
                        box.Position = newV2(minSX, minSY)
                        box.Color    = drawColor
                        box.Visible  = true
                    else
                        if espBoxPool[pl] then espBoxPool[pl].Visible = false end
                    end
                else
                    if espBoxPool[pl] then espBoxPool[pl].Visible = false end
                end
                if espCharmPool[pl]     then espCharmPool[pl].Visible     = false end
                if espHighlightPool[pl] then espHighlightPool[pl].Enabled = false end

            elseif espType == "Circle/Mark" then
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

            local head = cc.head
            if textOn and head then
                -- cc.headHalfY is precomputed at character spawn to avoid reading
                -- head.Size.Y every frame per player.
                local headTop = head.Position + Vector3.new(0, cc.headHalfY, 0)
                local sp, onScreen = Camera:WorldToViewportPoint(headTop)

                if onScreen and sp.Z > 0 then
                    local t   = getEspText(pl)
                    local txt = cc.txt

                    t.name.Position = newV2(sp.X, sp.Y - 22)
                    t.info.Position = newV2(sp.X, sp.Y - 11)
                    t.name.Visible  = true
                    t.info.Visible  = true

                    local dist = mfloor((root.Position - camPos).Magnitude + 0.5)
                    if dist ~= txt.lastDist or txt.colorDirty then
                        txt.lastDist   = dist
                        txt.colorDirty = false
                        t.info.Text    = txt.hpStr .. "  •  " .. dist .. "m"
                        t.info.Color   = newC3(txt.r, txt.g, 0)
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
    end)
end

ScreenGui.Destroying:Connect(stopAimbot)
ScreenGui.Destroying:Connect(stopEsp)

-- ============================================================
-- [13] BOOT
-- ============================================================
applySettingsToUI()
