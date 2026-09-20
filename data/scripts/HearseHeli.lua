-- Hearse. The definition is the game's own with scripting switched on, so a
-- hearse can notice that the prison disposes of its own dead and leave again
-- before anyone sees it. HearseBoat.lua and HearseHeli.lua are this file.
--
-- The game sends a hearse whenever a body is waiting, once an hour at most,
-- and it decides that by counting hearses already in the world, so there is
-- no way to stop it being sent. It can be sent away: the tick it appears at
-- the edge of the map, this script removes it if a Crematorium or Vaporizer
-- is standing anywhere in the prison. The next hour the game sends another,
-- which goes the same way.
--
-- A hearse already carrying bodies is left to finish its run, so nothing it
-- holds is ever lost, and with no machine in the prison the hearse is left
-- alone entirely and works as it always did.

local Find = Object.GetNearbyObjects
local Get  = Object.GetProperty

local MACHINES    = { "CrematoriumFurnace", "VaporizerPod" }
local REACH       = 2000  -- tiles; wider than any map, so the whole prison
local NUM_SLOTS   = 8
local CHECK_EVERY = 5     -- seconds between checks after the first

local timer = CHECK_EVERY

local function carrying()
    for n = 0, NUM_SLOTS - 1 do
        local id = Get("Slot" .. n .. ".i")
        if id ~= nil and id > -1 then return true end
    end
    return false
end

local function machineStanding()
    for _, typ in ipairs(MACHINES) do
        if next(Find(typ, REACH)) ~= nil then return true end
    end
    return false
end

function Create()
end

function Update(timePassed)
    timer = timer + timePassed
    if timer < CHECK_EVERY then return end
    timer = 0
    if carrying() then return end
    if machineStanding() then
        this.Delete()
    end
end

-- The game hands a script every object a search finds as a global named for
-- the object's type and id, and never takes one back, so a script that
-- searches holds on to everyone it has ever found. Every FORGET_EVERY seconds
-- those globals are cleared, and Lua's own collector frees what they held.
-- Objects the script still has in a local stay usable.
local FORGET_EVERY = 20
local forgetTimer = math.random() * FORGET_EVERY
local runUpdate = Update
function Update(timePassed)
    forgetTimer = forgetTimer + timePassed
    if forgetTimer >= FORGET_EVERY then
        forgetTimer = 0
        if _G ~= nil then
            for name, value in pairs(_G) do
                if type(value) == "table" and type(name) == "string" and name:find("i%-?%d+u%-?%d+$") then
                    _G[name] = nil
                end
            end
        end
    end
    return runUpdate(timePassed)
end
