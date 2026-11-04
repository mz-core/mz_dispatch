CREATE TABLE IF NOT EXISTS mz_dispatch_calls (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  public_id VARCHAR(160) NOT NULL,
  service_code VARCHAR(32) NOT NULL,
  org_code VARCHAR(64) NOT NULL,
  caller_citizenid VARCHAR(64) NULL,
  caller_session_id BIGINT UNSIGNED NULL,
  message VARCHAR(280) NOT NULL,
  category_code VARCHAR(32) NOT NULL DEFAULT 'general',
  priority_level TINYINT UNSIGNED NOT NULL DEFAULT 3,
  source_type VARCHAR(24) NOT NULL DEFAULT 'manual',
  report_count SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  location_accuracy VARCHAR(16) NOT NULL DEFAULT 'exact',
  status ENUM('open', 'accepted', 'closed') NOT NULL DEFAULT 'open',
  location_x DECIMAL(12,4) NOT NULL,
  location_y DECIMAL(12,4) NOT NULL,
  location_z DECIMAL(12,4) NOT NULL,
  routing_bucket INT NOT NULL DEFAULT 0,
  closed_by_citizenid VARCHAR(64) NULL,
  closed_at TIMESTAMP NULL,
  revision INT UNSIGNED NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_mz_dispatch_calls_public_id (public_id),
  KEY ix_mz_dispatch_calls_queue (service_code, status, created_at),
  KEY ix_mz_dispatch_calls_caller (caller_citizenid, service_code, status),
  KEY ix_mz_dispatch_calls_sensor (service_code, source_type, status, routing_bucket, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS mz_dispatch_assignments (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  call_public_id VARCHAR(160) NOT NULL,
  responder_citizenid VARCHAR(64) NOT NULL,
  responder_session_id BIGINT UNSIGNED NOT NULL,
  org_code VARCHAR(64) NOT NULL,
  assigned_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_mz_dispatch_assignment (call_public_id, responder_citizenid),
  KEY ix_mz_dispatch_assignment_responder (responder_citizenid, assigned_at),
  CONSTRAINT fk_mz_dispatch_assignment_call FOREIGN KEY (call_public_id)
    REFERENCES mz_dispatch_calls (public_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS mz_dispatch_history (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  operation_id VARCHAR(180) NOT NULL,
  call_public_id VARCHAR(160) NOT NULL,
  action VARCHAR(48) NOT NULL,
  actor_citizenid VARCHAR(64) NOT NULL,
  details_json LONGTEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_mz_dispatch_history_operation (operation_id),
  KEY ix_mz_dispatch_history_call (call_public_id, id),
  CONSTRAINT fk_mz_dispatch_history_call FOREIGN KEY (call_public_id)
    REFERENCES mz_dispatch_calls (public_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
