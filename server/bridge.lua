MZDispatch = MZDispatch or {}

local Bridge = {}

local function call(resourceName, exportName, ...)
  if GetResourceState(resourceName) ~= 'started' then
    return nil, resourceName == 'mz_core' and 'core_unavailable' or 'organization_unavailable'
  end
  local proxy = exports[resourceName]
  local fn = proxy and proxy[exportName]
  if type(fn) ~= 'function' then return nil, 'contract_unavailable' end
  local args = table.pack(...)
  local result = table.pack(pcall(function()
    return fn(proxy, table.unpack(args, 1, args.n))
  end))
  if result[1] ~= true then return nil, 'contract_failed' end
  return table.unpack(result, 2, result.n)
end

function Bridge.resolveIdentity(source)
  source = tonumber(source)
  if not source or source <= 0 then return nil, 'invalid_source' end
  local result, err = call('mz_core', 'ResolvePlayerIdentity', source)
  if type(result) ~= 'table' or result.ok ~= true then
    return nil, type(result) == 'table' and tostring(result.error or 'identity_unavailable')
      or err or 'identity_unavailable'
  end
  local identity = {
    source = tonumber(result.source),
    accountId = tonumber(result.accountId or result.account_id),
    characterId = tonumber(result.characterId or result.character_id),
    sessionId = tonumber(result.sessionId or result.session_id),
    citizenid = tostring(result.citizenid or ''),
    active = result.active == true
  }
  if identity.source ~= source or not identity.accountId or not identity.characterId
    or not identity.sessionId or identity.citizenid == '' then
    return nil, 'identity_inconsistent'
  end
  if identity.active ~= true then return nil, 'character_not_active' end
  return identity
end

function Bridge.authorizeResponder(source, serviceCode)
  local service = MZDispatchConfig.services[tostring(serviceCode or '')]
  if type(service) ~= 'table' then return nil, 'service_not_configured' end
  local identity, identityError = Bridge.resolveIdentity(source)
  if not identity then return nil, identityError end

  local readiness, readinessError = call('mz_org', 'GetOrganizationReadiness')
  if type(readiness) ~= 'table' or readiness.ready ~= true then
    return nil, readinessError or 'organization_not_ready'
  end
  local organizations, organizationsError = call('mz_org', 'GetPlayerOrgContext', source)
  if type(organizations) ~= 'table' then return nil, organizationsError or 'organization_unavailable' end

  local capabilityDenied, dutyDenied = false, false
  for _, organization in ipairs(organizations) do
    local code = tostring(organization.code or organization.orgCode or organization.org_code or '')
    local active = organization.active == true
      and (organization.status == nil or tostring(organization.status):lower() == 'active')
    if code == service.orgCode and active then
      local allowed, permissionError = call('mz_org', 'CanOrg', source, service.orgCode, service.capability)
      if allowed == nil then return nil, permissionError or 'organization_unavailable' end
      if allowed ~= true then capabilityDenied = true
      elseif organization.duty ~= true then dutyDenied = true
      else
        return {
          identity = identity,
          organization = { code = service.orgCode, id = tonumber(organization.orgId or organization.org_id) },
          service = service
        }
      end
    end
  end
  if dutyDenied then return nil, 'duty_required' end
  if capabilityDenied then return nil, 'capability_denied' end
  return nil, 'organization_not_found'
end

function Bridge.getLocation(source)
  local ped = GetPlayerPed(source)
  if not ped or ped <= 0 then return nil, 'location_unavailable' end
  local coords = GetEntityCoords(ped)
  if not coords then return nil, 'location_unavailable' end
  local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
  if not x or not y or not z then return nil, 'location_unavailable' end
  return { x = x, y = y, z = z, routingBucket = tonumber(GetPlayerRoutingBucket(source)) or 0 }
end

function Bridge.getSourceByCitizenId(citizenid)
  local value = call('mz_core', 'GetSourceByCitizenId', citizenid)
  value = tonumber(value)
  return value and value > 0 and value or nil
end

function Bridge.notify(source, data)
  source = tonumber(source)
  if not source then return end
  if GetResourceState('mz_notify') == 'started' then
    pcall(function() exports['mz_notify']:Notify(source, data) end)
  end
end

function Bridge.audit(action, payload)
  pcall(function()
    call('mz_core', 'CreateDetailedLog', 'dispatch', action, payload or {})
  end)
end

MZDispatch.Bridge = Bridge
