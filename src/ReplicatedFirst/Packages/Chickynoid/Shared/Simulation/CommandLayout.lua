--!strict

local module = {}
local CrunchTable = require(script.Parent.Parent.Vendor.CrunchTable)

export type BinaryTable = CrunchTable.BinaryTable
type Layout = CrunchTable.Layout
type Self = typeof(module)

export type Command = {
	localFrame: number,
	serverTime: number,
	deltaTime: number,
	snapshotServerFrame: number?,
	playerStateFrame: number,
	shiftLock: number?,
	x: number,
	y: number,
	z: number,
	fa: Vector3?,
	f: number?,
	j: number?,

	elapsedTime: number?,
	playerElapsedTime: number?,
	fakeCommand: boolean?,
	serial: number?,
	reset: boolean?,

	[string]: any
}

type anyTable = {
	[any]: any
}

local commandLayout = CrunchTable:CreateLayout()
commandLayout:Add("localFrame",CrunchTable.Enum.INT32)
commandLayout:Add("serverTime", CrunchTable.Enum.FLOAT)
commandLayout:Add("deltaTime", CrunchTable.Enum.FLOAT)
commandLayout:Add("snapshotServerFrame", CrunchTable.Enum.INT32)	
commandLayout:Add("playerStateFrame", CrunchTable.Enum.INT32)
commandLayout:Add("shiftLock", CrunchTable.Enum.UBYTE)
commandLayout:Add("x", CrunchTable.Enum.FLOAT)
commandLayout:Add("y", CrunchTable.Enum.FLOAT)
commandLayout:Add("z", CrunchTable.Enum.FLOAT)
commandLayout:Add("fa", CrunchTable.Enum.VECTOR3)
commandLayout:Add("f", CrunchTable.Enum.FLOAT)
commandLayout:Add("j", CrunchTable.Enum.FLOAT)

function module.GetCommandLayout(self: Self)
	return commandLayout
end

function module.EncodeCommand(self: Self, command: Command): BinaryTable
	return CrunchTable:BinaryEncodeTable(command, commandLayout)
end

function module.DecodeCommand(self: Self, command: BinaryTable): Command
	return CrunchTable:BinaryDecodeTable(command, commandLayout) 
end

return module