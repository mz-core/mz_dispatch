MZDispatch = MZDispatch or {}

local Service = {}
local Windows = {}
local PanicWindows = {}
local SensorWindows = {}
local SensorCreating = {}
local SensorSequence = 0
-- Serializa criacoes concorrentes do mesmo cidadao/servico. Sem isso, duas
-- requisicoes com requestIds diferentes podem passar pelo getActiveByCaller
-- antes de qualquer INSERT e gerar dois chamados/toasts.
local Creating = {}

local function log(action, data)
  if MZDispatchConfig.debug ~= true then return end
  local parts = {}
  for key, value in pairs(data or {}) do
    parts[#parts + 1] = ('%s=%s'):format(tostring(key), tostring(value))
  end
  table.sort(parts)
  print(('[mz_dispatch] %s %s'):format(tostring(action), table.concat(parts, ' ')))
end

local function result(ok, code, extra)
  local out = { ok = ok == true, code = code }
  for key, value in pairs(extra or {}) do out[key] = value end
  return out
end

local function token(value, minimum, maximum)
  if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
  value = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
  if #value < (minimum or 1) or #value > (maximum or 64) then return nil end
  if not value:match('^[%w:_-]+$') then return nil end
  return value
end

local function text(value, maximum)
  if type(value) ~= 'string' then return nil end
  value = value:gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' or #value > maximum then return nil end
  return value
end

local function closed(payload, allowed)
  if type(payload) ~= 'table' then return false end
  for key in pairs(payload) do if allowed[key] ~= true then return false end end
  return true
end

local function repository(method, ...)
  local fn = MZDispatch.Repository and MZDispatch.Repository[method]
  if type(fn) ~= 'function' then return nil, 'repository_unavailable' end
  local args = table.pack(...)
  local returned = table.pack(pcall(function() return fn(table.unpack(args, 1, args.n)) end))
  if returned[1] ~= true then return nil, 'database_unavailable' end
  return table.unpack(returned, 2, returned.n)
end

local function rateAllowed(source)
  local settings = MZDispatchConfig.rateLimit or {}
  local maximum = math.max(1, math.floor(tonumber(settings.maximum) or 3))
  local windowMs = math.max(1000, math.floor((tonumber(settings.windowSeconds) or 60) * 1000))
  local now = GetGameTimer()
  local window = Windows[source]
  if not window or now - window.startedAt >= windowMs then
    window = { startedAt = now, count = 0 }
    Windows[source] = window
  end
  if window.count >= maximum then return false end
  window.count = window.count + 1
  return true
end

local function availability()
  if MZDispatchConfig.enabled ~= true then return false, 'dispatch_disabled' end
  if not (MZDispatch.Prepare and MZDispatch.Prepare.ready == true) then
    return false, 'dispatch_unavailable'
  end
  return true
end

local function serviceConfig(serviceCode)
  serviceCode = token(serviceCode, 2, 32)
  local service = serviceCode and MZDispatchConfig.services[serviceCode] or nil
  if type(service) ~= 'table' or type(service.orgCode) ~= 'string'
    or type(service.capability) ~= 'string' then return nil, nil end
  return serviceCode, service
end

local function incidentConfig(serviceCode, categoryCode)
  local configured = MZDispatchConfig.incidentTypes
  local entries = type(configured) == 'table' and configured[serviceCode] or nil
  if type(entries) ~= 'table' then return nil end
  for _, incident in ipairs(entries) do
    if type(incident) == 'table' and incident.code == categoryCode then
      local priority = math.floor(tonumber(incident.priority) or 0)
      if type(incident.label) == 'string' and priority >= 1 and priority <= 5 then
        return {
          code = tostring(incident.code),
          label = incident.label,
          priority = priority,
          internalOnly = incident.internalOnly == true
        }
      end
    end
  end
end

local function operation(action, identity, requestId)
  return ('dispatch:%s:%s:%s'):format(action, identity.citizenid, requestId)
end

local function audit(action, source, identity, extra)
  MZDispatch.Bridge.audit(action, {
    actor = { type = 'player', source = source, citizenid = identity and identity.citizenid },
    context = extra or {}
  })
end

local function notifyResponders(serviceCode, call, isNewCall)
  local notified = 0
  for _, playerId in ipairs(GetPlayers()) do
    local target = tonumber(playerId)
    if target then
      local authorized = MZDispatch.Bridge.authorizeResponder(target, serviceCode)
      if authorized then
        if isNewCall ~= false then
          local message = tostring(call.message or 'Chamado aguardando atendimento.')
          local x, y = tonumber(call.location_x), tonumber(call.location_y)
          local time = tostring(call.created_at or ''):match('%d%d:%d%d:%d%d')
          if x and y then
            message = ('%s | Local: %.2f, %.2f'):format(message, x, y)
          end
          local title = serviceCode == 'police' and 'Novo chamado policial' or 'Novo chamado medico'
          if time then title = ('%s | %s'):format(title, time:sub(1, 5)) end
          MZDispatch.Bridge.notify(target, {
            type = serviceCode == 'police' and 'police' or 'health',
            title = title,
            message = message,
            duration = 7000,
            icon = 'radio'
          })
          TriggerClientEvent('mz_dispatch:client:newCall', target, Service.toClientCall(call))
        else
          TriggerClientEvent('mz_dispatch:client:callUpdated', target, {
            callId = call.public_id,
            status = tostring(call.status or '')
          })
        end
        notified = notified + 1
      end
    end
  end
  log('call_notified', { callId = call.public_id or '', service = serviceCode, responders = notified })
end

function Service.toClientCall(call)
  if type(call) ~= 'table' then return nil end
  return {
    public_id = call.public_id,
    service_code = call.service_code,
    org_code = call.org_code,
    message = call.message,
    category_code = call.category_code,
    category_label = call.category_label,
    priority_level = tonumber(call.priority_level) or 3,
    priority_label = call.priority_label,
    source_type = call.source_type,
    report_count = tonumber(call.report_count) or 1,
    location_accuracy = call.location_accuracy or 'exact',
    status = call.status,
    location_x = call.location_x,
    location_y = call.location_y,
    location_z = call.location_z,
    routing_bucket = call.routing_bucket,
    created_at = call.created_at,
    updated_at = call.updated_at,
    assigned_units = tonumber(call.assigned_units)
      or (type(call.assignments) == 'table' and #call.assignments or 0)
  }
end

function Service.create(source, payload, internal)
  local available, unavailableCode = availability()
  if not available then
    log('create_denied', { source = source, code = unavailableCode })
    return result(false, unavailableCode)
  end
  if not closed(payload, { serviceCode = true, message = true, requestId = true, categoryCode = true }) then
    log('create_denied', { source = source, code = 'invalid_payload' })
    return result(false, 'invalid_payload')
  end
  source = tonumber(source)
  local serviceCode, service = serviceConfig(payload.serviceCode)
  local requestId = token(payload.requestId, 8, 64)
  local message = text(payload.message, tonumber(MZDispatchConfig.messageMaximumLength) or 280)
  local categoryCode = token(payload.categoryCode
    or (MZDispatchConfig.defaultIncidentTypes or {})[serviceCode], 2, 32)
  local incident = serviceCode and categoryCode and incidentConfig(serviceCode, categoryCode) or nil
  if not source or not serviceCode or not requestId or not message or not incident
    or (incident.internalOnly and internal ~= 'panic') then
    log('create_denied', { source = source, code = 'invalid_payload' })
    return result(false, 'invalid_payload')
  end
  if not rateAllowed(source) then return result(false, 'rate_limited') end

  local identity, identityError = MZDispatch.Bridge.resolveIdentity(source)
  if not identity then return result(false, identityError or 'identity_unavailable') end

  local lockKey = ('%s:%s'):format(identity.citizenid, serviceCode)
  if Creating[lockKey] then
    log('create_denied', { service = serviceCode, source = source, code = 'call_creation_in_progress' })
    return result(false, 'call_creation_in_progress')
  end
  Creating[lockKey] = true

  if internal ~= 'panic' then
    local active, activeError = repository('getActiveByCaller', identity.citizenid, serviceCode)
    if activeError then
      Creating[lockKey] = nil
      return result(false, activeError)
    end
    if active then
      Creating[lockKey] = nil
      log('call_reused', { callId = active.public_id or '', service = serviceCode, source = source })
      return result(true, 'call_already_open', { call = active })
    end
  end

  local location, locationError = MZDispatch.Bridge.getLocation(source)
  if not location then
    Creating[lockKey] = nil
    return result(false, locationError or 'location_unavailable')
  end
  local publicId = ('dispatch:%s:%s'):format(identity.citizenid, requestId)
  local created, createError = repository('create', {
    publicId = publicId,
    operationId = operation('create', identity, requestId),
    serviceCode = serviceCode,
    orgCode = service.orgCode,
    categoryCode = incident.code,
    priorityLevel = incident.priority,
    sourceType = internal == 'panic' and 'panic' or (serviceCode == 'medical' and 'medical' or 'phone'),
    locationAccuracy = 'exact',
    callerCitizenid = identity.citizenid,
    callerSessionId = identity.sessionId,
    message = message,
    location = location,
    details = { source = source, routingBucket = location.routingBucket }
  })
  Creating[lockKey] = nil
  if created ~= true then
    log('call_create_failed', { service = serviceCode, source = source, code = createError or 'call_create_failed' })
    return result(false, createError or 'call_create_failed')
  end
  local call, readError = repository('get', publicId)
  if not call then
    log('call_read_failed', { callId = publicId, service = serviceCode, code = readError or 'call_read_failed' })
    return result(false, readError or 'call_read_failed')
  end
  call.category_label = incident.label
  call.priority_label = (MZDispatchConfig.priorities or {})[incident.priority] or 'Normal'
  audit('call_created', source, identity, { callId = publicId, serviceCode = serviceCode })
  log('call_created', { callId = publicId, service = serviceCode, source = source })
  notifyResponders(serviceCode, call)
  return result(true, 'call_created', { call = call })
end

function Service.list(source, payload)
  local available, unavailableCode = availability()
  if not available then
    log('queue_denied', { source = source, code = unavailableCode })
    return result(false, unavailableCode)
  end
  if not closed(payload, {
    serviceCode = true, page = true, pageSize = true, status = true, categoryCode = true, priorityLevel = true
  }) then
    -- Diagnostico do bug P8: o MDT enviava requestId no payload de list.
    log('queue_denied', { source = source, code = 'invalid_payload' })
    return result(false, 'invalid_payload')
  end
  local serviceCode = serviceConfig(payload.serviceCode)
  if not serviceCode then return result(false, 'service_not_configured') end
  local authorization, authorizationError = MZDispatch.Bridge.authorizeResponder(source, serviceCode)
  if not authorization then
    log('queue_denied', { source = source, service = serviceCode, code = authorizationError or 'not_authorized' })
    return result(false, authorizationError or 'not_authorized')
  end
  local page = math.max(1, math.floor(tonumber(payload.page) or 1))
  local pageSize = math.max(1, math.min(
    math.floor(tonumber(payload.pageSize) or tonumber(MZDispatchConfig.pageSize) or 25),
    tonumber(MZDispatchConfig.maximumPageSize) or 50
  ))
  local status = payload.status == nil and 'active' or tostring(payload.status)
  if status ~= 'active' and status ~= 'open' and status ~= 'accepted' and status ~= 'closed' and status ~= 'all' then
    return result(false, 'invalid_status_filter')
  end
  local categoryCode = payload.categoryCode ~= nil and token(payload.categoryCode, 2, 32) or nil
  if payload.categoryCode ~= nil and (not categoryCode or not incidentConfig(serviceCode, categoryCode)) then
    return result(false, 'invalid_category_filter')
  end
  local priorityLevel = payload.priorityLevel ~= nil and tonumber(payload.priorityLevel) or nil
  if payload.priorityLevel ~= nil and (not priorityLevel or priorityLevel % 1 ~= 0
    or priorityLevel < 1 or priorityLevel > 5) then
    return result(false, 'invalid_priority_filter')
  end
  local queue, queueError = repository('list', serviceCode, page, pageSize, {
    status = status,
    categoryCode = categoryCode,
    priorityLevel = priorityLevel
  })
  if not queue then
    log('queue_failed', { source = source, service = serviceCode, code = queueError or 'queue_unavailable' })
    return result(false, queueError or 'queue_unavailable')
  end
  for _, call in ipairs(queue.items or {}) do
    local incident = incidentConfig(serviceCode, tostring(call.category_code or ''))
    call.category_label = incident and incident.label or 'Ocorrência'
    call.priority_label = (MZDispatchConfig.priorities or {})[tonumber(call.priority_level) or 3] or 'Normal'
  end
  for index, call in ipairs(queue.items or {}) do
    queue.items[index] = Service.toClientCall(call)
  end
  audit('queue_read', source, authorization.identity, { serviceCode = serviceCode, page = page })
  log('queue_loaded', { source = source, service = serviceCode, items = #(queue.items or {}) })
  return result(true, 'queue_loaded', queue)
end

function Service.get(source, payload)
  local available, unavailableCode = availability()
  if not available then return result(false, unavailableCode) end
  if not closed(payload, { callId = true }) then return result(false, 'invalid_payload') end
  local callId = token(payload.callId, 8, 160)
  if not callId then return result(false, 'invalid_payload') end
  local call, callError = repository('get', callId)
  if not call then return result(false, callError or 'call_not_found') end
  local authorization, authorizationError = MZDispatch.Bridge.authorizeResponder(source, call.service_code)
  if not authorization then return result(false, authorizationError or 'not_authorized') end
  return result(true, 'call_loaded', { call = call })
end

function Service.accept(source, payload)
  local available, unavailableCode = availability()
  if not available then
    log('accept_denied', { source = source, code = unavailableCode })
    return result(false, unavailableCode)
  end
  if not closed(payload, { callId = true, requestId = true }) then
    log('accept_denied', { source = source, code = 'invalid_payload' })
    return result(false, 'invalid_payload')
  end
  local callId, requestId = token(payload.callId, 8, 160), token(payload.requestId, 8, 64)
  if not callId or not requestId then
    log('accept_denied', { source = source, code = 'invalid_payload' })
    return result(false, 'invalid_payload')
  end
  local call, callError = repository('get', callId)
  if not call then return result(false, callError or 'call_not_found') end
  if call.status == 'closed' then
    log('accept_denied', { callId = callId, source = source, code = 'call_closed' })
    return result(false, 'call_closed')
  end
  local authorization, authorizationError = MZDispatch.Bridge.authorizeResponder(source, call.service_code)
  if not authorization then
    log('accept_denied', { callId = callId, source = source, code = authorizationError or 'not_authorized' })
    return result(false, authorizationError or 'not_authorized')
  end
  local alreadyAssigned, assignedError = repository('isAssigned', callId, authorization.identity.citizenid)
  if assignedError then return result(false, assignedError) end
  if alreadyAssigned ~= true then
    local assigned, assignError = repository('assign', call, authorization.identity,
      operation('accept', authorization.identity, requestId))
    if assigned ~= true then
      log('accept_failed', { callId = callId, source = source, code = assignError or 'assignment_failed' })
      return result(false, assignError or 'assignment_failed')
    end
  end
  call = repository('get', callId) or call
  audit('unit_assigned', source, authorization.identity, { callId = callId, serviceCode = call.service_code })
  log('unit_assigned', { callId = callId, source = source, service = call.service_code })
  return result(true, alreadyAssigned and 'unit_already_assigned' or 'unit_assigned', { call = call })
end

function Service.close(source, payload)
  local available, unavailableCode = availability()
  if not available then
    log('close_denied', { source = source, code = unavailableCode })
    return result(false, unavailableCode)
  end
  if not closed(payload, { callId = true, requestId = true }) then
    log('close_denied', { source = source, code = 'invalid_payload' })
    return result(false, 'invalid_payload')
  end
  local callId, requestId = token(payload.callId, 8, 160), token(payload.requestId, 8, 64)
  if not callId or not requestId then
    log('close_denied', { source = source, code = 'invalid_payload' })
    return result(false, 'invalid_payload')
  end
  local call, callError = repository('get', callId)
  if not call then return result(false, callError or 'call_not_found') end
  local authorization, authorizationError = MZDispatch.Bridge.authorizeResponder(source, call.service_code)
  if not authorization then
    log('close_denied', { callId = callId, source = source, code = authorizationError or 'not_authorized' })
    return result(false, authorizationError or 'not_authorized')
  end
  if call.status == 'closed' then
    log('close_replayed', { callId = callId, source = source })
    return result(true, 'call_already_closed', { call = call })
  end
  local assigned, assignedError = repository('isAssigned', callId, authorization.identity.citizenid)
  if assignedError then return result(false, assignedError) end
  if assigned ~= true then
    log('close_denied', { callId = callId, source = source, code = 'assignment_required' })
    return result(false, 'assignment_required')
  end
  local closedOk, closeError = repository('close', call, authorization.identity,
    operation('close', authorization.identity, requestId))
  if closedOk ~= true then
    log('close_failed', { callId = callId, source = source, code = closeError or 'close_failed' })
    return result(false, closeError or 'close_failed')
  end
  call = repository('get', callId) or call
  audit('call_closed', source, authorization.identity, { callId = callId, serviceCode = call.service_code })
  log('call_closed', { callId = callId, source = source, service = call.service_code })
  local callerSource = call.caller_citizenid
    and MZDispatch.Bridge.getSourceByCitizenId(call.caller_citizenid) or nil
  if callerSource then
    MZDispatch.Bridge.notify(callerSource, {
      type = 'success', title = 'Chamado encerrado', message = 'O atendimento foi concluído.', duration = 5000
    })
  end
  return result(true, 'call_closed', { call = call })
end

function Service.createMedicalHelp(source, requestId)
  return Service.create(source, {
    serviceCode = 'medical',
    message = 'Solicitação de socorro médico',
    requestId = requestId
  })
end

function Service.panic(source, payload)
  local available, unavailableCode = availability()
  if not available then return result(false, unavailableCode) end
  if not closed(payload, { requestId = true }) then return result(false, 'invalid_payload') end
  local requestId = token(payload.requestId, 8, 64)
  if not requestId then return result(false, 'invalid_payload') end
  local authorization, authorizationError = MZDispatch.Bridge.authorizeResponder(source, 'police')
  if not authorization then return result(false, authorizationError or 'not_authorized') end

  local now, cooldownMs = GetGameTimer(), 60000
  local previous = PanicWindows[authorization.identity.citizenid]
  if previous and now - previous < cooldownMs then return result(false, 'panic_cooldown') end
  for citizenid, startedAt in pairs(PanicWindows) do
    if now - startedAt >= cooldownMs then PanicWindows[citizenid] = nil end
  end

  local response = Service.create(source, {
    serviceCode = 'police',
    categoryCode = 'panic',
    message = 'Unidade policial solicita apoio imediato.',
    requestId = requestId
  }, 'panic')
  if response.ok then
    PanicWindows[authorization.identity.citizenid] = now
    response.call = Service.toClientCall(response.call)
    audit('police_panic_triggered', source, authorization.identity, {
      callId = response.call and response.call.public_id or ''
    })
  end
  return response
end

function Service.recordSensor(source, categoryCode)
  local settings = type(MZDispatchConfig.sensors) == 'table' and MZDispatchConfig.sensors or {}
  if settings.enabled ~= true then
    return result(false, 'sensors_disabled')
  end
  local available, unavailableCode = availability()
  if not available then return result(false, unavailableCode) end

  source = tonumber(source)
  local serviceCode, service = serviceConfig('police')
  local category = token(categoryCode, 2, 32)
  local incident = category and incidentConfig(serviceCode, category) or nil
  if not source or source <= 0 or not serviceCode or not incident
    or incident.internalOnly or (category ~= 'gunshots' and category ~= 'fight') then
    return result(false, 'invalid_sensor_signal')
  end

  local cooldownSeconds = math.max(5, math.min(120, math.floor(tonumber(settings.sourceCooldownSeconds) or 15)))
  local windowSeconds = math.max(10, math.min(180, math.floor(tonumber(settings.aggregationWindowSeconds) or 60)))
  local radius = math.max(20, math.min(250, tonumber(settings.aggregationRadius) or 100))
  local now = GetGameTimer()
  local cooldownKey = ('%s:%s'):format(source, category)
  if SensorWindows[cooldownKey] and now - SensorWindows[cooldownKey] < cooldownSeconds * 1000 then
    return result(false, 'sensor_cooldown')
  end

  local location, locationError = MZDispatch.Bridge.getLocation(source)
  if not location then return result(false, locationError or 'location_unavailable') end
  local lockKey = ('%s:%s:%s'):format(serviceCode, category, location.routingBucket)
  if SensorCreating[lockKey] then return result(false, 'sensor_busy') end
  SensorWindows[cooldownKey] = now
  SensorCreating[lockKey] = true

  local function finish(response)
    SensorCreating[lockKey] = nil
    return response
  end

  local grouped, groupedError = repository(
    'findRecentSensor', serviceCode, category, location.routingBucket, location, radius, windowSeconds
  )
  if groupedError then return finish(result(false, groupedError)) end
  if type(grouped) == 'table' and type(grouped.public_id) == 'string' then
    local updated, updateError = repository('incrementSensorReport', grouped.public_id)
    if updated ~= true then return finish(result(false, updateError or 'sensor_update_failed')) end
    local call, readError = repository('get', grouped.public_id)
    if type(call) ~= 'table' then return finish(result(false, readError or 'call_read_failed')) end
    call.category_label = incident.label
    call.priority_label = (MZDispatchConfig.priorities or {})[incident.priority] or 'Normal'
    notifyResponders(serviceCode, call, false)
    log('sensor_report_grouped', { callId = call.public_id, category = category })
    return finish(result(true, 'sensor_report_grouped', { call = Service.toClientCall(call) }))
  end

  SensorSequence = SensorSequence + 1
  local requestId = ('%s:%s:%s'):format(tostring(location.routingBucket), tostring(now), tostring(SensorSequence))
  local publicId = ('dispatch:sensor:%s'):format(requestId)
  local created, createError = repository('create', {
    publicId = publicId,
    operationId = ('dispatch:sensor:%s'):format(requestId),
    historyActorCitizenid = 'system:mz_dispatch',
    callerCitizenid = nil,
    callerSessionId = nil,
    serviceCode = serviceCode,
    orgCode = service.orgCode,
    categoryCode = incident.code,
    priorityLevel = incident.priority,
    sourceType = 'sensor',
    locationAccuracy = 'server',
    message = category == 'fight'
      and 'Sinal automático de possível briga (não verificado).'
      or 'Sinal automático de possível disparo (não verificado).',
    location = location,
    details = { signal = 'weapon_damage', routingBucket = location.routingBucket }
  })
  if created ~= true then return finish(result(false, createError or 'call_create_failed')) end

  local call, readError = repository('get', publicId)
  if type(call) ~= 'table' then return finish(result(false, readError or 'call_read_failed')) end
  call.category_label = incident.label
  call.priority_label = (MZDispatchConfig.priorities or {})[incident.priority] or 'Normal'
  MZDispatch.Bridge.audit('sensor_call_created', {
    actor = { type = 'system', resource = 'mz_dispatch' },
    context = { callId = publicId, categoryCode = category, routingBucket = location.routingBucket }
  })
  notifyResponders(serviceCode, call)
  log('sensor_call_created', { callId = publicId, category = category })
  return finish(result(true, 'sensor_call_created', { call = Service.toClientCall(call) }))
end

function Service.clearSession(source)
  source = tonumber(source)
  if source then
    Windows[source] = nil
    for key in pairs(SensorWindows) do
      if key:match('^' .. source .. ':') then SensorWindows[key] = nil end
    end
  end
end

MZDispatch.Service = Service
