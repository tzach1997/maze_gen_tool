if SERVER then
    AddCSLuaFile()
end

TOOL.Category   = "Construction"
TOOL.Name       = "Maze Generator"
TOOL.Command    = nil
TOOL.ConfigName = ""

if CLIENT then
    language.Add("tool.maze.name", "Maze Generator")
    language.Add("tool.maze.desc", "Generate a maze with selectable wall unit (2/4/8/16/32)")
    language.Add("tool.maze.0", "Left click: generate maze. Right click: remove last maze. Reload: rotate maze placement.")
end

TOOL.ClientConVar["unit"]     = "4"  -- allowed: 2,4,8,16,32
TOOL.ClientConVar["width"]    = "8"
TOOL.ClientConVar["depth"]    = "8"
TOOL.ClientConVar["material"] = ""   -- optional material to apply to spawned walls
TOOL.ClientConVar["floor"]    = "0"  -- spawn floor tiles
TOOL.ClientConVar["roof"]     = "0"  -- spawn roof tiles
TOOL.ClientConVar["rotation"] = "0"  -- rotation in 90° increments (0, 90, 180, 270)
TOOL.ClientConVar["preview"]  = "1"  -- PREVIEW: show outer outline before placing

-- cellsize = distance between adjacent walls (depends on unit)

TOOL.LastBuilding = TOOL.LastBuilding or {}
TOOL.Mazes = TOOL.Mazes or {} -- stack of generated mazes (each is a table of ents)
TOOL.Rotation = TOOL.Rotation or 0 -- current rotation in degrees (client-side)

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

        -- Store material as a duplicator entity modifier so advdupe/duplicator preserves it
        pcall(function()
            if duplicator and duplicator.RegisterEntityModifier then
                -- register a safe, tool-specific modifier that sets the material on paste
                duplicator.RegisterEntityModifier("maze_material", function(ply, e, data)
                    if IsValid(e) and data and data.mat then
                        e:SetMaterial(data.mat)
                    end
                end)
            end

            if duplicator and duplicator.StoreEntityModifier then
                duplicator.StoreEntityModifier(ent, "maze_material", { mat = currentWallMaterial })
            end
        end)
    end

    -- If we're currently generating a maze, register this entity in that maze's table
    if istable(currentMazeParts) then
        table.insert(currentMazeParts, ent)
    end

    return ent
end

-- We'll choose `wallDefs` and `cellSize` at runtime based on selected `unit`.
-- Definitions for the three supported units (2, 4, 32).
local wallDefsByUnit = {
    ["1"] = {
        defs = {
            { segments = 32, model = "models/hunter/plates/plate1x32.mdl" },
            { segments = 24, model = "models/hunter/plates/plate1x24.mdl" },
            { segments = 16,  model = "models/hunter/plates/plate1x16.mdl"  },
            { segments = 8,  model = "models/hunter/plates/plate1x8.mdl"  },
            { segments = 7,  model = "models/hunter/plates/plate1x7.mdl"  },
            { segments = 6, model = "models/hunter/plates/plate1x6.mdl" },
            { segments = 5,  model = "models/hunter/plates/plate1x5.mdl" },
            { segments = 4,  model = "models/hunter/plates/plate1x4.mdl"  },
            { segments = 3,  model = "models/hunter/plates/plate1x3.mdl"  },
            { segments = 2,  model = "models/hunter/plates/plate1x2.mdl"  },
            { segments = 1,  model = "models/hunter/plates/plate1x1.mdl"  }
        },
        cellSize = 47
    },
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

-- Full 2D plate lookup per unit.
-- plate{N}x{M} at unit U covers (N/U) cells wide x (M/U) cells tall.
-- Only plates where both dimensions divide evenly into cells are included.
-- Sorted by area (cw*ch) descending so the greedy packer always tries largest first.
local roofPlatesByUnit = {}
do
    local allPlates = {
        {1,1,"plate1x1"},{1,2,"plate1x2"},{1,3,"plate1x3"},{1,4,"plate1x4"},
        {1,5,"plate1x5"},{1,6,"plate1x6"},{1,7,"plate1x7"},{1,8,"plate1x8"},
        {1,16,"plate1x16"},{1,24,"plate1x24"},{1,32,"plate1x32"},
        {2,2,"plate2x2"},{2,4,"plate2x4"},{2,6,"plate2x6"},{2,8,"plate2x8"},
        {2,16,"plate2x16"},{2,24,"plate2x24"},{2,32,"plate2x32"},
        {4,4,"plate4x4"},{4,8,"plate4x8"},{4,16,"plate4x16"},{4,24,"plate4x24"},{4,32,"plate4x32"},
        {8,8,"plate8x8"},{8,16,"plate8x16"},{8,24,"plate8x24"},{8,32,"plate8x32"},
        {16,16,"plate16x16"},{16,32,"plate16x32"},
        {32,32,"plate32x32"},
    }
    for _, unitStr in ipairs({"1","2","4","8","16","32"}) do
        local U = tonumber(unitStr)
        local list = {}
        for _, p in ipairs(allPlates) do
            local N, M, name = p[1], p[2], p[3]
            local cw = N / U
            local ch = M / U
            if cw == math.floor(cw) and ch == math.floor(ch) and cw >= 1 and ch >= 1 then
                table.insert(list, {
                    cw    = cw,
                    ch    = ch,
                    model = "models/hunter/plates/" .. name .. ".mdl"
                })
            end
        end
        table.sort(list, function(a, b) return (a.cw * a.ch) > (b.cw * b.ch) end)
        roofPlatesByUnit[unitStr] = list
    end
end

-- Spawn optimized floor or roof using 2D greedy rectangle packing.
-- At each uncovered cell, measures free space right (freeW) and down (freeH),
-- then places the largest plate (by area) that fits in either orientation.
-- A fully open 8x8 maze at unit=2 becomes 1 prop (plate16x16) instead of 64.
local function SpawnFloorOrRoof(ply, basePos, baseAng, cellSize, width, depth, unit, isRoof)
    local right   = baseAng:Right()
    local forward = baseAng:Forward()
    local up      = baseAng:Up()

    local plates = roofPlatesByUnit[unit] or roofPlatesByUnit["4"]
    local heightOffset = isRoof and cellSize or 0

    local covered = {}
    for x = 1, width do covered[x] = {} end

    -- Rotated angle: 90° yaw so the plate's long axis aligns with Right
    local angRot = baseAng * 1

    for cy = 1, depth do
        local cx = 1
        while cx <= width do
            if covered[cx][cy] then
                cx = cx + 1
            else
                -- measure free cells right and down
                local freeW = 0
                while cx + freeW <= width  and not covered[cx + freeW][cy] do freeW = freeW + 1 end
                local freeH = 0
                while cy + freeH <= depth  and not covered[cx][cy + freeH] do freeH = freeH + 1 end

                -- pick largest plate fitting in freeW x freeH (normal or rotated)
                local chosen, tileCW, tileCH, useRot = nil, 1, 1, false
                for _, p in ipairs(plates) do
                    if p.cw <= freeW and p.ch <= freeH then
                        chosen, tileCW, tileCH, useRot = p, p.cw, p.ch, false
                        break
                    end
                    if p.ch <= freeW and p.cw <= freeH then
                        chosen, tileCW, tileCH, useRot = p, p.ch, p.cw, true
                        break
                    end
                end
                if not chosen then
                    chosen = plates[#plates]
                    tileCW, tileCH, useRot = 1, 1, false
                end

                -- mark covered
                for dy = cy, cy + tileCH - 1 do
                    for dx = cx, cx + tileCW - 1 do
                        covered[dx][dy] = true
                    end
                end

                -- spawn centred on the tile's footprint
                local centerX = ((cx - 1) + tileCW * 0.5) * cellSize
                local centerY = ((cy - 1) + tileCH * 0.5) * cellSize
                local offset  = right * centerX + forward * centerY + up * heightOffset
                SpawnProp(ply, chosen.model, basePos + offset, useRot and angRot or baseAng)

                cx = cx + tileCW
            end
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
local function GenerateMaze(ply, hitPos, hitNormal, width, depth, cellSize, unit, wantFloor, wantRoof, rotation)
    if not SERVER then return end

    local cells = GenerateMazeData(width, depth)

    local baseAng = Angle(0, 0, 0)
    baseAng:RotateAroundAxis(baseAng:Up(), rotation or 0)

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

    local rotation = tonumber(self:GetClientInfo("rotation")) or 0

    -- Create a new maze parts table and make SpawnProp append into it
    local newMaze = {}
    currentMazeParts = newMaze

    GenerateMaze(ply, trace.HitPos, trace.HitNormal, width, depth, cellSize, unit, wantFloor, wantRoof, rotation)

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

function TOOL:Reload(trace)

    -- Get current rotation from the tool's client convar
    local cur = self:GetClientNumber("rotation") or 0

    -- Snap to nearest 90 and then add 90
    local snapped = math.Round(cur / 90) * 90
    local newRot = snapped + 90

    -- Wrap around at 360
    if newRot >= 360 then
        newRot = newRot - 360
    end

    -- Update the client convar; this will affect generation & preview
    RunConsoleCommand("maze_rotation", tostring(newRot))

    return true
end




local previewColor = Color(0, 255, 0, 200)

    -- Draw a 3D rectangle outline representing the maze's outer walls
function TOOL:DrawHUD()
    if not tobool(self:GetClientInfo("preview")) then return end

    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local tr = ply:GetEyeTrace()
    if not tr.Hit or tr.HitSky then return end

    local width = math.Clamp(tonumber(self:GetClientInfo("width")) or 8, 2, 64)
    local depth = math.Clamp(tonumber(self:GetClientInfo("depth")) or 8, 2, 64)

    local unit = tostring(self:GetClientInfo("unit") or "4")
    local unitCfg = wallDefsByUnit[unit] or wallDefsByUnit["4"]
    local cellSize = unitCfg.cellSize or 190

    local rotation = tonumber(self:GetClientInfo("rotation")) or 0

    -- Base angle & position same as server
    local baseAng = Angle(0, 0, 0)
    baseAng:RotateAroundAxis(baseAng:Up(), rotation)

    local right   = baseAng:Right()
    local forward = baseAng:Forward()
    local up      = baseAng:Up()

    -- Slight lift to avoid Z-fighting
    local basePos = tr.HitPos + tr.HitNormal * 4 + up * 1

    local sizeX = width * cellSize
    local sizeY = depth * cellSize

    local p1 = basePos
    local p2 = basePos + right * sizeX
    local p3 = basePos + right * sizeX + forward * sizeY
    local p4 = basePos + forward * sizeY

    cam.Start3D(EyePos(), EyeAngles())
        render.SetColorMaterial()
        render.DrawLine(p1, p2, previewColor, true)
        render.DrawLine(p2, p3, previewColor, true)
        render.DrawLine(p3, p4, previewColor, true)
        render.DrawLine(p4, p1, previewColor, true)
    cam.End3D()
end

----------------------------------------------------------
-- Control panel
----------------------------------------------------------
function TOOL.BuildCPanel(panel)
    panel:AddControl("Header", {
        Description = "Generate a maze using unit size 2/4/32.\nSelect unit, then set width/depth (cells)."
    })

    local combo = panel:ComboBox("Wall Unit", "maze_unit")
    combo:AddChoice("0. 1 (plate1x)", "1")
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
    panel:NumSlider("Rotate", "maze_rotation", 0, 360, 0)

    -- PREVIEW toggle
    panel:CheckBox("Preview outer outline", "maze_preview")
end
