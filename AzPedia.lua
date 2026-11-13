local addonName = ...
local frame = CreateFrame("Frame")

-- Cache the latest Dijkstra results while the Flight Master window is open
local activeBestCosts = {}
local activeBestPrev = {}
local activeDirectCosts = {}
local currentHubName = nil

-- Initialize SavedVariables
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("TAXIMAP_OPENED")

local function FormatCopper(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then
        return string.format("%dg %ds %dc", g, s, c)
    elseif s > 0 then
        return string.format("%ds %dc", s, c)
    else
        return string.format("%dc", c)
    end
end

local function ReconstructPath(prev, target)
    local path = {}
    local curr = target
    while curr do
        table.insert(path, 1, curr)
        curr = prev[curr]
    end
    return table.concat(path, " -> ")
end

local function CacheTaxiRoutes(directCosts, dist, prev)
    activeDirectCosts = directCosts
    activeBestCosts = dist
    activeBestPrev = prev
end

-- Dijkstra's algorithm (declared BEFORE AppendAzPediaTooltip so it is in scope)
local function FindCheapestPaths(graph, startNode)
    local dist = {}
    local prev = {}
    local unvisited = {}

    for node, _ in pairs(graph) do
        dist[node] = math.huge
        unvisited[node] = true
    end
    dist[startNode] = 0

    while next(unvisited) do
        local u = nil
        local best = math.huge
        for node, _ in pairs(unvisited) do
            if dist[node] < best then
                best = dist[node]
                u = node
            end
        end

        if not u or best == math.huge then break end
        unvisited[u] = nil

        if graph[u] then
            for neighbor, cost in pairs(graph[u]) do
                if dist[neighbor] == nil then dist[neighbor] = math.huge end
                local alt = dist[u] + cost
                if alt < dist[neighbor] then
                    dist[neighbor] = alt
                    prev[neighbor] = u
                end
            end
        end
    end

    return dist, prev
end

-- Helper to get Blizzard's default fare for any reachable slot (single-hop or auto-routed)
local function GetDefaultNodeCost(index)
    local cost = TaxiNodeCost(index)
    if cost and cost > 0 then
        return cost
    end
    -- Fallback for Classic TaxiFrame: sum the legs along Blizzard's default route
    if GetNumRoutes and TaxiGetNodeSlot then
        local numRoutes = GetNumRoutes(index)
        if numRoutes and numRoutes > 0 then
            local total = 0
            for r = 1, numRoutes do
                local srcSlot = TaxiGetNodeSlot(index, r, true)
                local dstSlot = TaxiGetNodeSlot(index, r, false)
                if srcSlot and dstSlot then
                    local srcName = TaxiNodeName(srcSlot)
                    local dstName = TaxiNodeName(dstSlot)
                    local legCost = AzPediaDB.graph[srcName] and AzPediaDB.graph[srcName][dstName]
                    if legCost then
                        total = total + legCost
                    else
                        return nil -- Missing leg data for auto-route sum
                    end
                end
            end
            if total > 0 then return total end
        end
    end
    return nil
end
local function RenderSavingsLines(destName)
    if not destName then return end
    local directCost = activeDirectCosts[destName]
    local bestCost = activeBestCosts[destName]

    if directCost and bestCost and bestCost < directCost then
        local savings = directCost - bestCost
        local route = ReconstructPath(activeBestPrev, destName)

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            string.format("|cffffd100[AzPedia]|r Save |cff00ff00%s|r (%s total)", FormatCopper(savings), FormatCopper(bestCost)),
            1, 1, 1
        )
        GameTooltip:AddLine("Route: " .. route, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end
end

local function AppendAzPediaTooltip(index)
    if type(index) ~= "number" or TaxiNodeGetType(index) ~= "REACHABLE" then return end

    local destName = TaxiNodeName(index)
    if not destName then return end

    -- Grab live cost right on hover in case TAXIMAP_OPENED fired before cost data arrived
    local liveCost = GetDefaultNodeCost(index)
    if liveCost and liveCost > 0 and currentHubName then
        activeDirectCosts[destName] = liveCost
        AzPediaDB.graph[currentHubName] = AzPediaDB.graph[currentHubName] or {}
        if AzPediaDB.graph[currentHubName][destName] ~= liveCost then
            AzPediaDB.graph[currentHubName][destName] = liveCost
            AzPediaDB.graph[destName] = AzPediaDB.graph[destName] or {}
            local dist, prev = FindCheapestPaths(AzPediaDB.graph, currentHubName)
            CacheTaxiRoutes(activeDirectCosts, dist, prev)
        end
    end

    RenderSavingsLines(destName)
end





-- Track already-hooked TaxiButton frames so we never attach duplicate scripts
local hookedButtons = setmetatable({}, { __mode = "k" })

local function HookTaxiButtons()
    local numNodes = NumTaxiNodes() or 0
    for i = 1, numNodes do
        local btn = _G["TaxiButton" .. i]
        if btn and not hookedButtons[btn] then
            btn:HookScript("OnEnter", function(self)
                local index = self:GetID()
                if not index or index == 0 then
                    index = self.index or i
                end
                AppendAzPediaTooltip(index)
            end)
            hookedButtons[btn] = true
        end
    end
end

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        AzPediaDB = AzPediaDB or { graph = {} }
        print("|cff00ff00AzPedia loaded.|r Talk to Flight Masters to build your fare database.")

    elseif event == "TAXIMAP_OPENED" then
        C_Timer.After(0, function()
            local numNodes = NumTaxiNodes()
            local currentNode = nil
            local directCosts = {}

            -- 1. Identify current hub and collect direct costs
            for i = 1, numNodes do
                local nodeType = TaxiNodeGetType(i)
                local name = TaxiNodeName(i)
                if nodeType == "CURRENT" then
                    currentNode = name
                elseif nodeType == "REACHABLE" and name then
                    local cost = GetDefaultNodeCost(i)
                    if cost and cost > 0 then
                        directCosts[name] = cost
                    end
                end
            end

            if not currentNode then return end
            currentHubName = currentNode

            -- 2. Save edges into persistent graph
            AzPediaDB.graph[currentNode] = AzPediaDB.graph[currentNode] or {}
            for dest, cost in pairs(directCosts) do
                AzPediaDB.graph[currentNode][dest] = cost
                AzPediaDB.graph[dest] = AzPediaDB.graph[dest] or {}
            end

            -- 3. Compare direct fares against multi-hop graph paths
            local dist, prev = FindCheapestPaths(AzPediaDB.graph, currentNode)
            CacheTaxiRoutes(directCosts, dist, prev)
            HookTaxiButtons()

            local foundSavings = false
            for dest, directCost in pairs(directCosts) do
                local bestCost = dist[dest]
                if bestCost and bestCost < directCost then
                    foundSavings = true
                    local savings = directCost - bestCost
                    local route = ReconstructPath(prev, dest)
                end
            end

        end)
    end
end)
