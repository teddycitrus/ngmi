--!strict
--[[
    QuestUI.client.luau
    Client-side quest tracker panel in top-right corner.
    Shows active quests, progress, and completion notifications.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemDefinitions = require(ReplicatedStorage.Shared.ItemDefinitions)
local UITheme = require(ReplicatedStorage.Shared.UITheme)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local QuestUpdate = Remotes:WaitForChild("QuestUpdate") :: RemoteEvent
local QuestComplete = Remotes:WaitForChild("QuestComplete") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================
-- STATE
-- ============================================================
local currentPhase = 0
local isMinimized = false
local activeQuests: { [string]: { name: string, description: string, progress: number, target: number, completed: boolean } } = {}

-- ============================================================
-- UI CREATION
-- ============================================================
local questGui = Instance.new("ScreenGui")
questGui.Name = "QuestTracker"
questGui.DisplayOrder = 25
questGui.ResetOnSpawn = false
-- The ObjectivesUI panel ("OBJECTIVES") is the single source of truth for tasks;
-- this older QUESTS tracker just overlapped it as a blank/duplicate panel, so it
-- stays hidden. (The reward pop-up notification lives in its own ScreenGui below.)
questGui.Enabled = false
questGui.Parent = playerGui

-- Container
local container = Instance.new("Frame")
container.Name = "Container"
container.Size = UDim2.new(0, 260, 0, 40) -- Starts small, grows with quests
container.Position = UDim2.new(1, -270, 0, 80)
container.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
container.BackgroundTransparency = 0.2
container.BorderSizePixel = 0
container.Visible = false
container.Parent = questGui

local containerCorner = Instance.new("UICorner")
containerCorner.CornerRadius = UDim.new(0, 10)
containerCorner.Parent = container

local containerStroke = Instance.new("UIStroke")
containerStroke.Color = Color3.fromRGB(60, 65, 80)
containerStroke.Thickness = 1
containerStroke.Transparency = 0.3
containerStroke.Parent = container

-- Header
local header = Instance.new("TextButton")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 32)
header.BackgroundTransparency = 1
header.Text = "QUESTS"
header.TextSize = 14
header.FontFace = UITheme.Font.Bold
header.TextColor3 = Color3.fromRGB(200, 200, 220)
header.TextXAlignment = Enum.TextXAlignment.Left
header.Parent = container

local headerPadding = Instance.new("UIPadding")
headerPadding.PaddingLeft = UDim.new(0, 10)
headerPadding.Parent = header

-- Minimize indicator
local minimizeIcon = Instance.new("TextLabel")
minimizeIcon.Size = UDim2.new(0, 20, 0, 20)
minimizeIcon.Position = UDim2.new(1, -30, 0, 6)
minimizeIcon.BackgroundTransparency = 1
minimizeIcon.Text = "▼"
minimizeIcon.TextSize = 12
minimizeIcon.FontFace = UITheme.Font.Bold
minimizeIcon.TextColor3 = Color3.fromRGB(150, 150, 170)
minimizeIcon.Parent = header

-- Quest list
local questList = Instance.new("Frame")
questList.Name = "QuestList"
questList.Size = UDim2.new(1, -16, 0, 0)
questList.Position = UDim2.new(0, 8, 0, 35)
questList.BackgroundTransparency = 1
questList.ClipsDescendants = true
questList.Parent = container

local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, 6)
listLayout.Parent = questList

-- Toggle minimize
header.Activated:Connect(function()
    isMinimized = not isMinimized
    minimizeIcon.Text = if isMinimized then "▶" else "▼"
    questList.Visible = not isMinimized
    updateContainerSize()
end)

-- ============================================================
-- QUEST ENTRY CREATION
-- ============================================================
local function createQuestEntry(questId: string, questData: typeof(activeQuests[""])): Frame
    local entry = Instance.new("Frame")
    entry.Name = "Quest_" .. questId
    entry.Size = UDim2.new(1, 0, 0, 50)
    entry.BackgroundColor3 = Color3.fromRGB(30, 35, 45)
    entry.BackgroundTransparency = 0.3
    entry.BorderSizePixel = 0
    entry.Parent = questList

    local entryCorner = Instance.new("UICorner")
    entryCorner.CornerRadius = UDim.new(0, 6)
    entryCorner.Parent = entry

    -- Quest name
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "Name"
    nameLabel.Size = UDim2.new(1, -10, 0, 20)
    nameLabel.Position = UDim2.new(0, 8, 0, 4)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = questData.name
    nameLabel.TextSize = 13
    nameLabel.FontFace = UITheme.Font.Bold
    nameLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.Parent = entry

    -- Progress text
    local progressLabel = Instance.new("TextLabel")
    progressLabel.Name = "Progress"
    progressLabel.Size = UDim2.new(1, -10, 0, 16)
    progressLabel.Position = UDim2.new(0, 8, 0, 26)
    progressLabel.BackgroundTransparency = 1
    progressLabel.Text = string.format("%d/%d", questData.progress, questData.target)
    progressLabel.TextSize = 12
    progressLabel.FontFace = UITheme.Font.Mono
    progressLabel.TextColor3 = Color3.fromRGB(150, 200, 150)
    progressLabel.TextXAlignment = Enum.TextXAlignment.Left
    progressLabel.Parent = entry

    -- Completed indicator
    if questData.completed then
        nameLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
        progressLabel.Text = "COMPLETE"
        progressLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
    end

    return entry
end

-- ============================================================
-- UI UPDATES
-- ============================================================
function updateContainerSize()
    local questCount = 0
    for _ in activeQuests do questCount += 1 end

    local contentHeight = if isMinimized then 0 else questCount * 56
    local totalHeight = 38 + contentHeight

    TweenService:Create(container, TweenInfo.new(0.2), {
        Size = UDim2.new(0, 260, 0, totalHeight),
    }):Play()
end

local function refreshQuestList()
    -- Clear existing entries
    for _, child in questList:GetChildren() do
        if child:IsA("Frame") then child:Destroy() end
    end

    -- Recreate entries
    for questId, questData in activeQuests do
        createQuestEntry(questId, questData)
    end

    -- Show/hide container
    local hasQuests = false
    for _ in activeQuests do hasQuests = true; break end
    container.Visible = hasQuests and (currentPhase == 1 or currentPhase == 2)

    updateContainerSize()
end

-- ============================================================
-- COMPLETION NOTIFICATION
-- ============================================================
local function showCompletionNotification(questId: string, rewards: { { itemId: string, count: number } })
    local notifGui = Instance.new("ScreenGui")
    notifGui.Name = "QuestNotification"
    notifGui.DisplayOrder = 200
    notifGui.Parent = playerGui

    local notif = Instance.new("Frame")
    notif.Size = UDim2.new(0, 300, 0, 54)
    notif.Position = UDim2.new(1, 0, 0.15, 0) -- Start off-screen right
    notif.BackgroundColor3 = UITheme.Color.Surface
    notif.BackgroundTransparency = UITheme.Alpha.Surface
    notif.BorderSizePixel = 0
    notif.Parent = notifGui
    UITheme.corner(notif, 6)
    UITheme.outline(notif)

    -- Thin accent down the left edge
    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(0, 2, 1, -16)
    accent.Position = UDim2.new(0, 8, 0, 8)
    accent.BackgroundColor3 = UITheme.Color.Good
    accent.BorderSizePixel = 0
    accent.Parent = notif

    -- Quest complete text
    local completeText = UITheme.label(notif, {
        text = "QUEST COMPLETE",
        size = 11,
        font = UITheme.Font.Bold,
        color = UITheme.Color.Good,
        shadow = false,
    })
    completeText.Size = UDim2.new(1, -36, 0, 14)
    completeText.Position = UDim2.new(0, 20, 0, 9)

    -- Rewards text
    local rewardParts = {}
    for _, reward in rewards do
        local item = ItemDefinitions.getItem(reward.itemId)
        local name = if item then item.name else reward.itemId
        table.insert(rewardParts, name .. " x" .. reward.count)
    end

    local rewardText = UITheme.label(notif, {
        text = table.concat(rewardParts, ", "),
        size = 14,
        font = UITheme.Font.Regular,
        shadow = false,
    })
    rewardText.Size = UDim2.new(1, -36, 0, 18)
    rewardText.Position = UDim2.new(0, 20, 0, 26)
    rewardText.TextTruncate = Enum.TextTruncate.AtEnd

    -- Slide in
    TweenService:Create(notif, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Position = UDim2.new(1, -(300 + UITheme.Margin), 0.15, 0),
    }):Play()

    -- Slide out after 4s
    task.delay(4, function()
        TweenService:Create(notif, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Position = UDim2.new(1, 20, 0.15, 0),
        }):Play()

        task.delay(0.4, function()
            notifGui:Destroy()
        end)
    end)
end

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
QuestUpdate.OnClientEvent:Connect(function(data: { id: string, name: string, description: string, progress: number, target: number, completed: boolean, active: boolean })
    if data.active or data.completed then
        activeQuests[data.id] = {
            name = data.name,
            description = data.description,
            progress = data.progress,
            target = data.target,
            completed = data.completed,
        }
    elseif typeof(data.id) == "string" then
        activeQuests[data.id] = nil -- reset for a new match
    end
    refreshQuestList()
end)

QuestComplete.OnClientEvent:Connect(function(data: { questId: string, rewards: { { itemId: string, count: number } } })
    showCompletionNotification(data.questId, data.rewards)
end)

GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    currentPhase = data.phase
    -- Hide during Night2 and cutscenes
    container.Visible = (currentPhase == 1 or currentPhase == 2) and next(activeQuests) ~= nil
end)

print("[QuestUI] Initialized - quest tracker ready")
