--!strict
-- A player's Coins. It works directly on the profile's data table, so the balance saves together
-- with the layout. Whole Coins only: every amount is checked before anything is written, so a
-- refused call leaves the balance exactly as it was.
local Wallet = {}
Wallet.__index = Wallet

-- Past 2^53 a double can no longer count every whole number, so that is the ceiling.
local MAX_COINS = 2 ^ 53

-- The adapter Build takes. Keep in step with WalletLike in Build.luau.
export type WalletLike = {
	balance: (WalletLike) -> number,
	charge: (WalletLike, number, string) -> boolean,
	credit: (WalletLike, number, string) -> boolean,
}

export type Wallet = typeof(setmetatable(
	{} :: {
		data: { coins: number },
		onChange: (() -> ())?,
	},
	Wallet
))

-- A whole, non-negative number within range. Fails for NaN, infinity, fractions and non-numbers.
local function validCoins(value: any): boolean
	return type(value) == "number" and value >= 0 and value <= MAX_COINS and value == math.floor(value)
end

function Wallet.new(data: { coins: number }, onChange: (() -> ())?): Wallet
	return setmetatable({ data = data, onChange = onChange }, Wallet)
end

function Wallet.balance(self: Wallet): number
	return self.data.coins
end

local function changed(self: Wallet)
	local callback = self.onChange
	if callback ~= nil then
		callback()
	end
end

-- The reason is for the caller's records. The wallet keeps no log of its own.
function Wallet.charge(self: Wallet, amount: number, _reason: string): boolean
	local coins = self.data.coins
	if not validCoins(amount) or not validCoins(coins) or amount > coins then
		return false
	end
	self.data.coins = coins - amount
	changed(self)
	return true
end

function Wallet.credit(self: Wallet, amount: number, _reason: string): boolean
	local coins = self.data.coins
	if not validCoins(amount) or not validCoins(coins) or amount > MAX_COINS - coins then
		return false
	end
	self.data.coins = coins + amount
	changed(self)
	return true
end

return Wallet
