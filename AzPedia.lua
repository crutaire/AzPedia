local addonName = ...
local frame = CreateFrame("Frame")

-- Initialize SavedVariables
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("TAXIMAP_OPENED")

local function FormatCopper(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return string.format("%dg %ds %dc", g, s, c)
end

-- Dijkstra's algorithm to find lowest-cost path from `startNode`
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

local function ReconstructPath(prev, target)
    local path = {}
    local curr = target
    while curr do
        table.insert(path, 1, curr)
        curr = prev[curr]
    end
    return table.concat(path, " -> ")
end

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        CheapFlightDB = CheapFlightDB or { graph = {} }
        print("|cff00ff00CheapFlight loaded.|r Talk to Flight Masters to build your fare database.")

    elseif event == "TAXIMAP_OPENED" then
        local numNodes = NumTaxiNodes()
        local currentNode = nil
        local directCosts = {}

        -- 1. Identify current hub and collect direct costs
        for i = 1, numNodes do
            local nodeType = TaxiNodeGetType(i)
            local name = TaxiNodeName(i)
            if nodeType == "CURRENT" then
                currentNode = name
            elseif nodeType == "REACHABLE" then
                local cost = TaxiNodeCost(i)
                if cost and cost > 0 then
                    directCosts[name] = cost
                end
            end
        end

        if not currentNode then return end

        -- 2. Save edges into persistent graph
        CheapFlightDB.graph[currentNode] = CheapFlightDB.graph[currentNode] or {}
        for dest, cost in pairs(directCosts) do
            CheapFlightDB.graph[currentNode][dest] = cost
            CheapFlightDB.graph[dest] = CheapFlightDB.graph[dest] or {}
        end

        -- 3. Compare direct fares against multi-hop graph paths
        local dist, prev = FindCheapestPaths(CheapFlightDB.graph, currentNode)
        local foundSavings = false

        for dest, directCost in pairs(directCosts) do
            local bestCost = dist[dest]
            if bestCost and bestCost < directCost then
                foundSavings = true
                local savings = directCost - bestCost
                local route = ReconstructPath(prev, dest)
                print(string.format(
                    "|cffffd100[CheapFlight]|r Save |cff00ff00%s|r to %s: %s (%s vs %s direct)",
                    FormatCopper(savings), dest, route, FormatCopper(bestCost), FormatCopper(directCost)
                ))
            end
        end

        if not foundSavings then
            print("|cff888888[CheapFlight]|r Fares logged for " .. currentNode .. ". Visit more hubs to discover split-hop savings.")
        end
    end
end)
