--!strict
--------------------------------------------------------------------------------
-- ServerComm.luau
-- The ServerStorage.ServerComm folder of BindableEvent buses that server
-- scripts use to talk to each other (scripts can't require each other).
-- Get-or-create, so load order between a sender and a listener never matters.
--------------------------------------------------------------------------------

local ServerStorage = game:GetService("ServerStorage")

local ServerComm = {}

function ServerComm.folder(): Folder
	local found = ServerStorage:FindFirstChild("ServerComm")
	if found and found:IsA("Folder") then
		return found
	end
	local folder = Instance.new("Folder")
	folder.Name = "ServerComm"
	folder.Parent = ServerStorage
	return folder
end

function ServerComm.bus(name: string): BindableEvent
	local folder = ServerComm.folder()
	local found = folder:FindFirstChild(name)
	if found and found:IsA("BindableEvent") then
		return found
	end
	local bus = Instance.new("BindableEvent")
	bus.Name = name
	bus.Parent = folder
	return bus
end

return ServerComm
