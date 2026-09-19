-- Crematorium furnace. VaporizerPod.lua is this file with the STYLE block
-- changed; keep the two in step.
--
-- The game carries any loose corpse to the nearest free morgue slab, and
-- nowhere else. The furnace builds on that: it spawns two morgue slabs inside
-- its own footprint, hidden under its sprite, so a guard carrying a body to
-- them walks it into the furnace mouth. It keeps those slabs free by
-- consuming one body per burn. Bodies resting on slabs farther away are
-- released one at a time, so a guard picks each one up and carries it over.
-- A released body nobody collects for a long while is consumed where it
-- lies so the pipeline never stalls.
--
-- Phases: Idle -> Burning -> CoolDown -> Idle. The phase and the cremation
-- count live on the object's blackboard so they survive a save.

-- STYLE
local NAME        = "CrematoriumFurnace"   -- object name; tooltip keys derive from it
local SMOKE_COUNT = 3                      -- smoke generators spawned at the chimney
-- END STYLE

local Get  = Object.GetProperty
local Set  = Object.SetProperty
local Find = Object.GetNearbyObjects
local safe = pcall or function(f, ...) return true, f(...) end

local NUM_SLOTS       = 8
local CHECK_INTERVAL  = 2     -- seconds between phase checks
local SWEEP_EVERY     = 8     -- seconds between morgue sweeps
local BUSY_SWEEPS     = 3     -- times as long between sweeps while a body is in the machine
local BURN_TIME       = 60    -- seconds the furnace burns per body
local COOL_TIME       = 15    -- seconds before the furnace takes the next body
local INTAKE_COUNT    = 2     -- hidden slabs per machine
-- Where the hidden slabs go, relative to the centre, on the tile grid. A
-- slab's sprite reaches two tiles up from its position, so they sit on the
-- bottom row of the footprint to stay under the machine's body. The
-- footprint is 3 wide and 2 tall facing north or south, 2 wide and 3 tall
-- facing east or west.
local INTAKE_ACROSS   = { { x = -1, y = 1 }, { x = 1, y = 1 } }
local INTAKE_ALONG    = { { x = -0.5, y = 1.5 }, { x = 0.5, y = 1.5 } }
local MORGUE_RADIUS   = 25    -- tiles; slabs this close are fed to the intake
local BODY_RADIUS     = 60    -- tiles; how far a carried body is tracked
local RELEASE_TIMEOUT = 600   -- seconds a released body waits for a guard
local ADOPT_EVERY     = 30    -- seconds between looks for bodies no slot names
local ADOPT_KINDS     = 5     -- kinds besides prisoners searched on each of those looks
local FULL_EVERY      = 30    -- seconds between searches of every kind of person

-- Every entity type a corpse can be. Dead people keep their living type, so
-- the only way to find a body is to search each type.
local ENTITY_TYPES = {
    "Prisoner", "Workman", "Guard", "ArmedGuard", "RiotGuard", "Sniper",
    "Doctor", "Orderly", "Paramedic", "Cook", "Gardener", "Janitor",
    "DogHandler", "Dog", "Warden", "Chief", "Foreman", "Psychologist",
    "Psychiatrist", "Accountant", "Lawyer", "Teacher", "SpiritualLeader",
    "Fireman", "Soldier", "Visitor", "Actor", "Avatar",
    "SystemAdministrator", "ComputerNerd", "SimulationOfficeManager",
    "YogaMaster", "ExecutionWitness", "MetroGuard", "TruckDriver",
    "ParoleOfficer", "ParoleLawyer", "AppealsLawyer", "AppealsMagistrate",
    "TeacherClone", "SpiritualLeaderClone", "ParoleOfficerClone",
    "ParoleLawyerClone", "AppealsLawyerClone", "AppealsMagistrateClone",
    "ForestryWorker", "Barber", "BarberChief", "GardenWorker",
    "GreenhouseWorker", "PlantationWorker", "Tailor", "CarMechanic",
    "CarMechanicHelper", "LotteryOfficial", "BasketballTrainer",
}

local clock      = 0
local busy       = false
local checkTimer = math.random() * CHECK_INTERVAL   -- a random start, so machines do not all work on one tick
local sweepTimer = math.random() * SWEEP_EVERY
local phaseTimer = 0
local released   = {}   -- body id -> clock time it was released from its slab
local lastAdopt  = -ADOPT_EVERY
local adoptNext  = 1
local kindOf     = {}   -- body id -> the kind it was found under
local lastFull   = -FULL_EVERY

function Create()
    Set("Phase", "Idle")
    Set("Cremated", 0)
    this.SubType = 0
    EnsureIntake(Slabs())
    UpdateTooltip()
end

function Update(timePassed)
    clock = clock + timePassed
    checkTimer = checkTimer + timePassed
    sweepTimer = sweepTimer + timePassed

    -- A sweep searches the map for the bodies it is tracking, and that search
    -- hands back everyone of a body's kind within reach, the living too. A
    -- machine with a body in it has nothing to choose until it is done, so
    -- while it burns or cools it sweeps a third as often.
    local due = SWEEP_EVERY
    if busy then due = SWEEP_EVERY * BUSY_SWEEPS end
    if sweepTimer >= due then
        sweepTimer = 0
        local ok, err = safe(Sweep)
        if not ok then Set("LastError", tostring(err)) end
    end

    if checkTimer < CHECK_INTERVAL then return end
    local dt = checkTimer
    checkTimer = 0
    phaseTimer = phaseTimer + dt

    local phase = Get("Phase") or "Idle"
    busy = phase ~= "Idle"
    if phase == "Burning" then
        if phaseTimer >= BURN_TIME then
            this.SubType = 0
            SetPhase("CoolDown")
        end
    elseif phase == "CoolDown" then
        if phaseTimer >= COOL_TIME then
            ClearSmoke()
            SetPhase("Idle")
        end
    end
    UpdateTooltip()
end

-------------------------------------------------------------------------------
-- The sweep
-------------------------------------------------------------------------------

function Sweep()
    local intake, far = Slabs()
    if EnsureIntake(intake) then
        intake, far = Slabs()
    end
    if clock - lastAdopt >= ADOPT_EVERY then
        lastAdopt = clock
        Adopt(intake, far)
    end
    -- Indexing bodies is the dearest thing this script does, so it looks up
    -- only the bodies something names, and nothing at all when nothing does.
    local bodies, gone = IndexBodies(WantedBodies(intake, far))

    Reconcile(intake, bodies, gone)
    Reconcile(far, bodies, gone)

    if (Get("Phase") or "Idle") == "Idle" then
        local body = NextBody(intake, far, bodies, gone)
        if body then
            Consume(body, intake, far)
            Ignite()
        end
    end

    ReleaseForCarry(intake, far, bodies)
end

-- The ids of every body a slot on this machine, a slab or the release list
-- names. Those are the only places the index is ever looked up from.
function WantedBodies(intake, far)
    local wanted = {}
    for id in pairs(released) do wanted[id] = true end
    for n = 0, NUM_SLOTS - 1 do
        local id = Get("Slot" .. n .. ".i")
        if id ~= nil and id > -1 then wanted[id] = true end
    end
    for _, slabs in ipairs({ intake, far }) do
        for _, slab in ipairs(slabs) do
            local id = Get(slab, "Slot0.i") or -1
            if id > -1 then wanted[id] = true end
        end
    end
    return wanted
end

-- The body to burn next: one the game put into the furnace itself, else one
-- resting on an intake slab, else a released body no guard has collected,
-- else, when guards cannot be used, the nearest body in the morgue.
function NextBody(intake, far, bodies, gone)
    for n = 0, NUM_SLOTS - 1 do
        local id = Get("Slot" .. n .. ".i")
        if id ~= nil and id > -1 then
            if bodies[id] then
                ClearOwnSlot(n)
                return bodies[id]
            elseif gone(id) then
                ClearOwnSlot(n)
            end
        end
    end
    for _, slab in ipairs(intake) do
        local body = bodies[Get(slab, "Slot0.i") or -1]
        if body then return body end
    end
    for id, since in pairs(released) do
        local body = bodies[id]
        if body == nil then
            if gone(id) then released[id] = nil end
        elseif clock - since > RELEASE_TIMEOUT and not IsLoaded(body) then
            return body
        end
    end
    if next(released) == nil and not CarryPossible(far) then
        for _, slab in ipairs(far) do
            local body = bodies[Get(slab, "Slot0.i") or -1]
            if body then return body end
        end
    end
    return nil
end

-- A released body is carried to the nearest free slab. That is only the
-- intake while every other slab is taken, so releases wait for a full morgue.
function CarryPossible(far)
    for _, slab in ipairs(far) do
        if (Get(slab, "Slot0.i") or -1) == -1 then return false end
    end
    return true
end

function Consume(body, intake, far)
    local id = body.Id.i
    released[id] = nil
    for _, slab in ipairs(intake) do
        if Get(slab, "Slot0.i") == id then ClearSlab(slab) end
    end
    for _, slab in ipairs(far) do
        if Get(slab, "Slot0.i") == id then ClearSlab(slab) end
    end
    body.Delete()
    Set("Cremated", (Get("Cremated") or 0) + 1)
end

-- Let go of one body per free intake slab so a guard carries it over. The
-- far slab keeps its slot marked until the body is burned, so the guard is
-- not sent straight back to it.
function ReleaseForCarry(intake, far, bodies)
    if not CarryPossible(far) then return end
    local capacity = 0
    for _, slab in ipairs(intake) do
        if (Get(slab, "Slot0.i") or -1) == -1 then capacity = capacity + 1 end
    end
    for id in pairs(released) do
        local body = bodies[id]
        if body and not OnIntake(body, intake) then capacity = capacity - 1 end
    end
    for _, slab in ipairs(far) do
        if capacity <= 0 then return end
        local id = Get(slab, "Slot0.i") or -1
        local body = bodies[id]
        if body and released[id] == nil and IsLoaded(body) then
            Set(body, "Loaded", false)
            Set(body, "CarrierId.i", -1)
            Set(body, "CarrierId.u", -1)
            released[id] = clock
            capacity = capacity - 1
        end
    end
end

-- Free any slab whose body is gone, or whose body now rests on a different
-- slab because a guard carried it somewhere other than the intake. Such a
-- body is no longer in flight and may be released again later. A body the
-- index did not turn up is gone only when the index looked for it: a slot
-- freed under a body still lying there reads as a free slab to the game and
-- as an empty one to this machine, and the body is never burned.
function Reconcile(slabs, bodies, gone)
    for _, slab in ipairs(slabs) do
        local id = Get(slab, "Slot0.i") or -1
        if id > -1 then
            local body = bodies[id]
            if body == nil then
                if gone(id) then ClearSlab(slab) end
            elseif IsLoaded(body) and CarrierOf(body) ~= slab.Id.i then
                ClearSlab(slab)
                released[id] = nil
            end
        end
    end
end

function CarrierOf(body)
    local carrier = body.CarrierId
    if carrier == nil or carrier.i == nil then return -1 end
    return carrier.i
end

-------------------------------------------------------------------------------
-- Burning
-------------------------------------------------------------------------------

function SetPhase(phase)
    Set("Phase", phase)
    phaseTimer = 0
end

function Ignite()
    this.SubType = 1
    for _ = 1, SMOKE_COUNT do
        Object.Spawn("SmokeGenerator", this.Pos.x, this.Pos.y - 0.5)
    end
    SetPhase("Burning")
    UpdateTooltip()
end

function ClearSmoke()
    for smoke in pairs(Find("SmokeGenerator", 3)) do
        smoke.Delete()
    end
end

-------------------------------------------------------------------------------
-- Slabs and bodies
-------------------------------------------------------------------------------

-- Morgue slabs sorted nearest first, split into this machine's own hidden
-- slabs and the rest of the morgue. A slab counts as the machine's own only
-- when it sits within the footprint, which a placed slab never can, so a
-- neighbouring machine's slabs and the player's slabs are never touched.
-- Other machines' hidden slabs are left out of the morgue list entirely.
function Slabs()
    local halfW, halfH = HalfFootprint()
    local intake, far = {}, {}
    for slab, dist in pairs(Find("MorgueSlab", MORGUE_RADIUS)) do
        local dx = math.abs(slab.Pos.x - this.Pos.x)
        local dy = math.abs(slab.Pos.y - this.Pos.y)
        if dx <= halfW + 0.1 and dy <= halfH + 0.3 then
            table.insert(intake, { slab = slab, dist = dist })
        elseif slab.Hidden ~= true then
            table.insert(far, { slab = slab, dist = dist })
        end
    end
    return Sorted(intake), Sorted(far)
end

function Sorted(entries)
    table.sort(entries, function(a, b) return a.dist < b.dist end)
    local out = {}
    for _, entry in ipairs(entries) do table.insert(out, entry.slab) end
    return out
end

-- Half the footprint width and height for the current orientation.
function HalfFootprint()
    if IntakeOffsets() == INTAKE_ALONG then return 1.0, 1.5 end
    return 1.5, 1.0
end

-- Keep exactly the hidden slabs inside the footprint: mark them as hidden so
-- they clean themselves up, drop any that sit off their row, and spawn the
-- missing ones. Only spawned slabs can be inside the footprint, since placed
-- objects cannot overlap. Returns true when the set changed.
function EnsureIntake(intake)
    local offsets = IntakeOffsets()
    local changed = false
    local kept = 0
    for _, slab in ipairs(intake) do
        if math.abs(slab.Pos.y - (this.Pos.y + offsets[1].y)) > 0.3
           or kept >= INTAKE_COUNT then
            slab.Delete()
            changed = true
        else
            Set(slab, "Hidden", true)
            kept = kept + 1
        end
    end
    for n = kept + 1, INTAKE_COUNT do
        local offset = offsets[n]
        local slab = Object.Spawn("MorgueSlab", this.Pos.x + offset.x, this.Pos.y + offset.y)
        if slab then Set(slab, "Hidden", true) end
        changed = true
    end
    return changed
end

-- The machine turned east or west has its long side running north-south.
function IntakeOffsets()
    local orientation = this.Or
    if orientation and orientation.x and math.abs(orientation.x) > 0.5 then
        return INTAKE_ALONG
    end
    return INTAKE_ACROSS
end

function ClearSlab(slab)
    Set(slab, "Slot0.i", -1)
    Set(slab, "Slot0.u", -1)
end

function ClearOwnSlot(n)
    Set("Slot" .. n .. ".i", -1)
    Set("Slot" .. n .. ".u", -1)
end

-- A body lying on a slab is tied to it from the body's side, by its carrier.
-- Where the slab's own slot names nobody the body is invisible to every sweep,
-- so every ADOPT_EVERY the machine looks for bodies lying on its slabs and
-- writes each one back into its slab's slot. Nearly every body is a prisoner,
-- so prisoners are searched on every look and the other kinds a few at a time.
function Adopt(intake, far)
    local slabById = {}
    for _, slabs in ipairs({ intake, far }) do
        for _, slab in ipairs(slabs) do slabById[slab.Id.i] = slab end
    end
    if next(slabById) == nil then return end
    local kinds = { ENTITY_TYPES[1] }
    for _ = 1, ADOPT_KINDS do
        adoptNext = adoptNext % #ENTITY_TYPES + 1
        if adoptNext ~= 1 then table.insert(kinds, ENTITY_TYPES[adoptNext]) end
    end
    for _, typ in ipairs(kinds) do
        for entity in pairs(Find(typ, MORGUE_RADIUS + 2)) do
            if IsCorpse(entity) and IsLoaded(entity) then
                local slab = slabById[CarrierOf(entity)]
                local id = entity.Id
                if slab and id.u ~= nil and (Get(slab, "Slot0.i") or -1) == -1 then
                    Set(slab, "Slot0.i", id.i)
                    Set(slab, "Slot0.u", id.u)
                    kindOf[id.i] = typ
                end
            end
        end
    end
end

-- The wanted bodies that are within reach, keyed by id, and a function that
-- says whether a wanted body is gone. A body that did not turn up is gone
-- only when its kind was searched on this sweep; one whose kind is not yet
-- known, on a sweep with no full search, was simply not looked for.
--
-- A search hands back a full script record of everything it finds, which the
-- game builds afresh every time, so searching every kind of person in a busy
-- prison costs more than everything else the mod does put together. A body
-- never changes kind, so the kind each body was found under is remembered and
-- only those kinds are searched. The rest are searched, in turn and only
-- until every wanted body has turned up, when a body is new or has gone, and
-- no more often than FULL_EVERY, so a body that is named but nowhere to be
-- found cannot bring the whole search back on every sweep.
function IndexBodies(wanted)
    local bodies = {}
    if next(wanted) == nil then
        kindOf = {}
        return bodies, function() return false end
    end
    local searched = {}
    local full = false
    local function search(typ)
        searched[typ] = true
        for entity in pairs(Find(typ, BODY_RADIUS)) do
            if IsCorpse(entity) then
                local id = entity.Id.i
                bodies[id] = entity
                if wanted[id] then kindOf[id] = typ end
            end
        end
    end
    local function allFound()
        for id in pairs(wanted) do
            if not bodies[id] then return false end
        end
        return true
    end
    for id in pairs(kindOf) do
        if not wanted[id] then kindOf[id] = nil end
    end
    for id in pairs(wanted) do
        local typ = kindOf[id]
        if typ and not searched[typ] then search(typ) end
    end
    if not allFound() and clock - lastFull >= FULL_EVERY then
        lastFull = clock
        full = true
        for _, typ in ipairs(ENTITY_TYPES) do
            if not searched[typ] then search(typ) end
            if allFound() then break end
        end
    end
    local function gone(id)
        if bodies[id] then return false end
        local typ = kindOf[id]
        return full or (typ ~= nil and searched[typ] == true)
    end
    return bodies, gone
end

-- A dead entity keeps its type but gains a cause of death and full damage.
function IsCorpse(entity)
    local cause = entity.DeathType
    if cause ~= nil and cause ~= "" and cause ~= "None" then return true end
    local damage = entity.Damage
    return damage ~= nil and damage >= 1
end

function IsLoaded(body)
    return body.Loaded == true
end

function OnIntake(body, intake)
    local carrier = CarrierOf(body)
    for _, slab in ipairs(intake) do
        if slab.Id.i == carrier then return true end
    end
    return false
end

function UpdateTooltip()
    local phase = Get("Phase") or "Idle"
    local total = Get("Cremated") or 0
    if phase == "Burning" then
        this.Tooltip = { "tooltip_" .. NAME .. "_Burning", total, "A" }
    elseif phase == "CoolDown" then
        this.Tooltip = { "tooltip_" .. NAME .. "_CoolDown", total, "A" }
    else
        this.Tooltip = { "tooltip_" .. NAME .. "_Idle", total, "A" }
    end
end
