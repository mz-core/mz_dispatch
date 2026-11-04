MZDispatch = MZDispatch or {}

-- Bootstrap do schema do mz_dispatch.
--
-- Fonte unica de DDL: sql/mz_dispatch.sql (lido do proprio resource em runtime).
-- Este arquivo NAO contem uma segunda definicao de schema: apenas o contrato
-- minimo usado para validar a estrutura criada/reutilizada.
--
-- Garantias:
--  - CREATE TABLE IF NOT EXISTS e uma unica evolucao aditiva conhecida do schema legado;
--  - banco saudavel nao recebe DDL (valida primeiro e reutiliza);
--  - qualquer outra estrutura incompativel falha fechado;
--  - o servico so responde depois de Prepare.ready == true.

local Prepare = {
  ready = false,
  state = 'idle', -- idle | waiting | running | ready | failed | disabled
  error = nil
}

local SQL_FILE = 'sql/mz_dispatch.sql'
local TABLES = { 'mz_dispatch_calls', 'mz_dispatch_assignments', 'mz_dispatch_history' }
local WAIT_ATTEMPTS = 120
local WAIT_INTERVAL_MS = 500

-- Contrato de validacao (nao e DDL). Os tipos sao familias para aceitar
-- variantes compativeis (ex.: TIMESTAMP/DATETIME) sem aceitar estrutura
-- incompativel. Tamanhos minimos protegem os IDs e a mensagem usados pelo servico.
local CONTRACT = {
  {
    name = 'mz_dispatch_calls',
    columns = {
      id = 'integer',
      public_id = 'text',
      service_code = 'text',
      org_code = 'text',
      caller_citizenid = 'text',
      caller_session_id = 'integer',
      message = 'text',
      category_code = 'text',
      priority_level = 'integer',
      source_type = 'text',
      report_count = 'integer',
      location_accuracy = 'text',
      status = 'enum',
      location_x = 'decimal',
      location_y = 'decimal',
      location_z = 'decimal',
      routing_bucket = 'integer',
      closed_by_citizenid = 'text',
      closed_at = 'temporal',
      revision = 'integer',
      created_at = 'temporal',
      updated_at = 'temporal'
    },
    minimumLength = { public_id = 160, message = 280 },
    unique = { { 'public_id' } },
    foreign = {}
  },
  {
    name = 'mz_dispatch_assignments',
    columns = {
      id = 'integer',
      call_public_id = 'text',
      responder_citizenid = 'text',
      responder_session_id = 'integer',
      org_code = 'text',
      assigned_at = 'temporal'
    },
    minimumLength = { call_public_id = 160 },
    unique = { { 'call_public_id', 'responder_citizenid' } },
    foreign = {
      { column = 'call_public_id', refTable = 'mz_dispatch_calls', refColumn = 'public_id' }
    }
  },
  {
    name = 'mz_dispatch_history',
    columns = {
      id = 'integer',
      operation_id = 'text',
      call_public_id = 'text',
      action = 'text',
      actor_citizenid = 'text',
      details_json = 'text',
      created_at = 'temporal'
    },
    minimumLength = { operation_id = 180, call_public_id = 160 },
    unique = { { 'operation_id' } },
    foreign = {
      { column = 'call_public_id', refTable = 'mz_dispatch_calls', refColumn = 'public_id' }
    }
  }
}

local VALID_TYPES = {
  integer = { tinyint = true, smallint = true, mediumint = true, int = true, bigint = true },
  decimal = { decimal = true, numeric = true, float = true, double = true },
  text = { char = true, varchar = true, tinytext = true, text = true, mediumtext = true, longtext = true },
  temporal = { timestamp = true, datetime = true },
  enum = { enum = true }
}

local LEGACY_CLASSIFICATION_COLUMNS = {
  { name = 'category_code', ddl = "category_code VARCHAR(32) NOT NULL DEFAULT 'general'" },
  { name = 'priority_level', ddl = 'priority_level TINYINT UNSIGNED NOT NULL DEFAULT 3' },
  { name = 'source_type', ddl = "source_type VARCHAR(24) NOT NULL DEFAULT 'manual'" },
  { name = 'report_count', ddl = 'report_count SMALLINT UNSIGNED NOT NULL DEFAULT 1' },
  { name = 'location_accuracy', ddl = "location_accuracy VARCHAR(16) NOT NULL DEFAULT 'exact'" }
}

local LEGACY_CLASSIFICATION_NAMES = {}
for _, definition in ipairs(LEGACY_CLASSIFICATION_COLUMNS) do
  LEGACY_CLASSIFICATION_NAMES[definition.name] = true
end

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function sanitize(value)
  local message = tostring(value or ''):gsub('[\r\n]+', ' ')
  if #message > 320 then message = message:sub(1, 320) .. '...' end
  return message
end

local function log(message)
  print(('[mz_dispatch] %s'):format(tostring(message)))
end

local function enabled()
  return MZDispatchConfig ~= nil and MZDispatchConfig.enabled == true
end

local function mysqlApi()
  return type(MySQL) == 'table'
    and type(MySQL.query) == 'table'
    and type(MySQL.query.await) == 'function'
end

local function connectionReady()
  if not mysqlApi() then return false, 'mysql_client_unavailable' end
  local ok, result = pcall(function() return MySQL.query.await('SELECT 1 AS ok') end)
  if ok ~= true then return false, sanitize(result) end
  if type(result) ~= 'table' or #result == 0 then return false, 'mysql_probe_empty' end
  return true
end

local function splitStatements(source)
  local text = tostring(source or ''):gsub('\r\n', '\n')
  text = text:gsub('%-%-[^\n]*', '')
  local statements = {}
  for chunk in text:gmatch('([^;]+)') do
    local statement = trim(chunk)
    if statement ~= '' then statements[#statements + 1] = statement end
  end
  return statements
end

local function loadSqlSource()
  local resourceName = type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() or nil
  if not resourceName then return nil, 'resource_name_unavailable' end
  if type(LoadResourceFile) ~= 'function' then return nil, 'load_resource_file_unavailable' end
  local ok, source = pcall(LoadResourceFile, resourceName, SQL_FILE)
  if ok ~= true then return nil, sanitize(source) end
  if type(source) ~= 'string' or trim(source) == '' then return nil, 'sql_file_unavailable:' .. SQL_FILE end
  return source
end

local function executeStatements(statements)
  for index, statement in ipairs(statements) do
    local upper = trim(statement):upper()
    if not upper:match('^CREATE TABLE IF NOT EXISTS ') then
      return false, ('unsafe_statement:%d:only_create_if_not_exists'):format(index)
    end
    local ok, err = pcall(function() return MySQL.query.await(statement) end)
    if ok ~= true then
      local tableName = statement:match('CREATE%s+TABLE%s+IF%s+NOT%s+EXISTS%s+([%w_]+)')
        or ('statement_%d'):format(index)
      local message = sanitize(err)
      local hint = ''
      local lower = message:lower()
      if lower:find('denied', 1, true) or lower:find('permission', 1, true) then
        hint = ' | required: CREATE and REFERENCES on the server database '
          .. '(or apply sql/mz_dispatch.sql manually)'
      end
      return false, ('create_failed:%s:%s%s'):format(tableName, message, hint)
    end
  end
  return true
end

local function fetchColumns()
  local rows = MySQL.query.await([[SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, CHARACTER_MAXIMUM_LENGTH
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (?, ?, ?)]],
    { TABLES[1], TABLES[2], TABLES[3] }) or {}
  local out = {}
  for _, row in ipairs(rows) do
    local tableName = tostring(row.TABLE_NAME or row.table_name or '')
    local columnName = tostring(row.COLUMN_NAME or row.column_name or '')
    if tableName ~= '' and columnName ~= '' then
      out[tableName] = out[tableName] or {}
      out[tableName][columnName] = {
        dataType = tostring(row.DATA_TYPE or row.data_type or ''):lower(),
        columnType = tostring(row.COLUMN_TYPE or row.column_type or ''):lower(),
        maxLength = tonumber(row.CHARACTER_MAXIMUM_LENGTH or row.character_maximum_length) or 0
      }
    end
  end
  return out
end

local function fetchUniqueIndexes()
  local rows = MySQL.query.await([[SELECT TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX, COLUMN_NAME
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (?, ?, ?) AND NON_UNIQUE = 0
    ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX]],
    { TABLES[1], TABLES[2], TABLES[3] }) or {}
  local grouped = {}
  for _, row in ipairs(rows) do
    local tableName = tostring(row.TABLE_NAME or row.table_name or '')
    local indexName = tostring(row.INDEX_NAME or row.index_name or '')
    local columnName = tostring(row.COLUMN_NAME or row.column_name or '')
    local position = tonumber(row.SEQ_IN_INDEX or row.seq_in_index)
    if tableName ~= '' and indexName ~= '' and indexName ~= 'PRIMARY'
      and columnName ~= '' and position then
      grouped[tableName] = grouped[tableName] or {}
      grouped[tableName][indexName] = grouped[tableName][indexName] or {}
      grouped[tableName][indexName][position] = columnName
    end
  end
  local sets = {}
  for tableName, indexes in pairs(grouped) do
    sets[tableName] = {}
    for _, columnsByPosition in pairs(indexes) do
      local ordered = {}
      for position = 1, #columnsByPosition do
        ordered[#ordered + 1] = columnsByPosition[position]
      end
      if #ordered > 0 then sets[tableName][table.concat(ordered, ',')] = true end
    end
  end
  return sets
end

local function fetchForeignKeys()
  local rows = MySQL.query.await([[SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (?, ?, ?)
      AND REFERENCED_TABLE_NAME IS NOT NULL]],
    { TABLES[1], TABLES[2], TABLES[3] }) or {}
  local out = {}
  for _, row in ipairs(rows) do
    local tableName = tostring(row.TABLE_NAME or row.table_name or '')
    local columnName = tostring(row.COLUMN_NAME or row.column_name or '')
    if tableName ~= '' and columnName ~= '' then
      out[tableName] = out[tableName] or {}
      out[tableName][columnName] = {
        refTable = tostring(row.REFERENCED_TABLE_NAME or row.referenced_table_name or ''),
        refColumn = tostring(row.REFERENCED_COLUMN_NAME or row.referenced_column_name or '')
      }
    end
  end
  return out
end

local function columnCompatible(kind, column)
  if kind == 'enum' then
    return column.dataType == 'enum' or VALID_TYPES.text[column.dataType] == true
  end
  local family = VALID_TYPES[kind]
  return family ~= nil and family[column.dataType] == true
end

local function validateSchema()
  local columns = fetchColumns()
  local unique = fetchUniqueIndexes()
  local foreign = fetchForeignKeys()
  local problems = {}

  for _, definition in ipairs(CONTRACT) do
    local tableColumns = columns[definition.name]
    if not tableColumns or next(tableColumns) == nil then
      problems[#problems + 1] = ('%s:missing'):format(definition.name)
    else
      for columnName, kind in pairs(definition.columns) do
        local column = tableColumns[columnName]
        if not column then
          problems[#problems + 1] = ('%s.%s:missing'):format(definition.name, columnName)
        elseif not columnCompatible(kind, column) then
          problems[#problems + 1] = ('%s.%s:type=%s'):format(
            definition.name, columnName, tostring(column.dataType))
        elseif kind == 'enum' and column.dataType == 'enum' then
          local columnType = tostring(column.columnType or ''):lower()
          if not (columnType:find("'open'", 1, true) and columnType:find("'accepted'", 1, true)
            and columnType:find("'closed'", 1, true)) then
            problems[#problems + 1] = ('%s.%s:enum_values'):format(definition.name, columnName)
          end
        end
      end
      for columnName, minimum in pairs(definition.minimumLength or {}) do
        local column = tableColumns[columnName]
        if column and column.maxLength > 0 and column.maxLength < minimum then
          problems[#problems + 1] = ('%s.%s:length=%d<%d'):format(
            definition.name, columnName, column.maxLength, minimum)
        end
      end
      local uniqueSets = unique[definition.name] or {}
      for _, expected in ipairs(definition.unique or {}) do
        local key = table.concat(expected, ',')
        if uniqueSets[key] ~= true then
          problems[#problems + 1] = ('%s:unique(%s)'):format(definition.name, key)
        end
      end
      local foreignByColumn = foreign[definition.name] or {}
      for _, expected in ipairs(definition.foreign or {}) do
        local actual = foreignByColumn[expected.column]
        if not actual or actual.refTable ~= expected.refTable or actual.refColumn ~= expected.refColumn then
          problems[#problems + 1] = ('%s:fk(%s->%s.%s)'):format(
            definition.name, expected.column, expected.refTable, expected.refColumn)
        end
      end
    end
  end

  return #problems == 0, problems
end

local function validateSafe()
  local ok, valid, problems = pcall(validateSchema)
  if ok ~= true then return false, { fatal = true, error = sanitize(valid) } end
  return valid, problems
end

local function upgradeLegacyClassification(problems)
  if type(problems) ~= 'table' or #problems == 0 then return false end

  local missing = {}
  for _, problem in ipairs(problems) do
    local columnName = tostring(problem):match('^mz_dispatch_calls%.([%w_]+):missing$')
    if not columnName or LEGACY_CLASSIFICATION_NAMES[columnName] ~= true then return false end
    missing[columnName] = true
  end

  local clauses = {}
  for _, definition in ipairs(LEGACY_CLASSIFICATION_COLUMNS) do
    if missing[definition.name] then clauses[#clauses + 1] = 'ADD COLUMN ' .. definition.ddl end
  end
  if #clauses == 0 then return false end

  log('known legacy classification schema detected; applying additive upgrade')
  local ok, errorValue = pcall(function()
    return MySQL.query.await('ALTER TABLE mz_dispatch_calls\n  ' .. table.concat(clauses, ',\n  '))
  end)
  if ok ~= true then
    return nil, 'legacy_upgrade_failed:' .. sanitize(errorValue)
  end
  return true
end

local function prepareSchema()
  log('schema initialization started')

  -- Banco saudavel: nao executa DDL, apenas valida e reutiliza.
  local valid, problems = validateSafe()
  if valid == true then
    log('schema validated')
    return true
  end
  if type(problems) == 'table' and problems.fatal then
    return false, 'validation_failed:' .. sanitize(problems.error)
  end

  local source, sourceError = loadSqlSource()
  if not source then return false, sourceError end
  local statements = splitStatements(source)
  if #statements == 0 then return false, 'sql_file_empty:' .. SQL_FILE end

  local executed, executeError = executeStatements(statements)
  if not executed then return false, executeError end

  local validAfter, problemsAfter = validateSafe()
  if validAfter ~= true and type(problemsAfter) == 'table' and problemsAfter.fatal ~= true then
    local upgraded, upgradeError = upgradeLegacyClassification(problemsAfter)
    if upgraded == nil then return false, upgradeError end
    if upgraded == true then
      validAfter, problemsAfter = validateSafe()
    end
  end
  if validAfter ~= true then
    local detail
    if type(problemsAfter) == 'table' and problemsAfter.fatal then
      detail = problemsAfter.error
    else
      detail = table.concat(problemsAfter or {}, ',')
    end
    return false, 'schema_invalid:' .. sanitize(detail)
  end

  log('schema validated')
  return true
end

local function waitForConnection()
  if not mysqlApi() then return false, 'mysql_client_unavailable' end
  local lastError
  for attempt = 1, WAIT_ATTEMPTS do
    local ok, err = connectionReady()
    if ok == true then return true end
    lastError = err
    if attempt == 1 then log('waiting for database connection') end
    if type(Wait) ~= 'function' then break end
    Wait(WAIT_INTERVAL_MS)
  end
  return false, 'database_connection_timeout:' .. sanitize(lastError or 'unknown')
end

function Prepare.run()
  if Prepare.ready == true then return true end
  if Prepare.state == 'waiting' or Prepare.state == 'running' then
    return false, 'initialization_in_progress'
  end
  if not enabled() then
    Prepare.ready, Prepare.state, Prepare.error = false, 'disabled', 'dispatch_disabled'
    return false, Prepare.error
  end
  if not mysqlApi() then
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', 'mysql_not_ready'
    return false, Prepare.error
  end

  Prepare.state, Prepare.error = 'running', nil
  local ok, result, errorValue = pcall(prepareSchema)
  if ok ~= true then
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', 'schema_exception:' .. sanitize(result)
  elseif result == true then
    Prepare.ready, Prepare.state, Prepare.error = true, 'ready', nil
  else
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', sanitize(errorValue)
  end
  return Prepare.ready, Prepare.error
end

function Prepare.bootstrap()
  if Prepare.ready == true then
    log(('schema_ready=true enabled=%s'):format(tostring(enabled())))
    return true
  end
  if Prepare.state == 'waiting' or Prepare.state == 'running' then
    return false, 'initialization_in_progress'
  end
  if not enabled() then
    Prepare.ready, Prepare.state, Prepare.error = false, 'disabled', 'dispatch_disabled'
    log('disabled by config; schema initialization skipped')
    log(('schema_ready=false enabled=false reason=%s'):format(tostring(Prepare.error)))
    return false, Prepare.error
  end

  Prepare.state = 'waiting'
  local connected, connectionError = waitForConnection()
  Prepare.state = 'idle'
  if not connected then
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', sanitize(connectionError)
    log(('schema initialization failed: %s'):format(Prepare.error))
    log(('schema_ready=false enabled=%s'):format(tostring(enabled())))
    return false, Prepare.error
  end

  log('database connection ready')
  local ready, errorValue = Prepare.run()
  if ready == true then
    log(('schema_ready=true enabled=%s'):format(tostring(enabled())))
    return true
  end
  log(('schema initialization failed: %s'):format(tostring(errorValue)))
  log(('schema_ready=false enabled=%s'):format(tostring(enabled())))
  return false, errorValue
end

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  if type(CreateThread) == 'function' then
    CreateThread(function() Prepare.bootstrap() end)
  else
    Prepare.bootstrap()
  end
end)

MZDispatch.Prepare = Prepare
