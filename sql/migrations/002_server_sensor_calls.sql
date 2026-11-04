-- Aplicacao manual apos 001_call_classification.sql em bancos que ja possuem P8.
-- Necessaria para chamadas automaticas sem atribuir o solicitante a um jogador.
-- Nao aplicar automaticamente nem em producao.
ALTER TABLE mz_dispatch_calls
  MODIFY COLUMN caller_citizenid VARCHAR(64) NULL,
  MODIFY COLUMN caller_session_id BIGINT UNSIGNED NULL,
  ADD KEY ix_mz_dispatch_calls_sensor (service_code, source_type, status, routing_bucket, created_at);
