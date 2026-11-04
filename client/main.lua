local blips = {}
local requestSequence = 0
local activeService
local activeFilter = { status = 'active', categoryCode = '', priorityLevel = '', page = 1 }
local panelOpen = false

local function notify(message, kind)
  if GetResourceState('mz_menu') == 'started' then
    exports['mz_menu']:Notify(message, kind or 'inform')
  else
    print(('[mz_dispatch] %s'):format(tostring(message)))
  end
end

local function nextRequestId()
  requestSequence = requestSequence + 1
  return ('dispatch_nui_%s_%s'):format(tostring(GetGameTimer()), tostring(requestSequence))
end

local function request(action, payload)
  local requestId = nextRequestId()
  payload = type(payload) == 'table' and payload or {}
  if action == 'accept' or action == 'close' or action == 'panic' then payload.requestId = requestId end
  TriggerServerEvent('mz_dispatch:server:request', {
    action = action, requestId = requestId, payload = payload
  })
end

local function requestList()
  if not activeService then return end
  local payload = {
    serviceCode = activeService,
    page = activeFilter.page,
    pageSize = MZDispatchConfig.pageSize or 25,
    status = activeFilter.status
  }
  if activeFilter.categoryCode ~= '' then payload.categoryCode = activeFilter.categoryCode end
  if activeFilter.priorityLevel ~= '' then payload.priorityLevel = tonumber(activeFilter.priorityLevel) end
  request('list', payload)
end

local function ui(message)
  SendNUIMessage(message)
end

local function closePanel()
  if not panelOpen then return end
  panelOpen = false
  SetNuiFocus(false, false)
  ui({ action = 'close' })
end

local function remove(callId)
  callId = tostring(callId or '')
  local blip = blips[callId]
  if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
  blips[callId] = nil
end

local function clearBlips()
  for callId in pairs(blips) do remove(callId) end
end

local function openPanel()
  if panelOpen then
    SetNuiFocus(true, true)
    ui({ action = 'open' })
    return
  end
  panelOpen = true
  activeService = nil
  activeFilter = { status = 'active', categoryCode = '', priorityLevel = '', page = 1 }
  SetNuiFocus(true, true)
  ui({
    action = 'open',
    services = MZDispatchConfig.services,
    incidentTypes = MZDispatchConfig.incidentTypes,
    priorities = MZDispatchConfig.priorities
  })
end

local function formatTime(value)
  local time = tostring(value or ''):match('%d%d:%d%d:%d%d')
  return time and time:sub(1, 5) or '--:--'
end

local function showCallFallback(call)
  if GetResourceState('mz_notify') == 'started' or GetResourceState('mz_menu') ~= 'started' then return end
  local x, y = tonumber(call.location_x), tonumber(call.location_y)
  local location = x and y and (' | Local: %.2f, %.2f'):format(x, y) or ''
  local category = call.service_code == 'medical' and 'médico' or 'policial'
  exports['mz_menu']:Notify({
    type = 'inform',
    title = ('Novo chamado %s | %s'):format(category, formatTime(call.created_at)),
    description = tostring(call.message or 'Chamado aguardando atendimento.') .. location,
    duration = 7000,
    icon = 'radio'
  })
end

RegisterNUICallback('close', function(_, cb)
  closePanel()
  cb({ ok = true })
end)

RegisterNUICallback('request', function(data, cb)
  data = type(data) == 'table' and data or {}
  local action = tostring(data.action or '')
  local payload = type(data.payload) == 'table' and data.payload or {}
  if action == 'service' then
    local serviceCode = tostring(payload.serviceCode or '')
    if MZDispatchConfig.services[serviceCode] then
      activeService = serviceCode
      activeFilter = { status = 'active', categoryCode = '', priorityLevel = '', page = 1 }
      ui({ action = 'service', serviceCode = serviceCode })
      requestList()
    end
  elseif action == 'filter' then
    local status = tostring(payload.status or 'active')
    if status ~= 'active' and status ~= 'closed' and status ~= 'all' then status = 'active' end
    activeFilter = {
      status = status,
      categoryCode = tostring(payload.categoryCode or ''),
      priorityLevel = tostring(payload.priorityLevel or ''),
      page = math.max(1, math.floor(tonumber(payload.page) or 1))
    }
    requestList()
  elseif action == 'accept' or action == 'close' then
    request(action, { callId = tostring(payload.callId or '') })
  elseif action == 'panic' then
    if activeService == 'police' then request('panic', {}) end
  elseif action == 'waypoint' then
    local x, y = tonumber(payload.x), tonumber(payload.y)
    if x and y and x == x and y == y and math.abs(x) <= 20000 and math.abs(y) <= 20000 then
      SetNewWaypoint(x, y)
      notify('Destino do chamado marcado no mapa.', 'success')
    end
  else
    cb({ ok = false, code = 'invalid_action' })
    return
  end
  cb({ ok = true })
end)

RegisterNetEvent('mz_dispatch:client:assignment', function(call)
  call = type(call) == 'table' and call or {}
  local callId = tostring(call.public_id or '')
  local x, y, z = tonumber(call.location_x), tonumber(call.location_y), tonumber(call.location_z)
  if callId == '' or not x or not y or not z then return end
  remove(callId)
  local blip = AddBlipForCoord(x, y, z)
  SetBlipSprite(blip, 280)
  SetBlipColour(blip, call.service_code == 'police' and 3 or 1)
  SetBlipScale(blip, 0.9)
  SetBlipAsShortRange(blip, false)
  BeginTextCommandSetBlipName('STRING')
  AddTextComponentString('Chamado em atendimento')
  EndTextCommandSetBlipName(blip)
  blips[callId] = blip
  local ttl = math.max(1, math.floor(tonumber(MZDispatchConfig.blipTtlSeconds) or 300)) * 1000
  SetTimeout(ttl, function() remove(callId) end)
end)

RegisterNetEvent('mz_dispatch:client:newCall', function(call)
  if type(call) ~= 'table' then return end
  showCallFallback(call)
  if MZDispatchConfig.sounds and MZDispatchConfig.sounds.enabled == true then
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)
  end
  if panelOpen and activeService == call.service_code then requestList() end
end)

RegisterNetEvent('mz_dispatch:client:callUpdated', function(payload)
  payload = type(payload) == 'table' and payload or {}
  if tostring(payload.status or '') == 'closed' then remove(payload.callId) end
  if panelOpen then requestList() end
end)

RegisterNetEvent('mz_dispatch:client:accessRevoked', function()
  clearBlips()
  if panelOpen then ui({ action = 'accessRevoked' }) end
end)

RegisterNetEvent('mz_dispatch:client:closed', function(callId)
  remove(callId)
  if panelOpen then requestList() end
end)

RegisterNetEvent('mz_dispatch:client:response', function(payload)
  payload = type(payload) == 'table' and payload or {}
  if not tostring(payload.requestId or ''):match('^dispatch_nui_') then return end
  local response = type(payload.response) == 'table' and payload.response
    or { ok = false, code = 'invalid_response' }
  if response.ok ~= true then
    if response.code == 'duty_required' or response.code == 'capability_denied'
      or response.code == 'organization_not_found' or response.code == 'character_not_active' then
      clearBlips()
      if panelOpen then ui({ action = 'accessRevoked' }) end
    end
    ui({ action = 'error', code = tostring(response.code or 'unknown') })
    return
  end
  if payload.action == 'list' then
    ui({
      action = 'calls',
      serviceCode = activeService,
      items = response.items or {},
      page = response.page or 1,
      pageSize = response.pageSize or MZDispatchConfig.pageSize or 25,
      total = response.total or 0
    })
    return
  end
  if payload.action == 'accept' or payload.action == 'close' or payload.action == 'panic' then
    local message = payload.action == 'panic' and 'Alerta de pânico enviado à fila policial.'
      or payload.action == 'accept' and 'Chamado aceito.'
      or 'Chamado encerrado.'
    notify(message, 'success')
    if payload.action ~= 'panic' and panelOpen then requestList() end
  end
end)

RegisterCommand('mz_dispatch', function()
  openPanel()
end, false)

RegisterKeyMapping('mz_dispatch', 'Abrir central de emergências', 'keyboard', 'F10')

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  closePanel()
  clearBlips()
end)
