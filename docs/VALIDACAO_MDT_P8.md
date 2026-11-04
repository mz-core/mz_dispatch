# Validação manual P8 — chamado policial + MDT

Roteiro para servidor FiveM real. **Runtime deste ambiente: NOT RUN** (não há FXServer ativo).

## Pré-requisitos

- `mz_core`, `mz_org`, `mz_notify`, `mz_dispatch` e `mz_police` iniciados.
- Schema do dispatch validado (`schema_ready=true`; sem DDL manual).
- 1 cidadão (C) e 2 policiais: A em duty com capability `mdt.open`; B online e fora de duty.
- Opcional para diagnóstico: `MZDispatchConfig.debug = true` em `mz_dispatch/config.lua` e
  `MZPoliceConfig.Dispatch.debug = true` em `mz_police/server/config.lua`.

## Passos e resultado esperado

1. **MDT vazio**
   - A abre o MDT (`mz_police_mdt`) e entra em **Dispatch**.
   - Esperado: fila vazia, sem toast, sem erro `invalid_payload`.
   - Log: `[mz_dispatch] queue_loaded ... items=0`.

2. **Novo chamado**
   - C envia uma solicitação policial pelo app Emergência do telefone.
   - Esperado: A recebe **exatamente 1 toast** "Novo chamado policial", com relato e coordenadas;
     B não recebe.
   - Se o MDT de A estiver aberto em Dispatch, a linha aparece sem toast adicional.
   - Fechar e reabrir o MDT: o chamado continua listado; nenhum toast novo.
   - Logs: `call_created`, `call_notified ... responders=1`, `queue_loaded ... items=1`.

3. **Snapshot e reentrega**
   - Abrir/fechar o MDT várias vezes e atualizar a fila.
   - Esperado: nenhum toast de criação; o mesmo `public_id` permanece.
   - Uma reentrega de `mz_dispatch:client:newCall` não deve gerar refresh/toast extra.
   - Log: `[mz_police][dispatch] new_call_ignored ... duplicate_delivery`.

4. **Dois chamados distintos**
   - C1 e C2 enviam chamados separados.
   - Esperado: cada chamado notifica A uma vez; ambos aparecem no MDT com ID, origem, horário,
     localização, status e contagem de unidades.

5. **Aceite e encerramento**
   - A abre o item e seleciona **Abrir GPS**: o waypoint usa as coordenadas persistidas pelo servidor,
     sem abrir painel adicional ou tomar foco.
   - A clica **Aceitar**: status `accepted`, blip temporário, sem toast de novo chamado.
   - A clica **Encerrar**: status `closed`, blip removido, chamado sai da fila.
   - Com o MDT de outro policial em duty aberto, a lista é reconsultada após o aceite/encerramento.
   - Logs: `unit_assigned`, `call_closed`.
   - B (fora de duty) não consegue listar/aceitar: `duty_required`.

6. **Concorrência**
   - Dois policiais em duty aceitam o mesmo chamado quase simultaneamente.
   - Esperado: servidor registra as unidades sem duplicar a mesma unidade; nenhuma criação/toast extra.
   - Encerrar sem atribuição retorna `assignment_required`.

7. **Reconexão / late join**
   - A reconecta ou B entra em duty depois.
   - Esperado: abrir o MDT carrega o estado atual; nenhum toast de chamados antigos.
   - Um chamado **novo** enviado depois continua notificando normalmente.

8. **Restart de resource**
   - Reiniciar `mz_dispatch` e `mz_police`.
   - Esperado: schema reutilizado sem DDL; estado persistido continua no MDT; um único handler
     de `newCall`/`callUpdated`; sem toasts duplicados.

9. **Falha controlada**
   - Parar `mz_dispatch` ou deixar o schema inválido.
   - Esperado: o MDT mostra `dispatch_unavailable`/erro, sem sucesso falso; após restaurar, a fila
     volta a carregar.
   - Log de negação: `queue_denied ... code=dispatch_unavailable`.

## Critério de aprovação

- 1 toast por policial elegível por chamado, em todo o fluxo.
- Chamado consultável no MDT independentemente do toast.
- Nenhum toast em abrir/fechar MDT, refresh, reconnect ou snapshot inicial.
- Status e atribuição sempre confirmados pelo servidor.
