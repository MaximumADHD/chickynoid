local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.Packages
local Chickynoid = require(Packages.Chickynoid).ChickynoidClient

Chickynoid:Setup()
