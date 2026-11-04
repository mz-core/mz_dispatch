# Contrato público mz_dispatch 1.0.0

Todos os exports recebem um `source` real e repetem identidade, organização, duty e capability no
servidor. Retorno: `{ ok: boolean, code: string, ... }`.

```lua
exports['mz_dispatch']:CreateEmergencyCall(source, {
  serviceCode = 'police',
  categoryCode = 'general', -- opcional; prioridade vem da configuracao server-side
  message = '<mensagem>',
  requestId = '<idempotency-key>'
})

exports['mz_dispatch']:CreateMedicalHelpCall(source, '<idempotency-key>')
-- Contrato exclusivo para chamadas originadas pelo recurso mz_police:
exports['mz_dispatch']:CreatePolicePanicCall(source, '<idempotency-key>')
exports['mz_dispatch']:ListCalls(source, {
  serviceCode = 'police', page = 1, pageSize = 25,
  status = 'active', categoryCode = 'gunshots', priorityLevel = 2
})
exports['mz_dispatch']:AcceptCall(source, { callId = '<public-id>', requestId = '<idempotency-key>' })
exports['mz_dispatch']:CloseCall(source, { callId = '<public-id>', requestId = '<idempotency-key>' })
```

Estados persistidos: `open` → `accepted` → `closed`. Várias unidades podem ser atribuídas; a mesma
unidade não é duplicada. Somente uma unidade atribuída pode encerrar. Coordenadas e routing bucket são
capturados no servidor, nunca aceitos do payload do cliente.

Categorias públicas para cada serviço são configuradas em `MZDispatchConfig.incidentTypes`.
`categoryCode` é opcional para preservar produtores existentes; o servidor escolhe a categoria padrão
do serviço e calcula `priority_level` a partir da configuração. Prioridades aceitas vão de 1 (crítica)
a 5 (informativa). Prioridade enviada pelo cliente não faz parte do contrato.

O snapshot mantém os campos operacionais anteriores e acrescenta `category_code`, `category_label`,
`priority_level`, `priority_label`, `source_type`, `report_count` e `location_accuracy`. Dados
internos do solicitante, sessões e histórico não são incluídos no DTO de fila.

Filtros opcionais de lista:

- `status`: `active` (padrão), `open`, `accepted`, `closed` ou `all`;
- `categoryCode`: categoria configurada para o serviço;
- `priorityLevel`: inteiro de 1 a 5.

O pânico é autorizado no `mz_police` e novamente no `mz_dispatch`, exige duty/capability policial e
aplica cooldown por identidade. O export `CreatePolicePanicCall` recusa qualquer recurso chamador
que não seja `mz_police`; a categoria `panic` não pode ser escolhida por produtores comuns.

O sensor opcional consome o evento server-side `weaponDamageEvent`, consulta a posição e o routing
bucket pelo servidor, impõe cooldown por emissor/categoria e agrupa sinais ativos próximos. Os
chamados são rotulados como não verificados e não armazenam identidade/sessão de jogador como
solicitante. `MZDispatchConfig.sensors.enabled` é `false` por padrão. Como o evento representa dano,
não detecta disparos sem impacto; testemunhas NPCs também não têm evidência server-side implementada.

Em bancos P8 já existentes, o bootstrap aplica somente as cinco colunas aditivas conhecidas de
classificação; `sql/migrations/001_call_classification.sql` permanece como fallback manual. Antes de
habilitar sensores, aplicar `sql/migrations/002_server_sensor_calls.sql`, que permite chamadas sem
solicitante jogador e cria o índice de agrupamento. Validar migrations em staging; qualquer outra
divergência de schema continua falhando fechado.

O evento de transporte NUI valida um envelope fechado, limita `action`/`requestId`, exige que a chave
de idempotência do payload coincida com a do envelope nas mutações e aplica rate limit por sessão.

Criações concorrentes do mesmo cidadão/serviço são serializadas: a segunda requisição do mesmo
intervalo retorna `call_creation_in_progress` em vez de abrir um segundo chamado.

Consultas de snapshot (`list`) usam `{ serviceCode, page, pageSize }` e filtros opcionais no payload. O
`requestId` pertence ao envelope da requisição e **não** ao payload de `list`; enviá-lo faz o owner
responder `invalid_payload`. Em `create`, `accept` e `close` a chave de idempotência aparece nos dois
lugares e precisa coincidir.

Eventos de transporte para consumidores autorizados:

- `mz_dispatch:client:newCall` — chamado recém-criado. É entregue somente a responders autorizados e
  o toast contextual é emitido uma única vez pelo owner via `mz_notify` ou, se indisponível, pelo
  cliente via `mz_menu`. Consumidores não devem emitir um segundo toast. O evento contém somente os campos operacionais públicos do chamado
  (ID, serviço, mensagem, estado, localização, horário e contagem de unidades); identidade do
  solicitante, sessões, histórico e atribuições detalhadas não são transmitidos.
- `mz_dispatch:client:callUpdated` — `{ callId, status }` após aceite/encerramento. É apenas um sinal
  de invalidação: o consumidor reconsulta `ListCalls` e não trata o evento como notificação.
- `mz_dispatch:client:assignment` — confirmação operacional sanitizada para o autor da mutação
  (blip temporário); `mz_dispatch:client:closed` — confirmação de encerramento e remoção local.

A fila da NUI do comando `/mz_dispatch` exibe serviço, categoria, prioridade, estado, horário,
contagem de unidades e coordenadas retornadas pelo servidor. **GPS** marca o waypoint localmente.
A NUI captura foco apenas enquanto aberta e mantém a transparência fora do painel.

Chamadas telefônicas de saída, consulta de veículo no local, testemunhas NPCs e callsigns reais não
fazem parte dos contratos públicos disponíveis nesta etapa. O pânico usa o contrato restrito acima;
o sensor server-side e a agregação de sinais estão implementados, mas desativados por padrão.
