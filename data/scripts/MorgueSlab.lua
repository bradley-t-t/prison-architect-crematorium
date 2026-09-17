-- Morgue slab. The definition is the game's own with scripting switched on,
-- so a slab that a Crematorium or Vaporizer spawned inside itself can notice
-- when that machine has been dismantled or moved away and remove itself.
-- Slabs the player placed are never marked Hidden and are left alone.

local Find = Object.GetNearbyObjects

local MACHINES    = { "CrematoriumFurnace", "VaporizerPod" }
local CHECK_EVERY = 10   -- seconds between checks
local REACH       = 2    -- tiles; a machine this close still owns the slab

local timer = 0

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
