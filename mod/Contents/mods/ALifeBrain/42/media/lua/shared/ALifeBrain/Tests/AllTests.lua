-- Loads every test suite. Kept apart from TestRunner so no file requires itself.

require "ALifeBrain/Tests/TestRunner"
require "ALifeBrain/Tests/JsonTests"
require "ALifeBrain/Tests/BridgeTests"

return ALifeBrain.Tests
