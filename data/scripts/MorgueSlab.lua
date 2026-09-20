-- Morgue slab. The definition is the game's own with scripting switched on,
-- so a slab that a Crematorium or Vaporizer spawned inside itself can notice
-- when that machine has been dismantled or moved away and remove itself.
-- Slabs the player placed are never marked Hidden and are left alone.

local Find = Object.GetNearbyObjects

local MACHINES    = { "CrematoriumFurnace", "VaporizerPod" }
local CHECK_EVERY = 10   -- seconds between checks
local REACH       = 2    -- tiles; a machine this close still owns the slab

local timer = math.random() * CHECK_EVERY   -- a random start, so slabs do not all check on one tick

function Create()
end

function Update(timePassed)
    timer = timer + timePassed
    if timer < CHECK_EVERY then return end
    timer = 0
    if this.Hidden ~= true then return end
    for _, typ in ipairs(MACHINES) do
        if next(Find(typ, REACH)) ~= nil then return end
    end
    this.Delete()
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
