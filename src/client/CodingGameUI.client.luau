--!strict
--[[
    CodingGameUI.client.luau
    Client-side coding mini-game interface with 3 game modes:
    1. Typing Challenge - type matching code snippets
    2. Bug Fix - spot the error in code
    3. Dependency Hell - match packages to versions
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CodingProgress = Remotes:WaitForChild("CodingProgress") :: RemoteEvent
local CodingTaskComplete = Remotes:WaitForChild("CodingTaskComplete") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

-- Gameplay runs in LockFirstPerson (mouse pinned + hidden), so free the cursor
-- while the coding terminal is open and restore it on close.
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CursorManager = require(Shared:WaitForChild("CursorManager"))
local UITheme = require(Shared:WaitForChild("UITheme"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================
-- CODE SNIPPETS (real-looking, funny)
-- ============================================================
local CODE_SNIPPETS = {
    'function submitProject()\n  local coffee = getCoffee()\n  if coffee == nil then\n    error("Cannot code without caffeine")\n  end\n  return deploy(coffee)\nend',
    'const sleep = async (hours) => {\n  // TODO: actually sleep\n  return new Promise((resolve) => {\n    setTimeout(resolve, 0);\n  });\n};',
    'def fix_bug(bug):\n    while True:\n        try:\n            bug.fix()\n            break\n        except Exception as e:\n            print("it works on my machine")\n            stackoverflow.search(e)',
    'import { useEffect, useState } from "react";\n\nexport function App() {\n  const [bugs, setBugs] = useState(99);\n  useEffect(() => {\n    setBugs(bugs + 1);\n  }, [bugs]);\n}',
    'class HackathonProject:\n    def __init__(self):\n        self.progress = 0\n        self.energy_drinks = 12\n        self.will_to_live = 100\n        self.hours_slept = 0',
    'try {\n  git.push("origin", "main", { force: true });\n  console.log("YOLO deploy successful");\n} catch (e) {\n  console.log("This is fine. Everything is fine.");\n  process.exit(1);\n}',
    'SELECT * FROM hackathon_teams\nWHERE sleep_hours > 0\nAND bugs_fixed > bugs_created\nORDER BY coffee_consumed DESC\nLIMIT 0; -- returns nothing',
    'func main() {\n    deadline := time.Now().Add(48 * time.Hour)\n    for time.Now().Before(deadline) {\n        code()\n        if rand.Intn(10) < 3 {\n            panicAttack()\n        }\n    }\n}',
    'const API_KEY = "sk-totally-not-hardcoded";\n\nasync function callAI(prompt) {\n  const res = await fetch(API_URL, {\n    headers: { Authorization: API_KEY },\n    body: JSON.stringify({ prompt }),\n  });\n  return res.json();\n}',
    'fn compile_project() -> Result<(), Error> {\n    let mut attempts = 0;\n    loop {\n        attempts += 1;\n        match cargo_build() {\n            Ok(_) => return Ok(()),\n            Err(e) if attempts < 100 => continue,\n            Err(e) => panic!("NGMI: {}", e),\n        }\n    }\n}',

    -- ── CLI / terminal sequences devs actually run ──────────────────────
    'git checkout -b feature/ship-it\nnpm install\nnpm run dev\ngit add .\ngit commit -m "it works on my machine"\ngit push origin main',
    'docker build -t hackathon-app .\ndocker run -p 3000:3000 hackathon-app\ndocker ps\ndocker logs --tail 50 hackathon-app\ndocker system prune -af',
    'rm -rf node_modules\nnpm cache clean --force\nnpm install\nnpm run build\nnpm run deploy -- --force\ngit push --force origin main',
    'git stash\ngit pull --rebase\ngit stash pop\ngit add -A\ngit commit -m "resolve conflicts (probably)"\ngit push',
    'kubectl apply -f deploy.yaml\nkubectl get pods\nkubectl rollout status deploy/app\nkubectl logs -f deploy/app\nkubectl scale deploy/app --replicas=3',
    'cd hackathon-mvp\nyarn install\nyarn add express cors dotenv\nyarn build\nyarn start --port 8080',
    'ssh deploy@prod\nexport NODE_ENV=production\npm2 restart all\npm2 logs --lines 20\nexit',

    -- ── more languages / syntaxes ───────────────────────────────────────
    '#!/bin/bash\nset -euo pipefail\nexport NODE_ENV=production\nif [ -z "$API_KEY" ]; then\n  echo "no API key, deploying anyway"\nfi\nnpm run start',
    'interface HackathonTeam {\n  name: string;\n  members: number;\n  caffeineLevel: number;\n  willShip: boolean;\n}\n\nconst team: HackathonTeam = getTeam();',
    'public class Main {\n    public static void main(String[] args) {\n        while (true) {\n            System.out.println("compiling...");\n            sleep(0);\n        }\n    }\n}',
    'class Project\n  def initialize\n    @bugs = 99\n    @commits = 0\n  end\n\n  def ship!\n    raise "not ready" unless @bugs.zero?\n  end\nend',
    '#include <iostream>\n\nint main() {\n    while (deadline_not_met()) {\n        write_code();\n        drink_coffee();\n    }\n    return EXIT_SUCCESS;\n}',
    '<?php\nfunction deploy($code) {\n    if (empty($code)) {\n        die("nothing to deploy");\n    }\n    return shell_exec("git push");\n}',
    'FROM node:20-alpine\nWORKDIR /app\nCOPY package.json .\nRUN npm install\nCOPY . .\nEXPOSE 3000\nCMD ["npm", "start"]',
    '.hero {\n  display: flex;\n  justify-content: center;\n  background: #0f0f17;\n  color: #00ffcc;\n  animation: panic 0.5s infinite;\n}',
    '<!DOCTYPE html>\n<html>\n  <head>\n    <title>Our MVP</title>\n  </head>\n  <body>\n    <h1>Coming soon</h1>\n  </body>\n</html>',
    'name: deploy\non:\n  push:\n    branches: [main]\njobs:\n  ship:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm ci && npm run deploy',
    'package main\n\nimport "fmt"\n\nfunc main() {\n    defer fmt.Println("see you never, bugs")\n    fmt.Println("hello, judges")\n}',
}

-- Bug fix puzzles: {code lines, buggy line index (1-based), bug description}
local BUG_FIX_PUZZLES = {
    {
        lines = {
            'function calculateScore(answers) {',
            '  let total = 0;',
            '  for (let i = 0; i <= answers.length; i++) {',
            '    total += answers[i].points;',
            '  }',
            '  return total;',
            '}',
        },
        bugLine = 3,
        hint = "Off-by-one error in loop condition",
    },
    {
        lines = {
            'def get_winner(scores):',
            '    best = scores[0]',
            '    for score in scores:',
            '        if score > best:',
            '            best == score',
            '    return best',
        },
        bugLine = 5,
        hint = "Assignment vs comparison operator",
    },
    {
        lines = {
            'const fetchData = async () => {',
            '  const response = await fetch("/api/data");',
            '  const data = response.json();',
            '  return data;',
            '};',
        },
        bugLine = 3,
        hint = "Missing await on async operation",
    },
    {
        lines = {
            'class User:',
            '    def __init__(self, name):',
            '        self.name = name',
            '        self.score = 0',
            '',
            '    def add_score(self, points):',
            '        score += points',
            '        return self.score',
        },
        bugLine = 7,
        hint = "Missing self reference",
    },
}

-- Dependency puzzles
local DEPENDENCY_SETS = {
    { packages = {"react", "express", "lodash", "axios"}, versions = {"18.2.0", "4.18.2", "4.17.21", "1.6.7"} },
    { packages = {"numpy", "pandas", "flask", "requests"}, versions = {"1.26.0", "2.1.4", "3.0.0", "2.31.0"} },
    { packages = {"vue", "webpack", "typescript", "eslint"}, versions = {"3.4.15", "5.90.0", "5.3.3", "8.56.0"} },
}

-- ============================================================
-- STATE
-- ============================================================
local currentPhase = 0
local isOpen = false
local taskCount = 0
local codingGui: ScreenGui? = nil
local projectCompletion = 0
local isPowerDown = false

-- ============================================================
-- SCANLINE EFFECT
-- ============================================================
local function createScanlines(parent: Frame)
    for i = 0, 30 do
        local line = Instance.new("Frame")
        line.Size = UDim2.new(1, 0, 0, 1)
        line.Position = UDim2.new(0, 0, 0, i * 20)
        line.BackgroundColor3 = Color3.new(0, 0, 0)
        line.BackgroundTransparency = 0.85
        line.BorderSizePixel = 0
        line.ZIndex = 5
        line.Parent = parent
    end
end

-- ============================================================
-- TERMINAL HEADER
-- ============================================================
-- ============================================================
-- TERMINAL ATMOSPHERE
-- ============================================================
-- Phosphor glow + CRT scanlines for the coding terminal. Both are purely
-- decorative: Active = false and no GuiButtons, so neither can swallow a click
-- from the puzzle underneath or interfere with the CursorManager scene.
-- ============================================================

--- Phosphor bleed. A stroke in the text's own colour at low opacity reads as an
--- old monitor blooming, and unlike a duplicated blurred label it costs one
--- instance and stays aligned automatically.
local function addTerminalGlow(label: TextLabel | TextBox, intensity: number?)
    local stroke = Instance.new("UIStroke")
    stroke.Name = "PhosphorGlow"
    stroke.Color = label.TextColor3
    stroke.Thickness = 1.2
    stroke.Transparency = 1 - (intensity or 0.35)
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    stroke.Parent = label
    -- Keep the bleed matched to the text if the colour changes (correct/wrong
    -- feedback recolours several of these mid-puzzle).
    label:GetPropertyChangedSignal("TextColor3"):Connect(function()
        stroke.Color = label.TextColor3
    end)
end

--- CRT scanlines confined to one frame. Pitch is in pixels so the line spacing
--- stays constant regardless of how the panel scales.
local function addScanlines(parent: Frame, pitch: number, alpha: number)
    local holder = Instance.new("Frame")
    holder.Name = "Scanlines"
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.ClipsDescendants = true
    holder.Active = false
    holder.ZIndex = 50
    holder.Parent = parent

    local function redraw()
        holder:ClearAllChildren()
        local height = holder.AbsoluteSize.Y
        if height <= 0 then
            return
        end
        for y = 0, math.ceil(height), pitch do
            local line = Instance.new("Frame")
            line.Size = UDim2.new(1, 0, 0, 1)
            line.Position = UDim2.new(0, 0, 0, y)
            line.BackgroundColor3 = Color3.new(0, 0, 0)
            line.BackgroundTransparency = alpha
            line.BorderSizePixel = 0
            line.Active = false
            line.ZIndex = 50
            line.Parent = holder
        end
    end

    redraw()
    holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(redraw)
end

local function createTerminalFrame(): (ScreenGui, Frame, TextLabel)
    if codingGui then codingGui:Destroy() end

    codingGui = Instance.new("ScreenGui")
    codingGui.Name = "CodingGame"
    codingGui.DisplayOrder = 80
    codingGui.IgnoreGuiInset = true
    codingGui.Parent = playerGui

    -- Full screen overlay
    local overlay = Instance.new("Frame")
    overlay.Size = UDim2.new(1, 0, 1, 0)
    overlay.BackgroundColor3 = Color3.fromRGB(5, 10, 5)
    overlay.BackgroundTransparency = 0.05
    overlay.BorderSizePixel = 0
    overlay.Parent = codingGui

    -- Terminal window
    -- Faint dark vignette behind the terminal so the panel sits in the room
    -- rather than floating flat on top of it.
    local backdrop = Instance.new("UIGradient")
    backdrop.Rotation = 90
    backdrop.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.35),
        NumberSequenceKeypoint.new(0.5, 0.6),
        NumberSequenceKeypoint.new(1, 0.35),
    })
    backdrop.Parent = overlay

    local terminal = Instance.new("Frame")
    terminal.Name = "Terminal"
    terminal.Size = UDim2.new(0.7, 0, 0.75, 0)
    terminal.Position = UDim2.new(0.15, 0, 0.1, 0)
    terminal.BackgroundColor3 = Color3.fromRGB(10, 15, 10)
    terminal.BorderSizePixel = 0
    terminal.ClipsDescendants = true
    terminal.Parent = codingGui

    local termCorner = Instance.new("UICorner")
    termCorner.CornerRadius = UDim.new(0, 10)
    termCorner.Parent = terminal

    local termStroke = Instance.new("UIStroke")
    termStroke.Color = Color3.fromRGB(0, 180, 0)
    termStroke.Thickness = 2
    termStroke.Transparency = 0.5
    termStroke.Parent = terminal

    createScanlines(terminal)

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 35)
    titleBar.BackgroundColor3 = Color3.fromRGB(20, 30, 20)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = terminal

    local titleText = Instance.new("TextLabel")
    titleText.Size = UDim2.new(1, -80, 1, 0)
    titleText.Position = UDim2.new(0, 10, 0, 0)
    titleText.BackgroundTransparency = 1
    titleText.Text = "hackathon-project $ ./build.sh"
    titleText.TextSize = 14
    titleText.FontFace = UITheme.Font.Mono
    titleText.TextColor3 = Color3.fromRGB(0, 200, 0)
    titleText.TextXAlignment = Enum.TextXAlignment.Left
    titleText.Parent = titleBar
    addTerminalGlow(titleText)

    -- Close button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 30, 0, 25)
    closeBtn.Position = UDim2.new(1, -40, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
    closeBtn.Text = "✕"
    closeBtn.TextSize = 14
    closeBtn.FontFace = UITheme.Font.Bold
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Parent = titleBar

    local closeBtnCorner = Instance.new("UICorner")
    closeBtnCorner.CornerRadius = UDim.new(0, 6)
    closeBtnCorner.Parent = closeBtn

    closeBtn.Activated:Connect(function()
        closeCodingUI()
    end)

    -- Progress bar
    local progressFrame = Instance.new("Frame")
    progressFrame.Size = UDim2.new(1, -20, 0, 24)
    progressFrame.Position = UDim2.new(0, 10, 0, 40)
    progressFrame.BackgroundColor3 = Color3.fromRGB(20, 25, 20)
    progressFrame.BorderSizePixel = 0
    progressFrame.Parent = terminal

    local progressCorner = Instance.new("UICorner")
    progressCorner.CornerRadius = UDim.new(0, 4)
    progressCorner.Parent = progressFrame

    local progressFill = Instance.new("Frame")
    progressFill.Name = "Fill"
    progressFill.Size = UDim2.new(projectCompletion / 100, 0, 1, 0)
    progressFill.BackgroundColor3 = Color3.fromRGB(0, 200, 80)
    progressFill.BorderSizePixel = 0
    progressFill.Parent = progressFrame

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 4)
    fillCorner.Parent = progressFill

    local progressLabel = Instance.new("TextLabel")
    progressLabel.Name = "ProgressLabel"
    progressLabel.Size = UDim2.new(1, 0, 1, 0)
    progressLabel.BackgroundTransparency = 1
    progressLabel.Text = string.format("Project: %d%%", math.floor(projectCompletion))
    progressLabel.TextSize = 12
    progressLabel.FontFace = UITheme.Font.Mono
    progressLabel.TextColor3 = Color3.new(1, 1, 1)
    progressLabel.ZIndex = 3
    progressLabel.Parent = progressFrame

    -- Content area
    local content = Instance.new("Frame")
    content.Name = "Content"
    content.Size = UDim2.new(1, -20, 1, -80)
    content.Position = UDim2.new(0, 10, 0, 70)
    content.BackgroundTransparency = 1
    content.Parent = terminal

    -- CRT pass over the finished panel. Added last so it layers above every
    -- child, and only to the terminal window rather than the whole screen.
    addScanlines(terminal, 3, 0.94)

    return codingGui, content, progressLabel
end

-- ============================================================
-- MINI-GAME 1: TYPING CHALLENGE
-- ============================================================
local function startTypingChallenge()
    local gui, content, progressLabel = createTerminalFrame()
    isOpen = true

    local snippet = CODE_SNIPPETS[math.random(1, #CODE_SNIPPETS)]
    -- Keep tasks short & simple: a task is just the first couple of non-blank lines
    -- of the snippet, not the whole block.
    local allLines = string.split(snippet, "\n")
    local lines = {}
    for _, ln in allLines do
        if ln:match("%S") then
            table.insert(lines, ln)
            if #lines >= 2 then
                break
            end
        end
    end
    if #lines == 0 then
        lines = { "ship()" }
    end
    local currentLine = 1
    local totalChars = 0
    local correctChars = 0

    -- Display code to type
    local codeDisplay = Instance.new("TextLabel")
    codeDisplay.Name = "CodeDisplay"
    codeDisplay.Size = UDim2.new(1, 0, 0.5, 0)
    codeDisplay.Position = UDim2.new(0, 0, 0, 0)
    codeDisplay.BackgroundTransparency = 1
    codeDisplay.Text = table.concat(lines, "\n")
    codeDisplay.TextSize = 16
    codeDisplay.FontFace = UITheme.Font.Mono
    codeDisplay.TextColor3 = Color3.fromRGB(0, 180, 0)
    codeDisplay.TextXAlignment = Enum.TextXAlignment.Left
    codeDisplay.TextYAlignment = Enum.TextYAlignment.Top
    codeDisplay.TextWrapped = true
    codeDisplay.Parent = content
    addTerminalGlow(codeDisplay)

    -- Current line indicator
    local lineIndicator = Instance.new("TextLabel")
    lineIndicator.Name = "LineIndicator"
    lineIndicator.Size = UDim2.new(1, 0, 0, 25)
    lineIndicator.Position = UDim2.new(0, 0, 0.52, 0)
    lineIndicator.BackgroundTransparency = 1
    lineIndicator.Text = "Type line " .. currentLine .. "/" .. #lines .. ":"
    lineIndicator.TextSize = 14
    lineIndicator.FontFace = UITheme.Font.Mono
    lineIndicator.TextColor3 = Color3.fromRGB(200, 200, 0)
    lineIndicator.TextXAlignment = Enum.TextXAlignment.Left
    lineIndicator.Parent = content
    addTerminalGlow(lineIndicator)

    -- Target line
    local targetDisplay = Instance.new("TextLabel")
    targetDisplay.Name = "Target"
    targetDisplay.Size = UDim2.new(1, 0, 0, 30)
    targetDisplay.Position = UDim2.new(0, 0, 0.57, 0)
    targetDisplay.BackgroundColor3 = Color3.fromRGB(20, 30, 20)
    targetDisplay.Text = (lines[currentLine] or "")
    targetDisplay.TextSize = 16
    targetDisplay.FontFace = UITheme.Font.Mono
    targetDisplay.TextColor3 = Color3.fromRGB(100, 255, 100)
    targetDisplay.TextXAlignment = Enum.TextXAlignment.Left
    targetDisplay.Parent = content
    addTerminalGlow(targetDisplay)

    local targetCorner = Instance.new("UICorner")
    targetCorner.CornerRadius = UDim.new(0, 4)
    targetCorner.Parent = targetDisplay

    -- Input box
    local inputBox = Instance.new("TextBox")
    inputBox.Name = "Input"
    inputBox.Size = UDim2.new(1, 0, 0, 35)
    inputBox.Position = UDim2.new(0, 0, 0.65, 0)
    inputBox.BackgroundColor3 = Color3.fromRGB(15, 20, 15)
    inputBox.Text = ""
    inputBox.PlaceholderText = "> Type here..."
    inputBox.PlaceholderColor3 = Color3.fromRGB(50, 80, 50)
    inputBox.TextSize = 16
    inputBox.FontFace = UITheme.Font.Mono
    inputBox.TextColor3 = Color3.fromRGB(0, 255, 0)
    inputBox.TextXAlignment = Enum.TextXAlignment.Left
    inputBox.ClearTextOnFocus = true
    inputBox.Parent = content
    addTerminalGlow(inputBox)

    local inputCorner = Instance.new("UICorner")
    inputCorner.CornerRadius = UDim.new(0, 6)
    inputCorner.Parent = inputBox

    local inputStroke = Instance.new("UIStroke")
    inputStroke.Color = Color3.fromRGB(0, 150, 0)
    inputStroke.Thickness = 1
    inputStroke.Parent = inputBox

    -- Feedback label
    local feedback = Instance.new("TextLabel")
    feedback.Name = "Feedback"
    feedback.Size = UDim2.new(1, 0, 0, 25)
    feedback.Position = UDim2.new(0, 0, 0.73, 0)
    feedback.BackgroundTransparency = 1
    feedback.Text = ""
    feedback.TextSize = 14
    feedback.FontFace = UITheme.Font.Mono
    feedback.TextXAlignment = Enum.TextXAlignment.Left
    feedback.Parent = content

    inputBox:CaptureFocus()

    -- Handle submission
    inputBox.FocusLost:Connect(function(enterPressed: boolean)
        if not enterPressed or not isOpen then return end

        -- Compare against the line ignoring BOTH leading and trailing whitespace,
        -- so indentation (and any stray spaces at the ends) never costs you
        -- accuracy — typing the actual code scores a true 100%.
        local function trim(s: string): string
            return (s:gsub("^%s*(.-)%s*$", "%1"))
        end
        -- Edit-distance similarity (0-1). A naive positional compare tanked the
        -- score on a single early typo (every later char then "mismatched"); this
        -- measures how many edits actually separate your text from the target, so
        -- the accuracy reflects how close you really typed it.
        local function similarity(a: string, b: string): number
            if a == b then return 1 end
            local la, lb = #a, #b
            if la == 0 or lb == 0 then return 0 end
            local prev = table.create(lb + 1)
            for j = 0, lb do prev[j] = j end
            for i = 1, la do
                local cur = table.create(lb + 1)
                cur[0] = i
                local ca = a:sub(i, i)
                for j = 1, lb do
                    local cost = if ca == b:sub(j, j) then 0 else 1
                    cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                end
                prev = cur
            end
            return 1 - prev[lb] / math.max(la, lb)
        end

        local target = trim(lines[currentLine] or "")
        local typed = trim(inputBox.Text)
        local sim = if #target > 0 then similarity(typed, target) else 1
        totalChars += #target
        correctChars += sim * #target

        local lineAccuracy = sim * 100

        if lineAccuracy >= 70 then
            feedback.Text = string.format("✓ Line %d complete (%.0f%% accuracy)", currentLine, lineAccuracy)
            feedback.TextColor3 = Color3.fromRGB(0, 255, 0)
        else
            feedback.Text = string.format("✗ Line %d - %.0f%% accuracy (needs 70%%+)", currentLine, lineAccuracy)
            feedback.TextColor3 = Color3.fromRGB(255, 100, 100)
        end

        currentLine += 1
        inputBox.Text = ""

        if currentLine > #lines then
            -- Task complete!
            local overallAccuracy = (correctChars / math.max(1, totalChars)) * 100
            local score = math.clamp(overallAccuracy / 100, 0, 1)

            feedback.Text = string.format("✓ BUILD SUCCESSFUL! Accuracy: %.0f%%", overallAccuracy)
            feedback.TextColor3 = Color3.fromRGB(100, 255, 100)

            CodingTaskComplete:FireServer({ taskType = "typing", score = score })

            task.delay(2, function()
                if isOpen then
                    closeCodingUI()
                end
            end)
        else
            lineIndicator.Text = "Type line " .. currentLine .. "/" .. #lines .. ":"
            targetDisplay.Text = (lines[currentLine] or "")
            inputBox:CaptureFocus()
        end
    end)
end

-- ============================================================
-- MINI-GAME 2: BUG FIX
-- ============================================================
local function startBugFix()
    local gui, content, progressLabel = createTerminalFrame()
    isOpen = true

    local puzzle = BUG_FIX_PUZZLES[math.random(1, #BUG_FIX_PUZZLES)]
    local timeLimit = 15
    local startTime = tick()

    -- Header
    local header = Instance.new("TextLabel")
    header.Size = UDim2.new(1, 0, 0, 30)
    header.BackgroundTransparency = 1
    header.Text = "🐛 BUG FIX: Find the error! (" .. timeLimit .. "s)"
    header.TextSize = 18
    header.FontFace = UITheme.Font.Bold
    header.TextColor3 = Color3.fromRGB(255, 200, 50)
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Parent = content

    -- Hint
    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, 0, 0, 20)
    hint.Position = UDim2.new(0, 0, 0, 32)
    hint.BackgroundTransparency = 1
    hint.Text = "Hint: " .. puzzle.hint
    hint.TextSize = 13
    hint.FontFace = UITheme.Font.Mono
    hint.TextColor3 = Color3.fromRGB(150, 150, 200)
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.Parent = content

    -- Timer
    local timer = Instance.new("TextLabel")
    timer.Name = "Timer"
    timer.Size = UDim2.new(0, 100, 0, 25)
    timer.Position = UDim2.new(1, -100, 0, 0)
    timer.BackgroundTransparency = 1
    timer.Text = timeLimit .. "s"
    timer.TextSize = 18
    timer.FontFace = UITheme.Font.Mono
    timer.TextColor3 = Color3.fromRGB(255, 100, 100)
    timer.Parent = content

    -- Code lines as clickable buttons
    local solved = false
    for i, line in puzzle.lines do
        local lineBtn = Instance.new("TextButton")
        lineBtn.Name = "Line_" .. i
        lineBtn.Size = UDim2.new(1, 0, 0, 28)
        lineBtn.Position = UDim2.new(0, 0, 0, 60 + (i - 1) * 30)
        lineBtn.BackgroundColor3 = Color3.fromRGB(15, 20, 15)
        lineBtn.BackgroundTransparency = 0.3
        lineBtn.Text = string.format(" %2d | %s", i, line)
        lineBtn.TextSize = 14
        lineBtn.FontFace = UITheme.Font.Mono
        lineBtn.TextColor3 = Color3.fromRGB(0, 200, 0)
        lineBtn.TextXAlignment = Enum.TextXAlignment.Left
        lineBtn.Parent = content

        -- Hover effect
        lineBtn.MouseEnter:Connect(function()
            if not solved then
                lineBtn.BackgroundColor3 = Color3.fromRGB(30, 40, 30)
                lineBtn.BackgroundTransparency = 0
            end
        end)
        lineBtn.MouseLeave:Connect(function()
            if not solved then
                lineBtn.BackgroundColor3 = Color3.fromRGB(15, 20, 15)
                lineBtn.BackgroundTransparency = 0.3
            end
        end)

        lineBtn.Activated:Connect(function()
            if solved then return end
            solved = true

            if i == puzzle.bugLine then
                -- Correct!
                lineBtn.BackgroundColor3 = Color3.fromRGB(0, 100, 0)
                lineBtn.BackgroundTransparency = 0
                lineBtn.TextColor3 = Color3.fromRGB(100, 255, 100)

                local elapsed = tick() - startTime
                local speedBonus = math.clamp(1 - elapsed / timeLimit, 0, 1)
                local score = 0.7 + speedBonus * 0.3

                header.Text = "✓ Bug Fixed! Great job!"
                header.TextColor3 = Color3.fromRGB(100, 255, 100)

                CodingTaskComplete:FireServer({ taskType = "bugfix", score = score })
            else
                -- Wrong!
                lineBtn.BackgroundColor3 = Color3.fromRGB(100, 0, 0)
                lineBtn.BackgroundTransparency = 0

                -- Highlight correct line
                local correctBtn = content:FindFirstChild("Line_" .. puzzle.bugLine)
                if correctBtn and correctBtn:IsA("TextButton") then
                    correctBtn.BackgroundColor3 = Color3.fromRGB(0, 100, 0)
                    correctBtn.BackgroundTransparency = 0
                end

                header.Text = "✗ Build Failed. The bug was on line " .. puzzle.bugLine
                header.TextColor3 = Color3.fromRGB(255, 100, 100)

                CodingTaskComplete:FireServer({ taskType = "bugfix", score = 0.3 })
            end

            task.delay(2.5, function()
                if isOpen then closeCodingUI() end
            end)
        end)
    end

    -- Timer countdown
    task.spawn(function()
        while not solved and isOpen do
            local remaining = timeLimit - (tick() - startTime)
            if remaining <= 0 then
                solved = true
                header.Text = "✗ TIME'S UP! Build timed out."
                header.TextColor3 = Color3.fromRGB(255, 50, 50)
                CodingTaskComplete:FireServer({ taskType = "bugfix", score = 0.1 })
                task.delay(2, function()
                    if isOpen then closeCodingUI() end
                end)
                break
            end
            timer.Text = string.format("%.0fs", remaining)
            if remaining < 5 then
                timer.TextColor3 = Color3.fromRGB(255, 50, 50)
            end
            task.wait(0.1)
        end
    end)
end

-- ============================================================
-- MINI-GAME 3: DEPENDENCY HELL
-- ============================================================
local function startDependencyHell()
    local gui, content, progressLabel = createTerminalFrame()
    isOpen = true

    local depSet = DEPENDENCY_SETS[math.random(1, #DEPENDENCY_SETS)]
    local timeLimit = 20
    local startTime = tick()
    local matched = 0
    local selectedPackage: number? = nil

    -- Shuffle versions
    local shuffledVersions = table.clone(depSet.versions)
    for i = #shuffledVersions, 2, -1 do
        local j = math.random(1, i)
        shuffledVersions[i], shuffledVersions[j] = shuffledVersions[j], shuffledVersions[i]
    end

    -- Tracking which version index maps to which original
    local versionToOriginal: { [number]: number } = {}
    for i, sv in shuffledVersions do
        for j, ov in depSet.versions do
            if sv == ov then
                versionToOriginal[i] = j
                break
            end
        end
    end

    local header = Instance.new("TextLabel")
    header.Size = UDim2.new(1, 0, 0, 30)
    header.BackgroundTransparency = 1
    header.Text = "📦 DEPENDENCY HELL: Match packages to versions!"
    header.TextSize = 18
    header.FontFace = UITheme.Font.Bold
    header.TextColor3 = Color3.fromRGB(255, 200, 50)
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Parent = content

    local timer = Instance.new("TextLabel")
    timer.Size = UDim2.new(0, 100, 0, 25)
    timer.Position = UDim2.new(1, -100, 0, 0)
    timer.BackgroundTransparency = 1
    timer.Text = timeLimit .. "s"
    timer.TextSize = 18
    timer.FontFace = UITheme.Font.Mono
    timer.TextColor3 = Color3.fromRGB(255, 200, 50)
    timer.Parent = content

    local packageButtons: { TextButton } = {}
    local versionButtons: { TextButton } = {}

    -- Package list (left side)
    for i, pkg in depSet.packages do
        local btn = Instance.new("TextButton")
        btn.Name = "Pkg_" .. i
        btn.Size = UDim2.new(0.4, 0, 0, 40)
        btn.Position = UDim2.new(0.05, 0, 0, 50 + (i - 1) * 50)
        btn.BackgroundColor3 = Color3.fromRGB(30, 50, 80)
        btn.Text = "  📦 " .. pkg
        btn.TextSize = 16
        btn.FontFace = UITheme.Font.Mono
        btn.TextColor3 = Color3.fromRGB(100, 200, 255)
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.Parent = content

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = btn

        packageButtons[i] = btn

        btn.Activated:Connect(function()
            if matched >= 4 then return end
            selectedPackage = i
            -- Highlight
            for _, pb in packageButtons do
                pb.BackgroundColor3 = Color3.fromRGB(30, 50, 80)
            end
            btn.BackgroundColor3 = Color3.fromRGB(50, 80, 130)
        end)
    end

    -- Version list (right side, shuffled)
    for i, ver in shuffledVersions do
        local btn = Instance.new("TextButton")
        btn.Name = "Ver_" .. i
        btn.Size = UDim2.new(0.4, 0, 0, 40)
        btn.Position = UDim2.new(0.55, 0, 0, 50 + (i - 1) * 50)
        btn.BackgroundColor3 = Color3.fromRGB(50, 40, 30)
        btn.Text = "  v" .. ver
        btn.TextSize = 16
        btn.FontFace = UITheme.Font.Mono
        btn.TextColor3 = Color3.fromRGB(255, 200, 100)
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.Parent = content

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = btn

        versionButtons[i] = btn

        btn.Activated:Connect(function()
            if selectedPackage == nil or matched >= 4 then return end

            local originalVersionIndex = versionToOriginal[i]
            if originalVersionIndex == selectedPackage then
                -- Correct match!
                matched += 1
                btn.BackgroundColor3 = Color3.fromRGB(0, 100, 0)
                btn.Active = false
                packageButtons[selectedPackage].BackgroundColor3 = Color3.fromRGB(0, 100, 0)
                packageButtons[selectedPackage].Active = false

                -- Draw connecting line
                local connector = Instance.new("TextLabel")
                connector.Size = UDim2.new(0.05, 0, 0, 2)
                connector.Position = UDim2.new(0.47, 0, 0, 70 + (selectedPackage - 1) * 50)
                connector.BackgroundColor3 = Color3.fromRGB(0, 200, 0)
                connector.Text = ""
                connector.Parent = content

                selectedPackage = nil

                if matched >= 4 then
                    local elapsed = tick() - startTime
                    local speedBonus = math.clamp(1 - elapsed / timeLimit, 0, 1)
                    local score = 0.6 + speedBonus * 0.4

                    header.Text = "✓ Dependencies resolved! npm install complete."
                    header.TextColor3 = Color3.fromRGB(100, 255, 100)

                    CodingTaskComplete:FireServer({ taskType = "dependency", score = score })

                    task.delay(2, function()
                        if isOpen then closeCodingUI() end
                    end)
                end
            else
                -- Wrong match - flash red
                btn.BackgroundColor3 = Color3.fromRGB(150, 30, 30)
                task.delay(0.3, function()
                    if btn.Parent and btn.Active then
                        btn.BackgroundColor3 = Color3.fromRGB(50, 40, 30)
                    end
                end)
            end
        end)
    end

    -- Timer
    task.spawn(function()
        while matched < 4 and isOpen do
            local remaining = timeLimit - (tick() - startTime)
            if remaining <= 0 then
                header.Text = "✗ npm ERR! Install timed out."
                header.TextColor3 = Color3.fromRGB(255, 50, 50)
                CodingTaskComplete:FireServer({ taskType = "dependency", score = matched * 0.15 })
                task.delay(2, function()
                    if isOpen then closeCodingUI() end
                end)
                break
            end
            timer.Text = string.format("%.0fs", remaining)
            if remaining < 5 then timer.TextColor3 = Color3.fromRGB(255, 50, 50) end
            task.wait(0.1)
        end
    end)
end

-- ============================================================
-- TASK SELECTION
-- ============================================================
local function openCodingTask()
    if isOpen then return end
    if isPowerDown then
        -- Show power down message
        local tempGui = Instance.new("ScreenGui")
        tempGui.DisplayOrder = 80
        tempGui.Parent = playerGui

        local msg = Instance.new("TextLabel")
        msg.Size = UDim2.new(0.4, 0, 0.08, 0)
        msg.Position = UDim2.new(0.3, 0, 0.45, 0)
        msg.BackgroundColor3 = Color3.fromRGB(30, 10, 10)
        msg.Text = "⚡ SYSTEMS DOWN - Restore all power & servers first!"
        msg.TextSize = 18
        msg.FontFace = UITheme.Font.Bold
        msg.TextColor3 = Color3.fromRGB(255, 100, 100)
        msg.Parent = tempGui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = msg

        task.delay(2, function() tempGui:Destroy() end)
        return
    end

    -- Free the cursor so the player can click code lines / packages and focus the
    -- text box. Paired with the pop() in closeCodingUI.
    CursorManager.push()

    taskCount += 1

    if taskCount % 5 == 0 then
        startDependencyHell()
    elseif taskCount % 3 == 0 then
        startBugFix()
    else
        startTypingChallenge()
    end
end

function closeCodingUI()
    if not isOpen then return end
    isOpen = false
    if codingGui then
        codingGui:Destroy()
        codingGui = nil
    end
    CursorManager.pop()
end

-- ============================================================
-- GLITCH EFFECTS (Night 2)
-- ============================================================
local function applyNight2Glitches()
    if currentPhase ~= 3 or not isOpen or not codingGui then return end

    task.spawn(function()
        while isOpen and currentPhase == 3 do
            task.wait(math.random(5, 15))
            if not isOpen or not codingGui then break end

            -- Screen flicker
            local flash = Instance.new("Frame")
            flash.Size = UDim2.new(1, 0, 1, 0)
            flash.BackgroundColor3 = Color3.fromRGB(0, 50, 0)
            flash.BackgroundTransparency = 0.7
            flash.ZIndex = 20
            flash.Parent = codingGui

            task.wait(0.05)
            if flash.Parent then flash:Destroy() end
        end
    end)
end

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
-- PlayerDesk proximity prompts are handled by InteractionManager;
-- we listen for a custom signal to open the coding UI
CodingProgress.OnClientEvent:Connect(function(data: { [string]: any })
    if type(data) ~= "table" then return end

    -- Desk-interaction control signals from InteractionManager
    if data.action == "start_coding" then
        openCodingTask()
        return
    elseif data.action == "stop_coding" then
        closeCodingUI()
        return
    end

    -- Otherwise it's a progress / power-state update from CodingGameServer
    if data.completion ~= nil then
        projectCompletion = data.completion
    end
    if data.blocked ~= nil then
        isPowerDown = data.blocked
    end
end)

GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    currentPhase = data.phase
    if data.phase == 0 then -- LOBBY
        closeCodingUI()
    end
end)

-- ESC to close
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if input.KeyCode == Enum.KeyCode.Escape and isOpen then
        closeCodingUI()
    end
end)

-- Expose openCodingTask for InteractionManager to call
local CodingGameUI = {}
CodingGameUI.open = openCodingTask
CodingGameUI.close = closeCodingUI

-- ============================================================
-- DESK PROMPT OWNERSHIP
-- Triggering is driven server-side (InteractionManager fires the
-- "start_coding" CodingProgress signal handled above). Here we only make sure
-- the "Code" prompt shows on the LOCAL player's OWN assigned desk and nobody
-- else's. ProximityPrompt.Enabled set on the client is local-only, so we hide
-- the other desks' prompts on this client (and re-hide them if the server
-- re-enables every desk on a phase change).
-- ============================================================
local CollectionService = game:GetService("CollectionService")

local function myDeskId(): any
    return player:GetAttribute("AssignedDeskId")
end

local function isMyDesk(desk: Instance): boolean
    local id = myDeskId()
    return id ~= nil and desk:GetAttribute("DeskId") == id
end

local function watchDeskPrompt(desk: Instance)
    if not (desk:IsA("BasePart") or desk:IsA("Model")) then return end
    task.spawn(function()
        local prompt = desk:WaitForChild("ProximityPrompt", 30)
        if not prompt or not prompt:IsA("ProximityPrompt") then return end
        local function refresh()
            -- Until we know which desk is ours, don't touch anything (otherwise
            -- we'd hide our own desk before the assignment arrives). Once known,
            -- only ever hide OTHER people's desks; leave our own to the server.
            if myDeskId() == nil then return end
            if not isMyDesk(desk) and prompt.Enabled then
                prompt.Enabled = false
            end
        end
        refresh()
        prompt:GetPropertyChangedSignal("Enabled"):Connect(refresh)
    end)
end

for _, desk in CollectionService:GetTagged("PlayerDesk") do
    watchDeskPrompt(desk)
end
CollectionService:GetInstanceAddedSignal("PlayerDesk"):Connect(watchDeskPrompt)

-- Our desk assignment can arrive after the desks do — re-hide non-owned desks
-- once we learn which one is ours.
player:GetAttributeChangedSignal("AssignedDeskId"):Connect(function()
    for _, desk in CollectionService:GetTagged("PlayerDesk") do
        local prompt = desk:FindFirstChildOfClass("ProximityPrompt")
        if prompt and not isMyDesk(desk) then
            prompt.Enabled = false
        end
    end
end)

print("[CodingGameUI] Initialized - 3 mini-game modes ready")
