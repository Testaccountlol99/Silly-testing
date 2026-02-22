-- ============================================================
--  AIMBOT  |  Loader
--  Fetches core, ui, and features from GitHub and runs them as
--  a single concatenated chunk so all locals flow through correctly.
-- ============================================================

local REPO = "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/"

-- Order matters: core declares shared locals, ui closes over them,
-- features assigns the aimbot/esp bodies that ui callbacks invoke.
local MODULES = {
    "core.lua",      -- math aliases, services, config, save/load, player cache, systems
    "ui.lua",        -- all GUI construction, component factories, widget wiring
    "features.lua",  -- drawing pools, aimbot loop, ESP loop, boot
}

-- Fetch each file and join into one string, then loadstring once so every
-- `local` defined in an earlier file is visible to all later ones.
-- Identical behaviour to running one large file.
local chunks = {}
for _, filename in ipairs(MODULES) do
    local ok, result = pcall(function()
        return game:HttpGet(REPO .. filename)
    end)
    if ok then
        chunks[#chunks + 1] = result
    else
        error("[Loader] Failed to fetch " .. filename .. ": " .. tostring(result))
    end
end

local fn, err = loadstring(table.concat(chunks))
if fn then
    fn()
else
    error("[Loader] Compile error: " .. tostring(err))
end
