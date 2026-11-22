--!strict
local Wallet = require("../../src/server/Wallet")

local function fresh(coins: number, onChange: (() -> ())?): (any, { coins: number })
	local data = { coins = coins }
	return Wallet.new(data, onChange), data
end

return {
	{
		name = "charging 30 from 100 leaves 70, in the profile data too",
		run = function()
			local w, data = fresh(100)
			assert(w:charge(30, "test") == true)
			assert(w:balance() == 70)
			assert(data.coins == 70, "the profile table must hold the new balance")
		end,
	},
	{
		name = "charging more than the balance is refused",
		run = function()
			local w = fresh(70)
			assert(w:charge(71, "test") == false)
			assert(w:balance() == 70)
			assert(w:charge(70, "test") == true, "charging the exact balance is allowed")
			assert(w:balance() == 0)
		end,
	},
	{
		name = "bad charge amounts are refused and change nothing",
		run = function()
			local w = fresh(70)
			local bad: { any } = { 1.5, -1, 0 / 0, math.huge, -math.huge, "5", true, {}, 1e300 }
			for _, amount in bad do
				assert(w:charge(amount, "test") == false, `charge {tostring(amount)} should be refused`)
				assert(w:balance() == 70)
			end
			assert(w:charge(nil :: any, "test") == false)
			assert(w:balance() == 70)
		end,
	},
	{
		name = "bad credit amounts are refused and change nothing",
		run = function()
			local w = fresh(70)
			local bad: { any } = { 1.5, -1, 0 / 0, math.huge, -math.huge, "5", true, {}, 1e300 }
			for _, amount in bad do
				assert(w:credit(amount, "test") == false, `credit {tostring(amount)} should be refused`)
				assert(w:balance() == 70)
			end
		end,
	},
	{
		name = "crediting 0 succeeds with no change, and crediting adds",
		run = function()
			local w = fresh(70)
			assert(w:credit(0, "test") == true)
			assert(w:balance() == 70)
			assert(w:credit(30, "test") == true)
			assert(w:balance() == 100)
		end,
	},
	{
		name = "a credit that would pass the safe integer range is refused",
		run = function()
			local top = 2 ^ 53
			local w = fresh(top - 1)
			assert(w:credit(2, "test") == false)
			assert(w:balance() == top - 1)
			assert(w:credit(1, "test") == true)
			assert(w:balance() == top)
		end,
	},
	{
		name = "a corrupt stored balance refuses every change",
		run = function()
			local bad: { number } = { 0 / 0, -5, 2.5, math.huge }
			for _, coins in bad do
				local w = fresh(coins)
				assert(w:charge(1, "test") == false)
				assert(w:credit(1, "test") == false)
			end
		end,
	},
	{
		name = "onChange fires once per successful call and never on a refused one",
		run = function()
			local calls = 0
			local w = fresh(100, function()
				calls += 1
			end)
			assert(w:charge(30, "test"))
			assert(calls == 1)
			assert(w:credit(10, "test"))
			assert(calls == 2)
			assert(w:charge(1000, "test") == false)
			assert(w:charge(1.5, "test") == false)
			assert(w:credit(-1, "test") == false)
			assert(w:credit(0 / 0, "test") == false)
			assert(calls == 2, `onChange fired on a refusal, calls = {calls}`)
		end,
	},
	{
		name = "onChange sees the new balance",
		run = function()
			local seen: { number } = {}
			local data = { coins = 100 }
			local w = Wallet.new(data, function()
				table.insert(seen, data.coins)
			end)
			w:charge(30, "test")
			w:credit(5, "test")
			assert(seen[1] == 70 and seen[2] == 75 and #seen == 2)
		end,
	},
}
