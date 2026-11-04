# mz_dispatch

Owner server-side de chamados compartilhados do MZ Framework.

- identidade: `mz_core`;
- organização, duty e capabilities: `mz_org`;
- fila, atribuições e histórico: `mz_dispatch`;
- notificações: `mz_notify` quando disponível;
- apresentação operacional: NUI local do `mz_dispatch`, usando tokens MZ de `mz_frontend`;
- notificações passivas: `mz_notify`, com fallback em `mz_menu`;
- produtores: app Emergência do `mz_phone` e pedido de ajuda do `mz_medical`;
- consumidores: MDT do `mz_police` e `/mz_dispatch` para responders autorizados.

O comando `/mz_dispatch` e a tecla F10 abrem o painel próprio, sem substituir o MDT nem os pedidos
originados pelo telefone. A tela mostra fila, histórico, filtros de estado/categoria/prioridade,
localização, horário, prioridade persistida, quantidade de unidades e ações GPS/aceite/encerramento.
O foco é capturado apenas enquanto o painel está aberto; toasts passivos não usam foco.

O alerta passivo de novo chamado usa `mz_notify` uma única vez e inclui serviço, relato e coordenadas
do servidor; se `mz_notify` estiver ausente, o cliente usa o toast passivo já existente em `mz_menu`.
Os eventos de transporte omitem identidade do solicitante, sessões, histórico e atribuições detalhadas.
Unidades são exibidas por posição no chamado ("Unidade 01"), sem expor citizenid. O MZ atualmente não
fornece um contrato público de callsign a este recurso.

Categorias e prioridades são definidas em `MZDispatchConfig.incidentTypes`; a prioridade é resolvida no
servidor e não é aceita do cliente. Chamadas antigas e produtores existentes continuam compatíveis
por meio das categorias padrão por serviço. O sensor opcional usa somente `weaponDamageEvent`, lê a
posição do jogador pelo servidor, aplica cooldown por jogador/categoria e agrega sinais próximos no
mesmo routing bucket. Os relatos são marcados como não verificados e não identificam o emissor como
solicitante. O sensor fica desativado por padrão e não detecta tiros sem impacto nem testemunhas NPCs.

Com `MZDispatchConfig.enabled = true`, `server/prepare.lua` aguarda o MySQL, cria as tabelas
ausentes a partir de `sql/mz_dispatch.sql` (`CREATE TABLE IF NOT EXISTS`) e valida colunas,
índices e foreign keys. Em banco saudável o schema é validado e reutilizado sem DDL. Bancos do
dispatch anteriores à classificação recebem no boot somente as cinco colunas aditivas conhecidas;
qualquer outra divergência permanece fail-closed (`dispatch_unavailable`). A migration versionada
`sql/migrations/001_call_classification.sql` continua disponível como fallback manual. Antes de
habilitar o sensor, aplicar também
`sql/migrations/002_server_sensor_calls.sql`, que permite chamados sem solicitante jogador e adiciona
o índice de agrupamento. O bootstrap não executa outras migrations nem corrige schemas desconhecidos.

Não há coordenada configurável no dispatch: a posição do solicitante é lida do ped server-side no
momento da criação.

O MDT do `mz_police` continua consultando a fila pelo contrato `ListCalls`; campos existentes do
snapshot são preservados. O payload de lista pode filtrar por `status`, `categoryCode` e
`priorityLevel`, além de `serviceCode`, `page` e `pageSize`. `requestId` pertence ao envelope e é
exigido apenas nas mutações (`create`, `accept`, `close`).
`mz_dispatch:client:newCall` e `mz_dispatch:client:callUpdated` invalidam a lista do MDT; o toast de
novo chamado continua sendo emitido uma única vez pelo owner via `mz_notify`.

Roteiro manual com dois policiais: `docs/VALIDACAO_MDT_P8.md`.

## Estado das integrações

**Concluído nesta etapa**
- NUI própria com histórico, filtros, loading/empty/error, paginação e ações GPS/aceite/encerramento.
- Classificação persistente com categorias configuráveis e prioridades 1-5 calculadas no servidor.
- Migration manual versionada para bancos existentes, sem execução automática.
- Notificação sonora configurável, desativada por padrão.
- Botão de pânico no MDT policial, autorizado no `mz_police` e delegado ao owner `mz_dispatch`, com
  cooldown por identidade e categoria interna P1.
- Sensor server-side de dano por arma para sinais potenciais de disparo/briga, com cooldown e
  agrupamento espacial/temporal; permanece desativado até validação em staging/runtime.
- Remoção periódica de blips e snapshot local quando uma unidade atribuída perde autorização; eventos
  de encerramento também removem blips dos consumidores autorizados.

**Pendente**
- Testemunhas NPCs e tiros sem impacto: não há sinal server-side confiável para afirmar esses eventos.
- Consulta veicular no local da ocorrência: o contrato atual de `mz_vehicles` restringe suas consultas
  policiais ao chamador `mz_police`; será necessária uma integração autorizada nesse owner.
- Contato telefônico: `mz_phone` não expõe contrato público confirmado para buscar o número do solicitante
  ou iniciar chamada de saída por citizenid.
- Callsigns públicos das unidades; a revogação de blips tem janela máxima aproximada de 10 segundos.

**Runtime FiveM: PENDENTE.** Não foi executado em servidor de jogo.
