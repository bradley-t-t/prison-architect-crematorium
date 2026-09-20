-- Crematorium: the mod's world script.
--
-- A machine spawns two morgue slabs inside itself and hides them, and those
-- slabs have to go when the machine that owns them is dismantled or moved
-- away. A slab cannot notice that without a script of its own, and a script on
-- the morgue slab means every slab in the prison runs one, because scripting
-- is switched on per kind of object and not per object. The game rebuilds the
-- whole script API into Lua on every one of those calls, so a prison with a
-- dozen slabs pays for a dozen checks a tick to watch the two that matter.
--
-- So the machines name the slabs they spawn and this script sweeps them: one
-- call a tick for the whole prison, however many slabs are standing.
--
-- The game finds an object by name one at a time and gives no way to walk a
-- list, so the sweep drains one name into the other and drains it back on the
-- next pass. Which name currently holds the slabs alternates, and both are
-- read every pass, so a sweep that is cut short leaves nothing stranded.

local MARK_A      = "CrematoriumIntake"
local MARK_B      = "CrematoriumIntake2"
local MACHINES    = { "CrematoriumFurnace", "VaporizerPod" }
local CHECK_EVERY = 10    -- seconds between sweeps
local REACH       = 2     -- tiles; a machine this close still owns the slab
local MAX_SLABS   = 64    -- slabs handled in one sweep; the rest wait for the next

local timer = 0

-- A slab is owned while any machine still stands within reach of it. This is
-- the whole test: a slab the player placed is never named and never reaches
-- this script, so nothing the player built can be swept away by it.
local function owned(slab)
    for _, typ in ipairs(MACHINES) do
        if next(Object.GetNearbyObjects(slab, typ, REACH) or {}) ~= nil then
            return true
        end
    end
    return false
end

-- Moves every slab called `from` over to `to`, deleting the orphans on the
-- way. Returns how many it moved.
local function drain(from, to)
    local moved = 0
    for _ = 1, MAX_SLABS do
        local slab = Game.GetObject(from)
        if slab == nil then
            break
        end
        -- renamed first, so a slab that survives cannot be picked up twice
        -- and spin this loop
        Object.SetProperty(slab, "Name", to)
        moved = moved + 1
        if slab.Hidden == true and not owned(slab) then
            slab.Delete()
        end
    end
    return moved
end

function Init()
end

function Update(timePassed)
    timer = timer + (tonumber(timePassed) or 0)
    if timer < CHECK_EVERY then
        return
    end
    timer = 0
    -- Both directions every pass. A machine names a new slab MARK_A whichever
    -- way the last sweep ran, so both names can hold slabs at any time.
    drain(MARK_A, MARK_B)
    drain(MARK_B, MARK_A)
end
