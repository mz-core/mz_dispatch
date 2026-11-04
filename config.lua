MZDispatchConfig = {
  -- Staging P8: habilitado. No boot, server/prepare.lua aguarda o MySQL, cria as tabelas
  -- ausentes a partir de sql/mz_dispatch.sql, evolui somente o schema legado conhecido
  -- de classificacao e valida a estrutura. Qualquer outra divergencia fica fail-closed.
  enabled = true,

  -- Logs discretos de fluxo (sem mensagem/conteudo sensivel). Ativar apenas em diagnostico.
  debug = false,

  messageMaximumLength = 280,
  pageSize = 25,
  maximumPageSize = 50,
  rateLimit = { maximum = 3, windowSeconds = 60 },
  requestRateLimit = { maximum = 30, windowSeconds = 10 },
  blipTtlSeconds = 300,
  sounds = { enabled = false },
  sensors = {
    enabled = false,
    sourceCooldownSeconds = 15,
    aggregationWindowSeconds = 60,
    aggregationRadius = 100.0
  },

  -- Org, duty e capability continuam pertencendo ao mz_org.
  services = {
    police = {
      orgCode = 'police',
      capability = 'mdt.open'
    },
    medical = {
      orgCode = 'ambulance',
      capability = 'ambulance.tablet.open'
    }
  },

  priorities = {
    [1] = 'Crítica',
    [2] = 'Alta',
    [3] = 'Normal',
    [4] = 'Baixa',
    [5] = 'Informativa'
  },

  defaultIncidentTypes = {
    police = 'general',
    medical = 'medical'
  },

  incidentTypes = {
    police = {
      { code = 'general', label = 'Ocorrência policial', priority = 3 },
      { code = 'gunshots', label = 'Disparos informados', priority = 2 },
      { code = 'fight', label = 'Briga informada', priority = 2 },
      { code = 'panic', label = 'Botão de pânico', priority = 1, internalOnly = true }
    },
    medical = {
      { code = 'medical', label = 'Emergência médica', priority = 2 }
    }
  }
}
