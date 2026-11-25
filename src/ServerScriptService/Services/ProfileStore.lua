--[[
	ProfileStore (A5) — session-locked, migration-aware profile load/save over any backend with
	an UpdateAsync(key, transform) method (DataStore in live servers, MemoryBackend in Studio mock
	mode and in tests). Pure: no Roblox services; time and waiting are injected.

	Record = { data = <PlayerDataSchema v1>, meta = { jobId, lockedAt, savedAt, sessions } }

	Session lock: a server owns a profile while meta.jobId is its JobId. Load waits for another
	live session (up to LoadAttempts * LockWaitSeconds), then takes over; a lock older than
	LockTimeoutSeconds counts as stale (crashed server). Every save re-checks the lock inside the
	transform and REFUSES to write if another server took over, so an older session can never
	overwrite a newer one. Autosaves refresh lockedAt.

	Failure policy: load failure => status "Unavailable": the player keeps playing on defaults in
	memory, NOTHING is ever written for them (real data is never replaced by defaults). Save
	failure => status "Unsaved": data stays in memory, dirty stays true, retried on the next save;
	never reported as saved. Retries are bounded (no infinite UpdateAsync loops).
	Profiles from a NEWER schema load read-only and are never written by this server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))

local ProfileStore = {}
ProfileStore.__index = ProfileStore

ProfileStore.Defaults = {
	LockTimeoutSeconds = 600,
	LockWaitSeconds = 4,
	LoadAttempts = 4,
	SaveAttempts = 3,
	BackoffSeconds = { 1, 2, 4 },
}

-- Pure lock decision: "Acquire" | "Busy" | "Steal"
function ProfileStore.LockDecision(meta, jobId, now, timeout)
	if type(meta) ~= "table" or meta.jobId == nil or meta.jobId == jobId then
		return "Acquire"
	end
	if now - (tonumber(meta.lockedAt) or 0) >= timeout then
		return "Steal"
	end
	return "Busy"
end

function ProfileStore.new(options)
	local self = setmetatable({}, ProfileStore)
	self.backend = assert(options.backend, "backend")
	self.jobId = assert(options.jobId, "jobId")
	self.clock = options.clock or os.time
	self.wait = options.wait or function() end
	self.log = options.log or function() end
	self.mock = options.mock == true
	local cfg = {}
	for k, v in pairs(ProfileStore.Defaults) do
		cfg[k] = v
	end
	for k, v in pairs(options.config or {}) do
		cfg[k] = v
	end
	self.config = cfg
	return self
end

function ProfileStore:_call(key, transform)
	return pcall(function()
		return self.backend:UpdateAsync(key, transform)
	end)
end

-- Returns a profile table (always; check profile.status).
function ProfileStore:Load(key)
	local cfg = self.config
	local profile = { key = key, data = nil, status = "Loading", dirty = false, notes = {} }
	for attempt = 1, cfg.LoadAttempts do
		local decision, loaded, readOnly, note
		local now = self.clock()
		local ok, err = self:_call(key, function(old)
			local meta = type(old) == "table" and old.meta or nil
			decision = ProfileStore.LockDecision(meta, self.jobId, now, cfg.LockTimeoutSeconds)
			if decision == "Busy" and attempt < cfg.LoadAttempts then
				return nil -- another live server holds it: do not write, wait and retry
			end
			local data, _, migrateNote = PlayerDataSchema.Migrate(type(old) == "table" and old.data or nil)
			note = migrateNote
			if type(data) == "table" and (tonumber(data.schemaVersion) or 0) > PlayerDataSchema.Version then
				readOnly = true
				loaded = data
				return nil -- never write a newer schema from an older server
			end
			loaded = data
			return {
				data = data,
				meta = { jobId = self.jobId, lockedAt = now, savedAt = meta and meta.savedAt or 0, sessions = ((meta and tonumber(meta.sessions)) or 0) + 1 },
			}
		end)
		if ok and loaded then
			profile.data = loaded
			if readOnly then
				profile.status = "ReadOnly"
				table.insert(profile.notes, "profile was saved by a newer game version: read only this session")
			else
				profile.status = self.mock and "Mock" or "Ready"
				if decision == "Busy" then
					table.insert(profile.notes, "took over a session that was still active elsewhere")
				elseif decision == "Steal" then
					table.insert(profile.notes, "previous session lock was stale")
				end
			end
			if note then
				table.insert(profile.notes, note)
			end
			profile.loadedAt = now
			return profile
		elseif ok then
			self.wait(cfg.LockWaitSeconds) -- busy elsewhere
		else
			self.log("[Profiles] load attempt " .. attempt .. " failed for " .. tostring(key) .. ": " .. tostring(err))
			self.wait(cfg.BackoffSeconds[math.min(attempt, #cfg.BackoffSeconds)])
		end
	end
	-- Could not load: play on defaults in memory, never write over the real record.
	profile.data = PlayerDataSchema.Defaults()
	profile.status = "Unavailable"
	table.insert(profile.notes, "could not load saved progress; this session will not be saved")
	return profile
end

function ProfileStore.CanSave(profile)
	return profile.status == "Ready" or profile.status == "Mock" or profile.status == "Unsaved"
end

-- Save (and optionally release the lock). Returns ok, reason. Serialized per profile.
function ProfileStore:Save(profile, release)
	if not ProfileStore.CanSave(profile) then
		return false, profile.status
	end
	while profile.saving do
		self.wait(0.1)
	end
	if not ProfileStore.CanSave(profile) then
		return false, profile.status
	end
	profile.saving = true
	local cfg = self.config
	local serial = profile.dirtySerial
	local snapshot = PlayerDataSchema.DeepCopy(profile.data)
	local refused = false
	local lastErr
	for attempt = 1, cfg.SaveAttempts do
		local now = self.clock()
		local written = false
		local ok, err = self:_call(profile.key, function(old)
			local meta = type(old) == "table" and old.meta or nil
			if meta and meta.jobId ~= nil and meta.jobId ~= self.jobId then
				refused = true
				return nil -- another server took over: never overwrite the newer session
			end
			written = true
			return {
				data = snapshot,
				meta = { jobId = (not release) and self.jobId or nil, lockedAt = (not release) and now or 0, savedAt = now, sessions = meta and meta.sessions or 1 },
			}
		end)
		if refused then
			profile.saving = false
			profile.status = "TakenOver"
			table.insert(profile.notes, "another server took over this profile; this session stopped saving")
			return false, "TakenOver"
		end
		if ok and written then
			profile.saving = false
			profile.lastSavedAt = now
			profile.saveCount = (profile.saveCount or 0) + 1
			profile.dirty = profile.dirtySerial ~= serial -- changed again while we were writing?
			profile.status = self.mock and "Mock" or "Ready"
			if release then
				profile.released = true
			end
			return true
		end
		lastErr = err
		self.log("[Profiles] save attempt " .. attempt .. " failed for " .. tostring(profile.key) .. ": " .. tostring(err))
		if attempt < cfg.SaveAttempts then
			self.wait(cfg.BackoffSeconds[math.min(attempt, #cfg.BackoffSeconds)])
		end
	end
	profile.saving = false
	profile.status = "Unsaved"
	profile.dirty = true
	return false, tostring(lastErr)
end

-- Mark changed; Save() later writes it.
function ProfileStore.MarkDirty(profile)
	profile.dirty = true
	profile.dirtySerial = (profile.dirtySerial or 0) + 1
end

---------------------------------------------------------------------------------------------
-- In-memory backend (Studio mock mode, tests). Same UpdateAsync contract as DataStore:
-- transform(old) -> new | nil (nil = cancel, keep old). Failure injection for tests.
---------------------------------------------------------------------------------------------
local MemoryBackend = {}
MemoryBackend.__index = MemoryBackend

function ProfileStore.MemoryBackend()
	return setmetatable({ records = {}, failNext = 0, calls = 0, writes = 0 }, MemoryBackend)
end

function MemoryBackend:UpdateAsync(key, transform)
	self.calls = self.calls + 1
	if self.failNext > 0 then
		self.failNext = self.failNext - 1
		error("injected DataStore failure")
	end
	local old = PlayerDataSchema.DeepCopy(self.records[key])
	local new = transform(old)
	if new ~= nil then
		self.records[key] = PlayerDataSchema.DeepCopy(new)
		self.writes = self.writes + 1
	end
	return new
end

return ProfileStore
