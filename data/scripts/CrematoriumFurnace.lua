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
-- The name put on a spawned slab, which data/world.lua sweeps by.
local INTAKE_MARK     = "CrematoriumIntake"
-- Where the hidden slabs go, relative to the centre, on the tile grid. A
-- slab's sprite reaches two tiles up from its position, so they sit on the
-- bottom row of the footprint to stay under the machine's body. The
-- footprint is 3 wide and 2 tall facing north or south, 2 wide and 3 tall
-- facing east or west.
local INTAKE_ACROSS   = { { x = -1, y = 1 }, { x = 1, y = 1 } }
local INTAKE_ALONG    = { { x = -0.5, y = 1.5 }, { x = 0.5, y = 1.5 } }
local ON_SPOT         = 0.3   -- tiles; a slab this close to an intake spot stands on it
-- The machines that keep hidden slabs, and how far from one of its own spots
-- a machine can stand.
local MACHINE_KINDS   = { "CrematoriumFurnace", "VaporizerPod" }
local NEIGHBOUR_REACH = 2
local MORGUE_RADIUS   = 25    -- tiles; slabs this close are fed to the intake
local RELEASE_TIMEOUT = 600   -- seconds a released body waits for a guard
local ADOPT_EVERY     = 30    -- seconds between looks for bodies no slot names
local ADOPT_KINDS     = 5     -- kinds besides prisoners searched on each of those looks
local ON_SLAB         = 2     -- tiles; a body resting on a slab is this close to it
local IN_MACHINE      = 2.5   -- tiles; a body inside the machine is this close to its centre
local IN_FLIGHT_FOR   = 120   -- seconds a released body may be off its slab before it is forgotten
local SLABS_EVERY     = 60    -- seconds the list of slabs is kept before it is looked for again

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
local slabCache  = nil  -- { intake, far }: the slabs last found, kept between sweeps
local slabsAge   = SLABS_EVERY

function Create()
    Set("Phase", "Idle")
    Set("Cremated", 0)
    this.SubType = 0
    if EnsureIntake(Slabs()) then slabCache = nil end
    UpdateTooltip()
end

function Update(timePassed)
    clock = clock + timePassed
    checkTimer = checkTimer + timePassed
    sweepTimer = sweepTimer + timePassed
    slabsAge = slabsAge + timePassed

    -- A sweep searches the map for the bodies it is tracking, and that search
    -- hands back everyone of a body's kind within reach, the living too. A
    -- machine with a body in it has nothing to choose until it is done, so
    -- while it burns or cools it sweeps a third as often.
    local due = SWEEP_EVERY
    if busy then due = SWEEP_EVERY * BUSY_SWEEPS end
    if sweepTimer >= due then
        sweepTimer = 0
        local ok, err = safe(Sweep)
        if not ok then
            Set("LastError", tostring(err))
            slabCache = nil     -- a slab taken down since the last look; look again
        end
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
        slabCache = nil
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
-- names, and for each one named by a slot the place it should be lying: the
-- machine itself, or the slab. Those are the only places the index is ever
-- looked up from.
function WantedBodies(intake, far)
    local wanted, where = {}, {}
    for id in pairs(released) do wanted[id] = true end
    for n = 0, NUM_SLOTS - 1 do
        local id = Get("Slot" .. n .. ".i")
        if id ~= nil and id > -1 then
            wanted[id] = true
            where[id] = { this, IN_MACHINE }
        end
    end
    for _, slabs in ipairs({ intake, far }) do
        for _, slab in ipairs(slabs) do
            local id = Get(slab, "Slot0.i") or -1
            if id > -1 then
                wanted[id] = true
                if where[id] == nil then where[id] = { slab, ON_SLAB } end
            end
        end
    end
    return wanted, where
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
    -- A released body still on its way takes up a place at the intake whether
    -- or not this sweep saw it: one in a guard's arms is not looked for.
    for id in pairs(released) do
        local body = bodies[id]
        if not (body and OnIntake(body, intake)) then capacity = capacity - 1 end
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
--
-- Machines built side by side share an edge, and the row a neighbour keeps
-- its slabs on can lie along it, inside what reads as this machine's
-- footprint. A slab on a spot a neighbour keeps one on is the neighbour's.
-- Were it counted here, each machine would take the other's slabs down on
-- every sweep and the other would build them again, and anything on its way
-- to one of them would find it gone.
--
-- The list is kept between sweeps, and looked for again as soon as a slab in
-- it has been taken down.
function Slabs()
    if slabCache ~= nil and slabsAge < SLABS_EVERY and AllStanding(slabCache) then
        return slabCache[1], slabCache[2]
    end
    local halfW, halfH = HalfFootprint()
    local intake, far = {}, {}
    for slab, dist in pairs(Find("MorgueSlab", MORGUE_RADIUS)) do
        local x, y = tonumber(slab.Pos.x), tonumber(slab.Pos.y)
        if x ~= nil and y ~= nil then
            local dx = math.abs(x - this.Pos.x)
            local dy = math.abs(y - this.Pos.y)
            if dx <= halfW + 0.1 and dy <= halfH + 0.3 then
                if OnSpot(this, x, y) or not NeighbourKeeps(slab, x, y) then
                    table.insert(intake, { slab = slab, dist = dist })
                end
            elseif slab.Hidden ~= true then
                table.insert(far, { slab = slab, dist = dist })
            end
        end
    end
    slabCache = { Sorted(intake), Sorted(far) }
    slabsAge = 0
    return slabCache[1], slabCache[2]
end

-- Whether every slab in the kept list is still standing. One that has been
-- taken down reads as standing nowhere.
function AllStanding(cache)
    for _, slabs in ipairs(cache) do
        for _, slab in ipairs(slabs) do
            if tonumber(slab.Pos.x) == nil then return false end
        end
    end
    return true
end

-- Whether (x, y) is one of the spots a machine keeps its own slabs on.
function OnSpot(machine, x, y)
    local mx, my = tonumber(machine.Pos.x), tonumber(machine.Pos.y)
    if mx == nil or my == nil then return false end
    for _, offset in ipairs(OffsetsFor(machine)) do
        if math.abs(x - (mx + offset.x)) <= ON_SPOT and math.abs(y - (my + offset.y)) <= ON_SPOT then
            return true
        end
    end
    return false
end

-- Whether another machine keeps a slab where this one stands. Only a slab in
-- this machine's footprint and off its own spots is asked about, which is
-- none at all unless machines stand side by side.
function NeighbourKeeps(slab, x, y)
    for _, kind in ipairs(MACHINE_KINDS) do
        for machine in pairs(Find(slab, kind, NEIGHBOUR_REACH) or {}) do
            local id = machine.Id
            if id and id.i ~= this.Id.i and OnSpot(machine, x, y) then return true end
        end
    end
    return false
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
            Set(slab, "Name", INTAKE_MARK)
            kept = kept + 1
        end
    end
    for n = kept + 1, INTAKE_COUNT do
        local offset = offsets[n]
        local slab = Object.Spawn("MorgueSlab", this.Pos.x + offset.x, this.Pos.y + offset.y)
        if slab then
            Set(slab, "Hidden", true)
            -- The name is how the mod's world script finds this slab again to
            -- remove it once this machine is gone. A slab the player placed is
            -- never named, and so is never touched.
            Set(slab, "Name", INTAKE_MARK)
        end
        changed = true
    end
    return changed
end

-- A machine turned east or west has its long side running north-south.
function OffsetsFor(machine)
    local orientation = machine.Or
    if orientation and orientation.x and math.abs(orientation.x) > 0.5 then
        return INTAKE_ALONG
    end
    return INTAKE_ACROSS
end

function IntakeOffsets()
    return OffsetsFor(this)
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
-- so every ADOPT_EVERY the machine looks on each slab that names nobody for a
-- body lying there and writes it back into the slab's slot. The look is made
-- on the slab and nowhere else, so it hands back whoever is on the slab rather
-- than everyone in the morgue. Nearly every body is a prisoner, so prisoners
-- are looked for on every round and the other kinds a few at a time.
--
-- A slab holds only the dead by rights, and anybody alive it holds cannot
-- move until something lets go, so the look lets up whoever alive it finds
-- held down there.
function Adopt(intake, far)
    local kinds = { ENTITY_TYPES[1] }
    for _ = 1, ADOPT_KINDS do
        adoptNext = adoptNext % #ENTITY_TYPES + 1
        if adoptNext ~= 1 then table.insert(kinds, ENTITY_TYPES[adoptNext]) end
    end
    for _, slabs in ipairs({ intake, far }) do
        for _, slab in ipairs(slabs) do
            if (Get(slab, "Slot0.i") or -1) == -1 then
                AdoptOnto(slab, kinds)
            end
        end
    end
end

function AdoptOnto(slab, kinds)
    for _, typ in ipairs(kinds) do
        for entity in pairs(Find(slab, typ, ON_SLAB) or {}) do
            local id = entity.Id
            if id and IsLoaded(entity) and CarrierOf(entity) == slab.Id.i then
                if not IsCorpse(entity) then
                    Set(entity, "Loaded", false)
                    Set(entity, "CarrierId.i", -1)
                    Set(entity, "CarrierId.u", -1)
                elseif id.u ~= nil then
                    Set(slab, "Slot0.i", id.i)
                    Set(slab, "Slot0.u", id.u)
                    kindOf[id.i] = typ
                    return
                end
            end
        end
    end
end

-- The wanted bodies, keyed by id, and a function that says whether a wanted
-- body is gone.
--
-- A search hands back a full script record of everything it finds, which the
-- game builds afresh every time, and a search of the morgue or wider hands
-- back most of the prison with it. So each body is looked for where its slot
-- says it lies, on its slab or in the machine, and only there: a search a
-- couple of tiles across that hands back the body and whoever is standing on
-- it. The kind each body was found under is remembered, and a body whose kind
-- is not yet known is looked for as each kind in turn, still only where it
-- should be lying.
--
-- A body that was looked for where it should be and was not there is gone.
-- A released body that no slot names any more is in a guard's arms, and is not
-- looked for at all: it turns up again on whichever slab the guard puts it
-- on, and it is forgotten once it has been off its slab for IN_FLIGHT_FOR.
function IndexBodies(wanted, where)
    local bodies = {}
    if next(wanted) == nil then
        kindOf = {}
        return bodies, function() return false end
    end
    for id in pairs(kindOf) do
        if not wanted[id] then kindOf[id] = nil end
    end
    local looked = {}
    local function lookAt(place, typ)
        for entity in pairs(Find(place[1], typ, place[2]) or {}) do
            if IsCorpse(entity) then
                local id = entity.Id.i
                bodies[id] = entity
                if wanted[id] then kindOf[id] = typ end
            end
        end
    end
    for id, place in pairs(where) do
        if not bodies[id] then
            local known = kindOf[id]
            if known then lookAt(place, known) end
            if not bodies[id] then
                for _, typ in ipairs(ENTITY_TYPES) do
                    if typ ~= known then
                        lookAt(place, typ)
                        if bodies[id] then break end
                    end
                end
            end
            looked[id] = true
        end
    end
    local function gone(id)
        if bodies[id] then return false end
        if looked[id] then return true end
        local since = released[id]
        return since ~= nil and clock - since > IN_FLIGHT_FOR
    end
    return bodies, gone
end

-- A body is a person whose Damage has reached 1. That is the only test: the
-- game hands a script a DeathType for the living as well as the dead, so
-- reading one says nothing about whether anybody has died, and a machine
-- that believed it would burn whoever it was handed.
function IsCorpse(entity)
    local damage = tonumber(entity.Damage)
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

-- The game hands a script every object a search finds as a global named for
-- the object's type and id, and never takes one back, so a script that
-- searches holds on to everyone it has ever found. Every FORGET_EVERY seconds
-- those globals are cleared, and Lua's own collector frees what they held.
-- Reading a property of an object goes through its global, so the slabs this
-- machine keeps between sweeps keep theirs.
local FORGET_EVERY = 20
local forgetTimer = math.random() * FORGET_EVERY
local runUpdate = Update
function Update(timePassed)
    forgetTimer = forgetTimer + timePassed
    if forgetTimer >= FORGET_EVERY then
        forgetTimer = 0
        if _G ~= nil then
            for name, value in pairs(_G) do
                if type(value) == "table" and type(name) == "string" and name:find("i%-?%d+u%-?%d+$")
                    and not name:find("^MorgueSlab") then
                    _G[name] = nil
                end
            end
        end
    end
    return runUpdate(timePassed)
end
