if SERVER then
    AddCSLuaFile()
end

TOOL.Category   = "Construction"
TOOL.Name       = "Maze Generator (unified)"
TOOL.Command    = nil
TOOL.ConfigName = ""

if CLIENT then
    language.Add("tool.maze.name", "Maze Generator (unified)")
    language.Add("tool.maze.desc", "Generate a maze with selectable wall unit (2/4/32)")
    language.Add("tool.maze.0", "Left click: generate maze. Right click: remove last maze.")
end

TOOL.ClientConVar["unit"]     = "4" -- allowed: 2,4,8,16,32
TOOL.ClientConVar["width"]    = "8"
TOOL.ClientConVar["depth"]    = "8"
TOOL.ClientConVar["material"] = "" -- optional material to apply to spawned walls
TOOL.ClientConVar["floor"]    = "0" -- spawn floor tiles
TOOL.ClientConVar["roof"]     = "0" -- spawn roof tiles
-- cellsize = distance between adjacent walls (depends on unit)

TOOL.LastBuilding = TOOL.LastBuilding or {}
TOOL.Mazes = TOOL.Mazes or {} -- stack of generated mazes (each is a table of ents)

-- during generation this points to the table receiving spawned parts
local currentMazeParts = nil
-- during generation this holds the material string to apply to each spawned part
local currentWallMaterial = nil

----------------------------------------------------------
-- Helpers
----------------------------------------------------------
local function SpawnProp(ply, model, pos, ang)
    local ent = ents.Create("prop_physics")
    if not IsValid(ent) then return nil end

    ent:SetModel(model)
    ent:SetPos(pos)
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()

    -- Freeze prop
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(false)
        phys:Wake()
    end

    ent:SetMoveType(MOVETYPE_NONE)

    -- Undo & cleanup (leave per-prop undo as original)
    undo.Create("Maze Part")
        undo.AddEntity(ent)
        undo.SetPlayer(ply)
    undo.Finish()

    ply:AddCleanup("props", ent)

    -- Apply material if specified for this generation
    if isstring(currentWallMaterial) and currentWallMaterial ~= "" then
        pcall(function() ent:SetMaterial(currentWallMaterial) end)
    end

    -- If we're currently generating a maze, register this entity in that maze's table
    if istable(currentMazeParts) then
        table.insert(currentMazeParts, ent)
    end

    return ent
end

-- We'll choose `wallDefs` and `cellSize` at runtime based on selected `maze_unit`.
-- Definitions for the three supported units (2, 4, 32).
local wallDefsByUnit = {
    ["2"] = {
        defs = {
            { segments = 16, model = "models/hunter/plates/plate2x32.mdl" },
            { segments = 12, model = "models/hunter/plates/plate2x24.mdl" },
            { segments = 8,  model = "models/hunter/plates/plate2x16.mdl" },
            { segments = 4,  model = "models/hunter/plates/plate2x8.mdl"  },
            { segments = 3,  model = "models/hunter/plates/plate2x6.mdl"  },
            { segments = 2,  model = "models/hunter/plates/plate2x4.mdl"  },
            { segments = 1,  model = "models/hunter/plates/plate2x2.mdl"  }
        },
        cellSize = 95
    },
    ["4"] = {
        defs = {
            { segments = 8, model = "models/hunter/plates/plate4x32.mdl" },
            { segments = 6, model = "models/hunter/plates/plate4x24.mdl" },
            { segments = 4, model = "models/hunter/plates/plate4x16.mdl" },
            { segments = 2, model = "models/hunter/plates/plate4x8.mdl"  },
            { segments = 1, model = "models/hunter/plates/plate4x4.mdl"  }
        },
        cellSize = 190
    },
    ["8"] = {
        defs = {
            { segments = 4, model = "models/hunter/plates/plate8x32.mdl" },
            { segments = 3, model = "models/hunter/plates/plate8x24.mdl" },
            { segments = 2, model = "models/hunter/plates/plate8x16.mdl" },
            { segments = 1, model = "models/hunter/plates/plate8x8.mdl"  },
        }, 
        cellSize = 379
    },
    ["16"] = {
        defs = {
            { segments = 2, model = "models/hunter/plates/plate16x32.mdl" },
            { segments = 1, model = "models/hunter/plates/plate16x16.mdl" }
        },
        cellSize = 758
    },
    ["32"] = {
        defs = {
            { segments = 1, model = "models/hunter/plates/plate32x32.mdl" }
        },
        cellSize = 1517
    }
}

-- active definitions (will be swapped when the player picks a unit)
local currentWallDefs = wallDefsByUnit["4"].defs

-- floor/roof single-tile model per cell for each unit
local floorTileByUnit = {
    ["2"]  = "models/hunter/plates/plate2x2.mdl",
    ["4"]  = "models/hunter/plates/plate4x4.mdl",
    ["8"]  = "models/hunter/plates/plate8x8.mdl",
    ["16"] = "models/hunter/plates/plate16x16.mdl",
    ["32"] = "models/hunter/plates/plate32x32.mdl"
}

-- Spawn a flat tile for floor or roof per cell (one tile per cell)
local function SpawnFloorOrRoof(ply, basePos, baseAng, cellSize, width, depth, unit, isRoof)
    local right   = baseAng:Right()
    local forward = baseAng:Forward()
    local up      = baseAng:Up()

    local model = floorTileByUnit[unit] or "models/hunter/plates/plate4x4.mdl"

    -- roof placed one cell height above base; floor at base
    local heightOffset = isRoof and cellSize or 0

    for x = 1, width do
        for y = 1, depth do
            local centerX = (x - 0.5) * cellSize
            local centerY = (y - 0.5) * cellSize

            local offset = right * centerX + forward * centerY + up * heightOffset
            local pos = basePos + offset
            local ang = baseAng -- flat orientation

            SpawnProp(ply, model, pos, ang)
        end
    end
end

----------------------------------------------------------
-- Maze data (DFS backtracker)
----------------------------------------------------------
local function GenerateMazeData(w, h)
    local cells = {}

    for x = 1, w do
        cells[x] = {}
        for y = 1, h do
            cells[x][y] = {
                visited = false,
                walls = { n = true, e = true, s = true, w = true }
            }
        end
    end

    local dirs = {
        { dx = 0,  dy = -1, key = "n", opp = "s" },
        { dx = 1,  dy = 0,  key = "e", opp = "w" },
        { dx = 0,  dy = 1,  key = "s", opp = "n" },
        { dx = -1, dy = 0,  key = "w", opp = "e" }
    }

    local function shuffle(t)
        for i = #t, 2, -1 do
            local j = math.random(i)
            t[i], t[j] = t[j], t[i]
        end
    end

    local function carve(x, y)
        cells[x][y].visited = true

        local order = {1, 2, 3, 4}
        shuffle(order)

        for _, idx in ipairs(order) do
            local d  = dirs[idx]
            local nx = x + d.dx
            local ny = y + d.dy

            if nx >= 1 and nx <= w and ny >= 1 and ny <= h and not cells[nx][ny].visited then
                cells[x][y].walls[d.key]   = false
                cells[nx][ny].walls[d.opp] = false
                carve(nx, ny)
            end
        end
    end

    math.randomseed(os.time() + math.floor(CurTime()))
    carve(1, 1)

    return cells
end

----------------------------------------------------------
-- Wall unification helpers
----------------------------------------------------------

-- Spawn a horizontal (north/south) unified wall run
-- dirFactor = 1 for north, -1 for south (only affects yaw)
local function SpawnHorizontalRun(ply, basePos, baseAng, cellSize, wallHeightOffset, y, runStartX, runLen, dir)
    local right   = baseAng:Right()
    local forward = baseAng:Forward()
    local up      = baseAng:Up()

    local edgeY
    local yaw

    if dir == "n" then
        -- north edge at (y - 1)
        edgeY = (y - 1) * cellSize
        yaw = baseAng.y
    else
        -- south edge at y
        edgeY = (y) * cellSize
        yaw = baseAng.y + 180
    end

    local remaining = runLen
    local currentStart = runStartX

    while remaining > 0 do
        local chosen = nil
        for _, def in ipairs(currentWallDefs) do
            if def.segments <= remaining then
                chosen = def
                break
            end
        end

        if not chosen then break end

        local s = chosen.segments

        -- Center X: average of s walls starting at currentStart
        local centerIndex = (currentStart - 0.5) + (s - 1) / 2
        local centerX = centerIndex * cellSize

        local offset = right * centerX +
                       forward * edgeY +
                       up * wallHeightOffset

        local pos = basePos + offset
        local ang = Angle(0, yaw, 0)
        ang:RotateAroundAxis(ang:Right(), 90) -- stand up

        SpawnProp(ply, chosen.model, pos, ang)

        currentStart = currentStart + s
        remaining = remaining - s
    end
end

-- Spawn a vertical (west/east) unified wall run
-- dir = "w" or "e"
local function SpawnVerticalRun(ply, basePos, baseAng, cellSize, wallHeightOffset, x, runStartY, runLen, dir)
    local right   = baseAng:Right()
    local forward = baseAng:Forward()
    local up      = baseAng:Up()

    local edgeX
    local yaw

    if dir == "w" then
        -- west edge at (x - 1)
        edgeX = (x - 1) * cellSize
        yaw = baseAng.y + 90
    else
        -- east edge at x
        edgeX = (x) * cellSize
        yaw = baseAng.y - 90
    end

    local remaining = runLen
    local currentStart = runStartY

    while remaining > 0 do
        local chosen = nil
        for _, def in ipairs(currentWallDefs) do
            if def.segments <= remaining then
                chosen = def
                break
            end
        end

        if not chosen then break end

        local s = chosen.segments

        -- Center Y: average of s walls starting at currentStart
        local centerIndex = (currentStart - 0.5) + (s - 1) / 2
        local centerY = centerIndex * cellSize

        local offset = right * edgeX +
                       forward * centerY +
                       up * wallHeightOffset

        local pos = basePos + offset
        local ang = Angle(0, yaw, 0)
        ang:RotateAroundAxis(ang:Right(), 90) -- stand up

        SpawnProp(ply, chosen.model, pos, ang)

        currentStart = currentStart + s
        remaining = remaining - s
    end
end

----------------------------------------------------------
-- Core: Generate maze props
----------------------------------------------------------
local function GenerateMaze(ply, hitPos, hitNormal, width, depth, cellSize, unit, wantFloor, wantRoof)
    if not SERVER then return end

    local cells = GenerateMazeData(width, depth)

    local baseAng = hitNormal:Angle()
    baseAng:RotateAroundAxis(baseAng:Right(), -90)

    local wallHeightOffset = cellSize / 2
    local basePos = hitPos + hitNormal * 4

    --------------------------------------------------
    -- NORTH walls (row by row)
    --------------------------------------------------
    for y = 1, depth do
        local x = 1
        while x <= width do
            local cell = cells[x][y]
            if cell.walls.n then
                local startX = x
                local runLen = 1
                x = x + 1
                while x <= width and cells[x][y].walls.n do
                    runLen = runLen + 1
                    x = x + 1
                end

                SpawnHorizontalRun(ply, basePos, baseAng, cellSize, wallHeightOffset, y, startX, runLen, "n")
            else
                x = x + 1
            end
        end
    end

    --------------------------------------------------
    -- WEST walls (column by column)
    --------------------------------------------------
    for x = 1, width do
        local y = 1
        while y <= depth do
            local cell = cells[x][y]
            if cell.walls.w then
                local startY = y
                local runLen = 1
                y = y + 1
                while y <= depth and cells[x][y].walls.w do
                    runLen = runLen + 1
                    y = y + 1
                end

                SpawnVerticalRun(ply, basePos, baseAng, cellSize, wallHeightOffset, x, startY, runLen, "w")
            else
                y = y + 1
            end
        end
    end

    --------------------------------------------------
    -- SOUTH outer walls (bottom row only)
    --------------------------------------------------
    do
        local y = depth
        local x = 1
        while x <= width do
            local cell = cells[x][y]
            if cell.walls.s then
                local startX = x
                local runLen = 1
                x = x + 1
                while x <= width and cells[x][y].walls.s do
                    runLen = runLen + 1
                    x = x + 1
                end

                SpawnHorizontalRun(ply, basePos, baseAng, cellSize, wallHeightOffset, y, startX, runLen, "s")
            else
                x = x + 1
            end
        end
    end

    --------------------------------------------------
    -- EAST outer walls (right column only)
    --------------------------------------------------
    do
        local x = width
        local y = 1
        while y <= depth do
            local cell = cells[x][y]
            if cell.walls.e then
                local startY = y
                local runLen = 1
                y = y + 1
                while y <= depth and cells[x][y].walls.e do
                    runLen = runLen + 1
                    y = y + 1
                end

                SpawnVerticalRun(ply, basePos, baseAng, cellSize, wallHeightOffset, x, startY, runLen, "e")
            else
                y = y + 1
            end
        end
    end

    -- Optionally spawn floor and/or roof tiles (one tile per cell)
    if wantFloor then
        SpawnFloorOrRoof(ply, basePos, baseAng, cellSize, width, depth, unit, false)
    end

    if wantRoof then
        SpawnFloorOrRoof(ply, basePos, baseAng, cellSize, width, depth, unit, true)
    end
end

----------------------------------------------------------
-- TOOL actions
----------------------------------------------------------
function TOOL:LeftClick(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsValid(ply) or not trace.Hit then return false end

    local width = math.Clamp(tonumber(self:GetClientInfo("width")) or 8, 2, 64)
    local depth = math.Clamp(tonumber(self:GetClientInfo("depth")) or 8, 2, 64)

    local unit = tostring(self:GetClientInfo("unit") or "4")
    local unitCfg = wallDefsByUnit[unit] or wallDefsByUnit["4"]
    currentWallDefs = unitCfg.defs
    local cellSize = unitCfg.cellSize

    -- Read material from client settings and set for this generation
    currentWallMaterial = tostring(self:GetClientInfo("material") or "")

    local wantFloor = tonumber(self:GetClientInfo("floor")) ~= 0
    local wantRoof  = tonumber(self:GetClientInfo("roof"))  ~= 0

    -- Create a new maze parts table and make SpawnProp append into it
    local newMaze = {}
    currentMazeParts = newMaze

    GenerateMaze(ply, trace.HitPos, trace.HitNormal, width, depth, cellSize, unit, wantFloor, wantRoof)

    -- Generation finished; stop directing spawns into currentMazeParts
    currentMazeParts = nil
    currentWallMaterial = nil

    -- Push the new maze onto the stack
    self.Mazes = self.Mazes or {}
    table.insert(self.Mazes, newMaze)

    -- For compatibility with older code that uses LastBuilding, set it to the last maze
    self.LastBuilding = newMaze

    return true
end

function TOOL:RightClick(trace)
    if CLIENT then return true end

    -- Pop the last placed maze and remove its entities
    self.Mazes = self.Mazes or {}
    local last = table.remove(self.Mazes)
    if istable(last) then
        for _, ent in ipairs(last) do
            if IsValid(ent) then ent:Remove() end
        end
    end

    -- Update LastBuilding to point to the new last maze (or empty)
    self.LastBuilding = self.Mazes[#self.Mazes] or {}

    return true
end

----------------------------------------------------------
-- Control panel
----------------------------------------------------------
function TOOL.BuildCPanel(panel)
    panel:AddControl("Header", {
        Description = "Generate a maze using unit size 2/4/32.\nSelect unit, then set width/depth (cells)."
    })

    local combo = panel:ComboBox("Wall Unit", "maze_unit")
    combo:AddChoice("1. 2 (plate2x)", "2")
    combo:AddChoice("2. 4 (plate4x)", "4")
    combo:AddChoice("3. 8 (plate16x)", "8")
    combo:AddChoice("4. 16 (plate16x)", "16")
    combo:AddChoice("5. 32 (plate32x)", "32")

    panel:NumSlider("Maze Width (cells)",  "maze_width",    2, 64, 0)
    panel:NumSlider("Maze Depth (cells)",  "maze_depth",    2, 64, 0)
    panel:TextEntry("Wall Material (leave empty for none)", "maze_material")
    panel:CheckBox("Add Floor", "maze_floor")
    panel:CheckBox("Add Roof", "maze_roof")
end
