if SERVER then
    AddCSLuaFile()
end

TOOL.Category   = "Construction"
TOOL.Name       = "Maze Generator"
TOOL.Command    = nil
TOOL.ConfigName = ""

if CLIENT then
    language.Add("tool.maze.name", "Maze Generator")
    language.Add("tool.maze.desc", "Generate a maze")
    language.Add("tool.maze.0", "Left click: generate maze. Right click: remove last maze.")
end

-- Maze size in cells
TOOL.ClientConVar["width"]    = "8"
TOOL.ClientConVar["depth"]    = "8"
-- cellsize = distance between adjacent walls
TOOL.ClientConVar["cellsize"] = "190"

TOOL.LastBuilding = TOOL.LastBuilding or {}

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

    -- Undo & cleanup
    undo.Create("Maze Part")
        undo.AddEntity(ent)
        undo.SetPlayer(ply)
    undo.Finish()

    ply:AddCleanup("props", ent)

    return ent
end

-- Models & how many "cell distances" they cover
-- segments = how many wall positions this plate replaces
local wallDefs = {
    { segments = 8, model = "models/hunter/plates/plate4x32.mdl" },
    { segments = 6, model = "models/hunter/plates/plate4x24.mdl" },
    { segments = 4, model = "models/hunter/plates/plate4x16.mdl" },
    { segments = 2, model = "models/hunter/plates/plate4x8.mdl"  },
    { segments = 1, model = "models/hunter/plates/plate4x4.mdl"  }
}

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
        for _, def in ipairs(wallDefs) do
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
        for _, def in ipairs(wallDefs) do
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
local function GenerateMaze(ply, hitPos, hitNormal, width, depth, cellSize)
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
end

----------------------------------------------------------
-- TOOL actions
----------------------------------------------------------
function TOOL:LeftClick(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsValid(ply) or not trace.Hit then return false end

    local width    = math.Clamp(tonumber(self:GetClientInfo("width"))    or 8, 2, 32)
    local depth    = math.Clamp(tonumber(self:GetClientInfo("depth"))    or 8, 2, 32)
    local cellSize = math.Clamp(tonumber(self:GetClientInfo("cellsize")) or 240, 32, 1024)

    -- Remove previous maze
    if self.LastBuilding and istable(self.LastBuilding) then
        for _, ent in ipairs(self.LastBuilding) do
            if IsValid(ent) then ent:Remove() end
        end
    end

    GenerateMaze(ply, trace.HitPos, trace.HitNormal, width, depth, cellSize)

    -- We don't store parts individually now – they are all frozen props.
    self.LastBuilding = {}

    return true
end

function TOOL:RightClick(trace)
    if CLIENT then return true end

    if self.LastBuilding and istable(self.LastBuilding) then
        for _, ent in ipairs(self.LastBuilding) do
            if IsValid(ent) then ent:Remove() end
        end
        self.LastBuilding = {}
    end

    return true
end

----------------------------------------------------------
-- Control panel
----------------------------------------------------------
function TOOL.BuildCPanel(panel)
    panel:AddControl("Header", {
        Description =
            "Generate a maze made entirely from hunter plate4xN.\n" ..
            "cell size = distance between walls."
    })

    panel:NumSlider("Maze Width (cells)",  "maze_width",    2, 32, 0)
    panel:NumSlider("Maze Depth (cells)",  "maze_depth",    2, 32, 0)
    panel:NumSlider("Cell Size (units)",   "maze_cellsize", 100, 200, 0)
end
