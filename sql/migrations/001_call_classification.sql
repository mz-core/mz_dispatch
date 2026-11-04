-- Fallback manual versionado para bancos que ja possuem o schema P8.
-- O bootstrap atual aplica a mesma evolucao aditiva quando detecta exatamente esse schema legado.
ALTER TABLE mz_dispatch_calls
  ADD COLUMN category_code VARCHAR(32) NOT NULL DEFAULT 'general' AFTER message,
  ADD COLUMN priority_level TINYINT UNSIGNED NOT NULL DEFAULT 3 AFTER category_code,
  ADD COLUMN source_type VARCHAR(24) NOT NULL DEFAULT 'manual' AFTER priority_level,
  ADD COLUMN report_count SMALLINT UNSIGNED NOT NULL DEFAULT 1 AFTER source_type,
  ADD COLUMN location_accuracy VARCHAR(16) NOT NULL DEFAULT 'exact' AFTER report_count;

UPDATE mz_dispatch_calls
SET category_code = 'medical', priority_level = 2
WHERE service_code = 'medical' AND category_code = 'general';
