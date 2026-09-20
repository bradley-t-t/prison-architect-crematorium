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

-- Every scripted object is a Lua state of its own, and what a script drops
-- stays in memory until a collection runs. A full one every GC_EVERY seconds
-- keeps a long session from piling it up. The state is small, so it is cheap.
local GC_EVERY = 20
local gcTimer = math.random() * GC_EVERY
local runUpdate = Update
function Update(timePassed)
    gcTimer = gcTimer + timePassed
    if gcTimer >= GC_EVERY then
        gcTimer = 0
        if collectgarbage then collectgarbage("collect") end
    end
    return runUpdate(timePassed)
end
