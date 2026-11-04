MZDispatch = MZDispatch or {}

local actions = {
  create = MZDispatch.Service.create,
  list = MZDispatch.Service.list,
  get = MZDispatch.Service.get,
  accept = MZDispatch.Service.accept,
  close = MZDispatch.Service.close,
  panic = MZDispatch.Service.panic
}
local requestWindows = {}
local trackedAssignments = {}

local function trackAssignment(actorSource, call)
  if type(call) ~= 'table' or type(call.public_id) ~= 'string' then return end
  local ttl = math.max(1, math.floor(tonumber(MZDispatchConfig.blipTtlSeconds) or 300)) * 1000
  trackedAssignments[actorSource] = trackedAssignments[actorSource] or {}
  trackedAssignments[actorSource][call.public_id] = {
    serviceCode = tostring(call.service_code or ''),
    expiresAt = GetGameTimer() + ttl
  }
end

local function removeTrackedCall(callId, excludedSource)
  for actorSource, assignments in pairs(trackedAssignments) do
    if assignments[callId] then
      assignments[callId] = nil
      if actorSource ~= excludedSource then
        TriggerClientEvent('mz_dispatch:client:closed', actorSource, callId)
      end
    end
    if not next(assignments) then trackedAssignments[actorSource] = nil end
  end
end

local function token(value, minimum, maximum)
  if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
  value = tostring(value)
  if #value < minimum or #value > maximum or not value:match('^[%w:_-]+$') then return nil end
  return value
end

local function closedRequest(request)
  for key in pairs(request) do
    if key ~= 'action' and key ~= 'requestId' and key ~= 'payload' then return false end
  end
  return true
end

local function requestAllowed(actorSource)
  local settings = MZDispatchConfig.requestRateLimit or {}
  local maximum = math.max(1, math.floor(tonumber(settings.maximum) or 30))
  local windowMs = math.max(1000, math.floor((tonumber(settings.windowSeconds) or 10) * 1000))
  local now = GetGameTimer()
  local window = requestWindows[actorSource]
  if not window or now - window.startedAt >= windowMs then
    window = { startedAt = now, count = 0 }
    requestWindows[actorSource] = window
  end
  if window.count >= maximum then return false end
  window.count = window.count + 1
  return true
end

-- Sinal de invalidacao de snapshot para MDTs abertos. Nao e uma notificacao:
-- o consumidor reconsulta a lista canonica e nao dispara toast de novo chamado.
local function broadcastCallUpdated(actorSource, call)
  if type(call) ~= 'table' or type(call.public_id) ~= 'string' then return end
  local serviceCode = tostring(call.service_code or '')
  if serviceCode == '' then return end
  if tostring(call.status or '') == 'closed' then removeTrackedCall(call.public_id, actorSource) end
  local actor = tonumber(actorSource)
  for _, playerId in ipairs(GetPlayers()) do
    local target = tonumber(playerId)
    if target and target ~= actor then
      if MZDispatch.Bridge.authorizeResponder(target, serviceCode) then
        TriggerClientEvent('mz_dispatch:client:callUpdated', target, {
          callId = call.public_id,
          status = tostring(call.status or '')
        })
      end
    end
  end
end

RegisterNetEvent('mz_dispatch:server:request', function(request)
  local actorSource = source
  local allowed = requestAllowed(actorSource)
  request = type(request) == 'table' and request or {}
  local action = token(request.action, 1, 16) or ''
  local requestId = token(request.requestId, 8, 64) or ''
  local payload = type(request.payload) == 'table' and request.payload or {}
  local handler = actions[action]
  local response
  if not allowed then
    response = { ok = false, code = 'rate_limited' }
  elseif action == '' or requestId == '' or not closedRequest(request) then
    response = { ok = false, code = 'invalid_request' }
  elseif type(handler) ~= 'function' then
    response = { ok = false, code = 'invalid_action' }
  elseif (action == 'create' or action == 'accept' or action == 'close' or action == 'panic')
    and tostring(payload.requestId or '') ~= requestId then
    response = { ok = false, code = 'invalid_request' }
  else
    response = handler(actorSource, payload)
  end
  TriggerClientEvent('mz_dispatch:client:response', actorSource, {
    action = action,
    requestId = requestId,
    response = response
  })
  if action == 'accept' and response.ok == true and type(response.call) == 'table' then
    trackAssignment(actorSource, response.call)
    TriggerClientEvent(
      'mz_dispatch:client:assignment',
      actorSource,
      MZDispatch.Service.toClientCall(response.call)
    )
    broadcastCallUpdated(actorSource, response.call)
  elseif action == 'close' and response.ok == true and type(response.call) == 'table' then
    TriggerClientEvent('mz_dispatch:client:closed', actorSource, response.call.public_id)
    broadcastCallUpdated(actorSource, response.call)
  end
end)

AddEventHandler('playerDropped', function()
  requestWindows[source] = nil
  trackedAssignments[source] = nil
  MZDispatch.Service.clearSession(source)
end)

CreateThread(function()
  while true do
    Wait(10000)
    local now = GetGameTimer()
    for actorSource, assignments in pairs(trackedAssignments) do
      local revoked = false
      for callId, assignment in pairs(assignments) do
        if now >= assignment.expiresAt then
          assignments[callId] = nil
        elseif not MZDispatch.Bridge.authorizeResponder(actorSource, assignment.serviceCode) then
          revoked = true
          break
        end
      end
      if revoked then
        trackedAssignments[actorSource] = nil
        TriggerClientEvent('mz_dispatch:client:accessRevoked', actorSource)
      elseif not next(assignments) then
        trackedAssignments[actorSource] = nil
      end
    end
  end
end)

exports('CreateEmergencyCall', function(source, payload)
  return MZDispatch.Service.create(source, payload or {})
end)

exports('CreateMedicalHelpCall', function(source, requestId)
  return MZDispatch.Service.createMedicalHelp(source, requestId)
end)

exports('CreatePolicePanicCall', function(actorSource, requestId)
  if GetInvokingResource() ~= 'mz_police' then return { ok = false, code = 'forbidden_caller' } end
  return MZDispatch.Service.panic(actorSource, { requestId = requestId })
end)

exports('ListCalls', function(source, payload)
  return MZDispatch.Service.list(source, payload or {})
end)

exports('AcceptCall', function(source, payload)
  return MZDispatch.Service.accept(source, payload or {})
end)

exports('CloseCall', function(source, payload)
  return MZDispatch.Service.close(source, payload or {})
end)
