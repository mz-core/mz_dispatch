MZDispatch = MZDispatch or {}

local Repository = {}

local function encode(value)
  local ok, result = pcall(json.encode, value or {})
  return ok and result or '{}'
end

local function transaction(statements)
  local ok, result = pcall(MySQL.transaction.await, statements)
  return ok == true and result == true
end

function Repository.getActiveByCaller(citizenid, serviceCode)
  return MySQL.single.await([[SELECT * FROM mz_dispatch_calls
    WHERE caller_citizenid = ? AND service_code = ? AND status IN ('open', 'accepted')
    ORDER BY created_at DESC LIMIT 1]], { citizenid, serviceCode })
end

function Repository.get(publicId)
  local call = MySQL.single.await('SELECT * FROM mz_dispatch_calls WHERE public_id = ? LIMIT 1', { publicId })
  if not call then return nil end
  call.assignments = MySQL.query.await([[SELECT responder_citizenid, org_code, assigned_at
    FROM mz_dispatch_assignments WHERE call_public_id = ? ORDER BY assigned_at ASC]], { publicId }) or {}
  call.history = MySQL.query.await([[SELECT action, actor_citizenid, details_json, created_at
    FROM mz_dispatch_history WHERE call_public_id = ? ORDER BY id ASC LIMIT 200]], { publicId }) or {}
  return call
end

function Repository.create(data)
  return transaction({
    {
      query = [[INSERT INTO mz_dispatch_calls
        (public_id, service_code, org_code, caller_citizenid, caller_session_id, message,
         category_code, priority_level, source_type, report_count, location_accuracy,
         status, location_x, location_y, location_z, routing_bucket)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 'open', ?, ?, ?, ?)]],
      parameters = {
        data.publicId, data.serviceCode, data.orgCode, data.callerCitizenid, data.callerSessionId,
        data.message, data.categoryCode, data.priorityLevel, data.sourceType, data.locationAccuracy,
        data.location.x, data.location.y, data.location.z, data.location.routingBucket
      }
    },
    {
      query = [[INSERT INTO mz_dispatch_history
        (operation_id, call_public_id, action, actor_citizenid, details_json)
        VALUES (?, ?, 'created', ?, ?)]],
      parameters = {
        data.operationId, data.publicId, data.historyActorCitizenid or data.callerCitizenid, encode(data.details)
      }
    }
  })
end

function Repository.findRecentSensor(serviceCode, categoryCode, routingBucket, location, radius, windowSeconds)
  return MySQL.single.await([[SELECT public_id FROM mz_dispatch_calls
    WHERE service_code = ? AND category_code = ? AND source_type = 'sensor'
      AND status IN ('open', 'accepted') AND routing_bucket = ?
      AND created_at >= DATE_SUB(CURRENT_TIMESTAMP, INTERVAL ? SECOND)
      AND location_x BETWEEN ? AND ? AND location_y BETWEEN ? AND ?
      AND POW(location_x - ?, 2) + POW(location_y - ?, 2) <= POW(?, 2)
    ORDER BY created_at DESC LIMIT 1]], {
    serviceCode, categoryCode, routingBucket, windowSeconds,
    location.x - radius, location.x + radius, location.y - radius, location.y + radius,
    location.x, location.y, radius
  })
end

function Repository.incrementSensorReport(publicId)
  local changed = MySQL.update.await([[UPDATE mz_dispatch_calls
    SET report_count = LEAST(report_count + 1, 65535)
    WHERE public_id = ? AND source_type = 'sensor' AND status IN ('open', 'accepted')]], { publicId })
  return (tonumber(changed) or 0) > 0
end

function Repository.list(serviceCode, page, pageSize, filters)
  page, pageSize = math.max(1, math.floor(tonumber(page) or 1)), math.max(1, math.floor(tonumber(pageSize) or 25))
  local offset = (page - 1) * pageSize
  filters = type(filters) == 'table' and filters or {}
  local where = { 'c.service_code = ?' }
  local parameters = { serviceCode }
  if filters.status == 'active' then
    where[#where + 1] = "c.status IN ('open', 'accepted')"
  elseif filters.status == 'open' or filters.status == 'accepted' or filters.status == 'closed' then
    where[#where + 1] = 'c.status = ?'
    parameters[#parameters + 1] = filters.status
  elseif filters.status ~= 'all' then
    where[#where + 1] = "c.status IN ('open', 'accepted')"
  end
  if filters.categoryCode then
    where[#where + 1] = 'c.category_code = ?'
    parameters[#parameters + 1] = filters.categoryCode
  end
  if filters.priorityLevel then
    where[#where + 1] = 'c.priority_level = ?'
    parameters[#parameters + 1] = filters.priorityLevel
  end
  local whereSql = table.concat(where, ' AND ')
  parameters[#parameters + 1] = pageSize
  parameters[#parameters + 1] = offset
  local rows = MySQL.query.await(([[SELECT c.public_id, c.service_code, c.org_code, c.message, c.status,
    c.category_code, c.priority_level, c.source_type, c.report_count, c.location_accuracy,
    c.location_x, c.location_y, c.location_z, c.routing_bucket, c.created_at, c.updated_at,
    COUNT(a.id) AS assigned_units
    FROM mz_dispatch_calls c LEFT JOIN mz_dispatch_assignments a ON a.call_public_id = c.public_id
    WHERE %s
    GROUP BY c.id ORDER BY c.created_at DESC LIMIT ? OFFSET ?]]):format(whereSql), parameters) or {}
  local countParameters = {}
  for index, value in ipairs(parameters) do
    if index <= #parameters - 2 then countParameters[#countParameters + 1] = value end
  end
  local total = MySQL.scalar.await(('SELECT COUNT(*) FROM mz_dispatch_calls c WHERE %s'):format(whereSql),
    countParameters) or 0
  return { items = rows, page = page, pageSize = pageSize, total = tonumber(total) or 0 }
end

function Repository.isAssigned(publicId, citizenid)
  return (tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM mz_dispatch_assignments
    WHERE call_public_id = ? AND responder_citizenid = ?]], { publicId, citizenid })) or 0) > 0
end

function Repository.assign(call, responder, operationId)
  return transaction({
    {
      query = [[INSERT IGNORE INTO mz_dispatch_assignments
        (call_public_id, responder_citizenid, responder_session_id, org_code)
        VALUES (?, ?, ?, ?)]],
      parameters = { call.public_id, responder.citizenid, responder.sessionId, call.org_code }
    },
    {
      query = [[UPDATE mz_dispatch_calls SET status = 'accepted', revision = revision + 1
        WHERE public_id = ? AND status IN ('open', 'accepted')]],
      parameters = { call.public_id }
    },
    {
      query = [[INSERT INTO mz_dispatch_history
        (operation_id, call_public_id, action, actor_citizenid, details_json)
        VALUES (?, ?, 'unit_assigned', ?, ?)]],
      parameters = { operationId, call.public_id, responder.citizenid, encode({ orgCode = call.org_code }) }
    }
  })
end

function Repository.close(call, responder, operationId)
  local committed = transaction({
    {
      query = [[UPDATE mz_dispatch_calls SET status = 'closed', closed_at = CURRENT_TIMESTAMP,
        closed_by_citizenid = ?, revision = revision + 1
        WHERE public_id = ? AND status IN ('open', 'accepted')]],
      parameters = { responder.citizenid, call.public_id }
    },
    {
      query = [[INSERT INTO mz_dispatch_history
        (operation_id, call_public_id, action, actor_citizenid, details_json)
        SELECT ?, public_id, 'closed', ?, ? FROM mz_dispatch_calls
        WHERE public_id = ? AND status = 'closed' AND closed_by_citizenid = ?]],
      parameters = { operationId, responder.citizenid, '{}', call.public_id, responder.citizenid }
    }
  })
  if not committed then return false end
  local owner = MySQL.scalar.await('SELECT closed_by_citizenid FROM mz_dispatch_calls WHERE public_id = ?', {
    call.public_id
  })
  return tostring(owner or '') == tostring(responder.citizenid)
end

MZDispatch.Repository = Repository
