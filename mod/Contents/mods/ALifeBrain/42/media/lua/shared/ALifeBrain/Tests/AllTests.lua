-- Loads every test suite. Kept apart from TestRunner so no file requires itself.

require "ALifeBrain/Tests/TestRunner"
require "ALifeBrain/Tests/JsonTests"
require "ALifeBrain/Tests/BridgeTests"
require "ALifeBrain/Tests/DialogueTests"
require "ALifeBrain/Tests/TradeTests"
require "ALifeBrain/Tests/BehaviorTests"
require "ALifeBrain/Tests/ParleyTests"
require "ALifeBrain/Tests/ControlTests"

return ALifeBrain.Tests
