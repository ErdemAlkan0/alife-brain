-- Pause while talking (user request, 2026-10-11): while the conversation window is open the
-- game stands still, so the dead and the fights wait while the player reads and types. It is
-- the game's own pause (speed 0, as its escape menu does); ALifeBrainMain keeps the bridge
-- running through OnTickEvenPaused, so replies still arrive. On close the speed the game had
-- comes back, unless the player changed it in between; a game that was already paused stays
-- paused. Single player only: a multiplayer game cannot be paused (this is what puts
-- multiplayer off for now). Mod Options "pauseWhileTalking", on by default.

ALifeBrain = ALifeBrain or {}

local Pause = {
    option = nil, -- PZAPI.ModOptions tick box (client)
    saved = nil, -- its value in ModOptions.ini, used when there is no tick box
    held = nil, -- { speed = n } while we hold the pause
}
ALifeBrain.Pause = Pause

-- Tests replace this with fakes: { speed = fn() -> n, setSpeed = fn(n), showMessage = fn(bool), multiplayer = fn() }.
Pause.override = nil

local function deps()
    if Pause.override ~= nil then return Pause.override end
    local function controls()
        local found = nil
        pcall(function() found = UIManager.getSpeedControls() end)
        return found
    end
    return {
        speed = function()
            local speed = nil
            pcall(function() speed = controls():getCurrentGameSpeed() end)
            if speed == nil then pcall(function() speed = getGameSpeed() end) end
            return tonumber(speed)
        end,
        setSpeed = function(speed)
            if not pcall(function() controls():SetCurrentGameSpeed(speed) end) then pcall(setGameSpeed, speed) end
        end,
        showMessage = function(show) pcall(setShowPausedMessage, show) end,
        multiplayer = function() return type(isClient) == "function" and isClient() == true end,
    }
end

function Pause.enabled()
    local option = Pause.option
    if option ~= nil and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        return not ok or value ~= false
    end
    return Pause.saved ~= false
end

-- Pauses the game for a conversation. Returns true when it paused it.
function Pause.hold()
    if Pause.held ~= nil or not Pause.enabled() then return false end
    local d = deps()
    if d.multiplayer() then return false end
    local speed = d.speed()
    if speed == nil or speed == 0 then return false end
    Pause.held = { speed = speed }
    d.setSpeed(0)
    d.showMessage(false) -- the window says so itself (Pause.active)
    return true
end

-- Ends our pause: the speed comes back if the game is still paused.
function Pause.release()
    local held = Pause.held
    if held == nil then return false end
    Pause.held = nil
    local d = deps()
    d.showMessage(true)
    if d.speed() == 0 then d.setSpeed(held.speed) end
    return true
end

-- True while our pause stands (the window shows it).
function Pause.active()
    return Pause.held ~= nil and deps().speed() == 0
end

-- True while the game is paused, by us or not (ALifeBrainMain: keep the bridge going).
function Pause.gamePaused()
    return deps().speed() == 0
end

return Pause
