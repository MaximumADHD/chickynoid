--!strict
local Enums = {}

Enums.EventType = table.freeze({
	ChickynoidAdded = 0,
	ChickynoidRemoving = 1,
	Command = 2,
	State = 3,
	Snapshot = 4,
	WorldState = 5,
	CollisionData = 6,
	
	WeaponDataChanged = 8,
	BulletFire = 9,
	BulletImpact = 10,

	DebugBox = 11,

	PlayerDisconnected = 12,
})

Enums.NetworkProblemState = table.freeze({
	None = 0,
	TooFarBehind = 1,
	TooFarAhead = 2,
	TooManyCommands = 3,
	DroppedPacketGood = 4,
	DroppedPacketBad = 5,
	CommandUnderrun = 6,
})

Enums.FpsMode = table.freeze({
	Uncapped = 0,
	Hybrid = 1,
	Fixed60 = 2,
})

Enums.AnimChannel = table.freeze({
	Channel0 = 0,
	Channel1 = 1,
	Channel2 = 2,
	Channel3 = 3,
})

Enums.WeaponData = table.freeze({
	WeaponAdd = 0,
	WeaponRemove = 1,
	WeaponState = 2,
	Equip = 3,
	Dequip = 4,
})

Enums.Crashland = table.freeze({
	STOP = 0,
	FULL_BHOP = 1,
	FULL_BHOP_FORWARD = 2,
	CAPPED_BHOP = 3,
	CAPPED_BHOP_FORWARD = 4,
})

return Enums
