-- ==============================================================================
-- ESQUEMA DE BASE DE DATOS DISTRIBUIDA — NBA REAL-TIME SYSTEM
-- Versión:   3.0 — Sincronización, Transacciones y Coherencia/Disponibilidad
-- Motor:     SQLite 3.x (prototipo) → PostgreSQL 16 (producción distribuida)
-- ==============================================================================
-- NUEVA ARQUITECTURA:
--   + Distributed Locks  (mutex / semáforo a nivel de BD)
--   + 2-Phase Commit     (coordinación multi-nodo)
--   + Saga Pattern       (transacciones largas con compensación)
--   + Transactional Outbox (entrega exactamente-una-vez)
--   + Dead Letter Queue  (eventos irrecuperables)
--   + Vector Clocks      (ordenamiento causal)
--   + Quorum State       (lecturas/escrituras por mayoría)
--   + Circuit Breaker    (tolerancia a fallos en cascada)
-- ==============================================================================

-- ==============================================================================
-- PRAGMA DE CONFIGURACIÓN
-- ==============================================================================
PRAGMA journal_mode       = WAL;        -- Write-Ahead Logging: concurrencia máxima
PRAGMA synchronous        = NORMAL;     -- Balance durabilidad / rendimiento
PRAGMA foreign_keys       = ON;         -- Integridad referencial
PRAGMA cache_size         = -64000;     -- 64 MB de page cache
PRAGMA temp_store         = MEMORY;
PRAGMA wal_autocheckpoint = 1000;       -- Checkpoint cada 1000 páginas (~4 MB)
PRAGMA busy_timeout       = 5000;       -- Esperar 5s antes de SQLITE_BUSY

-- ==============================================================================
-- SHARD 0 — DATOS MAESTROS
-- ==============================================================================

CREATE TABLE IF NOT EXISTS teams (
    team_id    TEXT PRIMARY KEY,
    full_name  TEXT NOT NULL,
    city       TEXT NOT NULL,
    conference TEXT CHECK(conference IN ('East','West')),
    division   TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS players (
    player_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    team_id    TEXT    NOT NULL REFERENCES teams(team_id),
    position   TEXT    CHECK(position IN ('PG','SG','SF','PF','C')),
    rating     INTEGER CHECK(rating BETWEEN 50 AND 99),
    is_starter INTEGER DEFAULT 0,
    active     INTEGER DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ==============================================================================
-- SHARD 1 — DATOS DE PARTIDOS
-- ==============================================================================

CREATE TABLE IF NOT EXISTS games (
    game_id          TEXT    PRIMARY KEY,
    shard_id         INTEGER NOT NULL DEFAULT 0,
    home_team_id     TEXT    NOT NULL REFERENCES teams(team_id),
    away_team_id     TEXT    NOT NULL REFERENCES teams(team_id),
    season           TEXT    NOT NULL DEFAULT '2025-26',
    quarter          INTEGER DEFAULT 1 CHECK(quarter BETWEEN 1 AND 6),
    clock_ms         INTEGER DEFAULT 720000,
    home_score       INTEGER DEFAULT 0,
    away_score       INTEGER DEFAULT 0,
    possession       TEXT    CHECK(possession IN ('home','away')),
    status           TEXT    DEFAULT 'SCHEDULED'
                     CHECK(status IN ('SCHEDULED','LIVE','HALFTIME','FINAL','SUSPENDED')),
    simulation_speed REAL    DEFAULT 1.0,
    start_time       DATETIME DEFAULT CURRENT_TIMESTAMP,
    end_time         DATETIME,
    -- Control de versión optimista (Optimistic Concurrency Control)
    version          INTEGER DEFAULT 1,
    last_updated     DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    checksum         TEXT
);

CREATE TABLE IF NOT EXISTS game_quarters (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id     TEXT    NOT NULL REFERENCES games(game_id),
    quarter     INTEGER NOT NULL CHECK(quarter BETWEEN 1 AND 6),
    home_score  INTEGER DEFAULT 0,
    away_score  INTEGER DEFAULT 0,
    duration_ms INTEGER,
    UNIQUE(game_id, quarter)
);

-- ==============================================================================
-- SHARD 2 — STREAM DE EVENTOS EN TIEMPO REAL
-- ==============================================================================

CREATE TABLE IF NOT EXISTS game_events (
    event_id        TEXT    PRIMARY KEY,
    game_id         TEXT    NOT NULL REFERENCES games(game_id),
    quarter         INTEGER NOT NULL,
    clock_ms        INTEGER NOT NULL,
    event_time_ms   INTEGER NOT NULL,
    type            TEXT    NOT NULL
                    CHECK(type IN (
                        'SHOT','REBOUND','ASSIST','TURNOVER',
                        'STEAL','BLOCK','FOUL','SUBSTITUTION',
                        'TIMEOUT','PERIOD_START','PERIOD_END'
                    )),
    team_id         TEXT    REFERENCES teams(team_id),
    player_name     TEXT,
    shot_type       TEXT    CHECK(shot_type IN ('2PT','3PT','FT') OR shot_type IS NULL),
    shot_made       INTEGER,
    points          INTEGER DEFAULT 0,
    reb_type        TEXT    CHECK(reb_type IN ('DEF','OFF') OR reb_type IS NULL),
    foul_type       TEXT    CHECK(foul_type IN ('PERSONAL','SHOOTING','TECHNICAL') OR foul_type IS NULL),
    player_out      TEXT,
    player_in       TEXT,
    received_at_ms  INTEGER NOT NULL,
    processed_at_ms INTEGER,
    latency_ms      REAL    GENERATED ALWAYS AS
                    (CASE WHEN processed_at_ms IS NOT NULL
                          THEN CAST(processed_at_ms - received_at_ms AS REAL)
                          ELSE NULL END) VIRTUAL,
    is_late         INTEGER DEFAULT 0,
    is_duplicate    INTEGER DEFAULT 0,
    -- Referencia a la transacción 2PC que lo originó (trazabilidad completa)
    tx_id           TEXT    REFERENCES transaction_log(tx_id),
    node_origin     INTEGER DEFAULT 0,
    replicated      INTEGER DEFAULT 0,
    -- Vector clock en el momento de creación (JSON: {"n0":5,"n1":3,"n2":2})
    vector_clock    TEXT    DEFAULT '{}',
    created_at      DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW'))
);

CREATE TABLE IF NOT EXISTS cold_events AS SELECT * FROM game_events WHERE 0;

-- ==============================================================================
-- SHARD 3 — ESTADÍSTICAS DE JUGADORES (CRDT)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS player_game_stats (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id      TEXT    NOT NULL REFERENCES games(game_id),
    player_name  TEXT    NOT NULL,
    team_id      TEXT    NOT NULL REFERENCES teams(team_id),
    on_court     INTEGER DEFAULT 0,
    minutes      REAL    DEFAULT 0.0,
    pts          INTEGER DEFAULT 0,
    fgm          INTEGER DEFAULT 0,
    fga          INTEGER DEFAULT 0,
    tpm          INTEGER DEFAULT 0,
    tpa          INTEGER DEFAULT 0,
    ftm          INTEGER DEFAULT 0,
    fta          INTEGER DEFAULT 0,
    reb          INTEGER DEFAULT 0,
    ast          INTEGER DEFAULT 0,
    stl          INTEGER DEFAULT 0,
    blk          INTEGER DEFAULT 0,
    tov          INTEGER DEFAULT 0,
    pf           INTEGER DEFAULT 0,
    -- CRDT G-Counter: version monotónica + nodo de última escritura
    version      INTEGER DEFAULT 1,
    node_updated INTEGER DEFAULT 0,
    last_updated DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    UNIQUE(game_id, player_name)
);

-- ==============================================================================
-- SHARD 4 — ANALÍTICA IA
-- ==============================================================================

CREATE TABLE IF NOT EXISTS ai_projections (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id              TEXT    NOT NULL REFERENCES games(game_id),
    quarter              INTEGER NOT NULL,
    clock_ms             INTEGER NOT NULL,
    snapshot_at_ms       INTEGER,
    win_prob_home        REAL    NOT NULL CHECK(win_prob_home BETWEEN 0 AND 1),
    win_prob_away        REAL    NOT NULL CHECK(win_prob_away BETWEEN 0 AND 1),
    projected_score_home INTEGER,
    projected_score_away INTEGER,
    scenarios_simulated  INTEGER,
    recursion_depth      INTEGER,
    execution_time_ms    REAL,
    created_at           DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS system_exceptions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id        TEXT    REFERENCES games(game_id),
    exception_type TEXT    NOT NULL
                   CHECK(exception_type IN (
                       'late_event','data_inconsistency','deadlock_warning',
                       'sensor_loss','deadline_overrun','queue_highwater',
                       'node_failure','replication_lag','checksum_mismatch',
                       'tx_timeout','quorum_failed','lock_timeout',
                       'saga_compensation','circuit_open','dlq_overflow'
                   )),
    event_id       TEXT,
    details        TEXT    NOT NULL,
    clock_ms       INTEGER,
    quarter        INTEGER,
    node_id        INTEGER DEFAULT 0,
    resolved       INTEGER DEFAULT 0,
    wall_ts        DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW'))
);

-- ==============================================================================
-- CAPA DE SINCRONIZACIÓN DISTRIBUIDA
-- ==============================================================================

-- ── 1. DISTRIBUTED LOCKS (Mutex / Semáforo a nivel de BD) ─────────────────────
-- Equivalente al semáforo de Dijkstra implementado en el sistema, pero a nivel
-- de cluster de base datos. Previene escrituras concurrentes desde distintos nodos.
--
-- Escenario típico:
--   Nodo 0 quiere actualizar home_score mientras Nodo 1 aplica una réplica.
--   Ambos solicitan LOCK EXCLUSIVE 'score:NBA_LAL_BOS':
--     → El primero adquiere el lock (holder_node = 0)
--     → El segundo es encolado en lock_waiters
--     → Al liberar (RELEASE), lock_waiters sirve al siguiente (FIFO Dijkstra)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS distributed_locks (
    lock_id        TEXT    PRIMARY KEY,          -- 'score:game_id', 'stats:LAL', etc.
    game_id        TEXT    REFERENCES games(game_id),
    resource_type  TEXT    NOT NULL              -- recurso protegido
                   CHECK(resource_type IN ('SCORE','STATS','QUEUE','POSSESSION','CLOCK','AI')),
    lock_type      TEXT    NOT NULL              -- tipo de exclusión
                   CHECK(lock_type IN ('EXCLUSIVE','SHARED','INTENT_EXCL')),
    holder_node    INTEGER,                      -- nodo que lo retiene (NULL = libre)
    holder_tx_id   TEXT,                         -- tx_id del titular (trazabilidad)
    acquired_at    DATETIME,
    expires_at     DATETIME,                     -- TTL anti-deadlock
    waiter_count   INTEGER DEFAULT 0,            -- procesos bloqueados esperando
    acquire_count  INTEGER DEFAULT 0,            -- veces adquirido (historial)
    updated_at     DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW'))
);

-- ── 2. LOCK WAITERS — Cola FIFO de procesos esperando un lock ─────────────────
-- Implementa exactamente la misma lógica que la cola interna del Semaphore.queue[]
-- de Dijkstra, pero persistida para auditoría y recuperación ante fallos.
CREATE TABLE IF NOT EXISTS lock_waiters (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    lock_id     TEXT    NOT NULL REFERENCES distributed_locks(lock_id),
    waiter_node INTEGER NOT NULL,
    waiter_tx   TEXT,                            -- transacción bloqueada
    requested_at DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    wait_type   TEXT    DEFAULT 'BLOCKED'
                CHECK(wait_type IN ('BLOCKED','TIMED_OUT','ACQUIRED','CANCELLED'))
);

-- ── 3. DEADLOCK DETECTOR — Grafo Wait-For ──────────────────────────────────────
-- Detecta ciclos en el grafo de espera entre nodos (A espera a B, B espera a A).
-- Un ciclo = deadlock. Se resuelve abortando la transacción de menor prioridad.
CREATE TABLE IF NOT EXISTS deadlock_graph (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    waiter_node INTEGER NOT NULL,                -- Nodo que ESPERA el lock
    holder_node INTEGER NOT NULL,                -- Nodo que RETIENE el lock
    lock_id     TEXT    NOT NULL,
    game_id     TEXT,
    detected_at DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    resolved    INTEGER DEFAULT 0,               -- 1 = ciclo resuelto
    resolution  TEXT                             -- 'ABORT_WAITER','ABORT_HOLDER','TIMEOUT'
                CHECK(resolution IN ('ABORT_WAITER','ABORT_HOLDER','TIMEOUT') OR resolution IS NULL)
);

-- ==============================================================================
-- CAPA DE TRANSACCIONES DISTRIBUIDAS
-- ==============================================================================

-- ── 4. TRANSACTION LOG — 2-Phase Commit Protocol (2PC) ────────────────────────
-- El protocolo 2PC garantiza que una transacción distribuida es TODA-O-NADA:
-- si algún nodo no puede confirmar, todos hacen ROLLBACK.
--
-- Escenario: SHOT anotado → transacción que actualiza en TODOS los nodos:
--   (1) Shard 2: INSERT game_events
--   (2) Shard 1: UPDATE games SET home_score = home_score + 3
--   (3) Shard 3: UPDATE player_game_stats SET pts = pts + 3
--   (4) Shard 4: INSERT ai_projections (batch)
--
-- Flujo 2PC:
--   FASE 1 PREPARE:  Coordinador → todos los participantes: "¿puedes confirmar?"
--   FASE 1 VOTE:     Cada nodo responde VOTE-COMMIT o VOTE-ABORT
--   FASE 2 COMMIT:   Si todos dicen VOTE-COMMIT → Coordinador emite COMMIT global
--   FASE 2 ROLLBACK: Si alguno dice VOTE-ABORT  → Coordinador emite ABORT global
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS transaction_log (
    tx_id            TEXT    PRIMARY KEY,         -- UUID de la transacción
    game_id          TEXT    REFERENCES games(game_id),
    tx_type          TEXT    NOT NULL
                     CHECK(tx_type IN (
                         'SHOT_MADE','TURNOVER','FOUL_CALL','SUBSTITUTION',
                         'TIMEOUT_CALL','QUARTER_END','STAT_BATCH','AI_BATCH'
                     )),
    coordinator_node INTEGER NOT NULL DEFAULT 0,
    phase            TEXT    NOT NULL DEFAULT 'INIT'
                     CHECK(phase IN ('INIT','PREPARE','PREPARED','COMMIT','COMMITTED','ABORT','ABORTED','RECOVERING')),
    participants     TEXT    NOT NULL,             -- JSON: [{"node":0,"shard":1},{"node":1,"shard":2}]
    prepare_votes    TEXT    DEFAULT '{}',         -- JSON: {"node0":"COMMIT","node1":"COMMIT"}
    payload          TEXT    NOT NULL,             -- JSON: datos de la transacción
    started_at       DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    prepared_at      DATETIME,
    committed_at     DATETIME,
    aborted_at       DATETIME,
    timeout_at       DATETIME,                    -- abortar automáticamente si supera
    retry_count      INTEGER DEFAULT 0,
    error_msg        TEXT,
    -- Causalidad: vector clock al inicio de la transacción
    vector_clock_at  TEXT    DEFAULT '{}'
);

-- ── 5. TX_PARTICIPANTS — Votos de cada nodo en 2PC ────────────────────────────
CREATE TABLE IF NOT EXISTS tx_participants (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    tx_id        TEXT    NOT NULL REFERENCES transaction_log(tx_id),
    node_id      INTEGER NOT NULL,
    shard_id     INTEGER NOT NULL,
    vote         TEXT    CHECK(vote IN ('PREPARE_OK','VOTE_COMMIT','VOTE_ABORT') OR vote IS NULL),
    ack          TEXT    CHECK(ack  IN ('COMMIT_ACK','ABORT_ACK') OR ack IS NULL),
    voted_at     DATETIME,
    acked_at     DATETIME,
    error_msg    TEXT,
    UNIQUE(tx_id, node_id)
);

-- ── 6. SAGA LOG — Transacciones largas con compensación ───────────────────────
-- El patrón Saga divide una transacción larga (ej. FOUL → 2 FT → rebound) en
-- pasos secuenciales. Si un paso falla, ejecuta acciones de COMPENSACIÓN en
-- orden inverso (rollback semántico, no físico).
--
-- Escenario FOUL_WITH_FREE_THROWS:
--   Step 1: registrar foul (compensación: decrement pf)
--   Step 2: suspender shot clock (compensación: restaurar shot clock)
--   Step 3: crear FT_1 event (compensación: borrar FT_1)
--   Step 4: crear FT_2 event (compensación: borrar FT_2)
--   Step 5: actualizar score (compensación: revertir score)
--   Si Step 4 falla → ejecutar compensaciones 3, 2, 1 en orden inverso
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS saga_log (
    saga_id       TEXT    PRIMARY KEY,            -- UUID del saga
    game_id       TEXT    REFERENCES games(game_id),
    saga_type     TEXT    NOT NULL
                  CHECK(saga_type IN (
                      'FOUL_FREE_THROWS','SUBSTITUTION_PAIR','QUARTER_TRANSITION',
                      'TIMEOUT_SEQUENCE','REBOUND_POSSESSION'
                  )),
    current_step  INTEGER DEFAULT 0,              -- paso actual
    total_steps   INTEGER NOT NULL,
    status        TEXT    DEFAULT 'RUNNING'
                  CHECK(status IN ('RUNNING','COMPLETED','COMPENSATING','COMPENSATED','FAILED')),
    trigger_event TEXT,                           -- event_id que inició el saga
    started_at    DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    completed_at  DATETIME,
    compensating_from INTEGER                     -- paso desde donde se compensa
);

-- ── 7. SAGA STEPS — Pasos individuales y sus compensaciones ───────────────────
CREATE TABLE IF NOT EXISTS saga_steps (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    saga_id         TEXT    NOT NULL REFERENCES saga_log(saga_id),
    step_number     INTEGER NOT NULL,
    step_name       TEXT    NOT NULL,             -- 'register_foul', 'create_ft1', etc.
    status          TEXT    DEFAULT 'PENDING'
                    CHECK(status IN ('PENDING','EXECUTING','DONE','COMPENSATING','COMPENSATED','FAILED')),
    -- Acción forward
    action_type     TEXT    NOT NULL,             -- 'INSERT','UPDATE','DELETE','EMIT_EVENT'
    action_payload  TEXT    NOT NULL,             -- JSON de la acción
    action_result   TEXT,                         -- JSON del resultado
    -- Acción de compensación (undone si el saga debe revertir)
    compensation_type    TEXT,
    compensation_payload TEXT,
    compensation_result  TEXT,
    executed_at      DATETIME,
    compensated_at   DATETIME,
    error_msg        TEXT,
    UNIQUE(saga_id, step_number)
);

-- ==============================================================================
-- CAPA DE ENTREGA DE EVENTOS (Garantías de Entrega)
-- ==============================================================================

-- ── 8. EVENT OUTBOX — Patrón Transactional Outbox ──────────────────────────────
-- PROBLEMA: Si escribimos en game_events Y enviamos la notificación de replicación
-- en dos pasos separados, un fallo entre ambos causaría que el evento exista en
-- el nodo primario pero no se replique nunca.
--
-- SOLUCIÓN: El Outbox Pattern escribe el evento Y su notificación en la MISMA
-- transacción de BD. Un proceso relay (Change Data Capture) lee el outbox y
-- publica a los réplicas. Si falla, reintenta. Los receptores son IDEMPOTENTES.
--
-- Garantía: AT-LEAST-ONCE DELIVERY + IDEMPOTENCIA en receptor = EXACTLY-ONCE
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS event_outbox (
    outbox_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id         TEXT    REFERENCES games(game_id),
    event_id        TEXT    UNIQUE,               -- Clave de idempotencia
    tx_id           TEXT    REFERENCES transaction_log(tx_id),
    topic           TEXT    NOT NULL DEFAULT 'game.events',
                                                  -- 'game.events','game.stats','game.ai'
    payload         TEXT    NOT NULL,             -- JSON completo del evento/stat
    status          TEXT    DEFAULT 'PENDING'
                    CHECK(status IN ('PENDING','RELAYING','DELIVERED','FAILED','DEAD')),
    target_nodes    TEXT    NOT NULL DEFAULT '[1,2,3]',
    delivered_to    TEXT    DEFAULT '[]',          -- JSON: nodos con ACK
    attempts        INTEGER DEFAULT 0,
    max_attempts    INTEGER DEFAULT 5,
    next_retry_at   DATETIME,
    created_at      DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    delivered_at    DATETIME,
    -- Vector clock para garantizar ordenamiento causal en el receptor
    vector_clock    TEXT    DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending
    ON event_outbox(status, next_retry_at) WHERE status IN ('PENDING','FAILED');

-- ── 9. DEAD LETTER QUEUE — Eventos irrecuperables ─────────────────────────────
-- Eventos que superaron el máximo de reintentos. Requieren inspección manual
-- o replay controlado. Crítico para auditoría y no-pérdida de datos.
CREATE TABLE IF NOT EXISTS event_dead_letter (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    outbox_id   INTEGER NOT NULL REFERENCES event_outbox(outbox_id),
    game_id     TEXT,
    event_id    TEXT,
    topic       TEXT,
    payload     TEXT,
    failed_at   DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    last_error  TEXT,
    total_attempts INTEGER,
    replayed    INTEGER DEFAULT 0,               -- 1 si fue reprocesado manualmente
    replayed_at DATETIME
);

-- ── 10. DELIVERY ACK — Confirmaciones por nodo ────────────────────────────────
-- Rastrea exactamente qué nodo confirmó la entrega de cada evento del outbox.
CREATE TABLE IF NOT EXISTS delivery_ack (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    outbox_id   INTEGER NOT NULL REFERENCES event_outbox(outbox_id),
    target_node INTEGER NOT NULL,
    acked_at    DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    latency_ms  INTEGER,
    UNIQUE(outbox_id, target_node)
);

-- ==============================================================================
-- CAPA DE COHERENCIA (Consistency)
-- ==============================================================================

-- ── 11. VECTOR CLOCKS — Relojes vectoriales (Lamport generalizado) ─────────────
-- Garantizan el ordenamiento causal de eventos en el sistema distribuido.
-- Cada nodo mantiene un contador. Al enviar un mensaje, incluye su vector clock.
-- El receptor actualiza: VC_receptor[i] = max(VC_receptor[i], VC_mensaje[i]) + delta
--
-- Esto permite detectar:
--   - A → B: A causó B (happens-before)
--   - A ∥ B: eventos concurrentes (sin relación causal)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vector_clocks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id     TEXT    NOT NULL REFERENCES games(game_id),
    node_id     INTEGER NOT NULL,
    clock_n0    INTEGER DEFAULT 0,               -- contador del Nodo 0
    clock_n1    INTEGER DEFAULT 0,               -- contador del Nodo 1
    clock_n2    INTEGER DEFAULT 0,               -- contador del Nodo 2
    clock_n3    INTEGER DEFAULT 0,               -- contador del Nodo 3
    event_ref   TEXT,                            -- event_id o tx_id de referencia
    updated_at  DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    UNIQUE(game_id, node_id)
);

-- ── 12. QUORUM STATE — Estado de quórum para escrituras críticas ───────────────
-- Para escrituras críticas (marcador, cambio de cuarto) se requiere que
-- MAYORÍA de nodos (N/2 + 1) confirmen antes de considerar la escritura durable.
-- Con 4 nodos: quórum = 3. Con 3 nodos: quórum = 2.
--
-- Read Quorum  (R): mínimo nodos que deben responder para una lectura válida
-- Write Quorum (W): mínimo ACKs para confirmar escritura
-- R + W > N   →  garantiza que cada lectura ve la última escritura
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quorum_state (
    quorum_id     TEXT    PRIMARY KEY,           -- 'write:tx_id'
    tx_id         TEXT    REFERENCES transaction_log(tx_id),
    game_id       TEXT,
    operation     TEXT    NOT NULL CHECK(operation IN ('READ','WRITE')),
    required_acks INTEGER NOT NULL,              -- quórum mínimo (N/2+1)
    received_acks INTEGER DEFAULT 0,
    ack_nodes     TEXT    DEFAULT '[]',          -- JSON: nodos que respondieron
    quorum_reached INTEGER DEFAULT 0,           -- 1 cuando received >= required
    started_at    DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
    completed_at  DATETIME,
    timed_out     INTEGER DEFAULT 0             -- 1 si el quórum no se alcanzó a tiempo
);

-- ==============================================================================
-- CAPA DE DISPONIBILIDAD (Availability / Fault Tolerance)
-- ==============================================================================

-- ── 13. CIRCUIT BREAKER — Prevención de fallos en cascada ─────────────────────
-- Patrón que evita que un nodo fallido cause cascada de errores.
-- Estados:
--   CLOSED    → Normal. Peticiones pasan. Cuenta fallos.
--   OPEN      → Demasiados fallos. No pasa ninguna petición. Timer de espera.
--   HALF_OPEN → Período de prueba. Permite UNA petición. Si falla → OPEN de nuevo.
--
-- Ejemplo: Nodo 2 (ASYNC) no responde. Después de 5 fallos en 10s:
--   → Circuit OPEN para Nodo 2
--   → Tráfico redirigido solo a Nodo 1
--   → Después de 30s, intenta HALF_OPEN
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS circuit_breaker (
    node_id           INTEGER PRIMARY KEY,
    state             TEXT    NOT NULL DEFAULT 'CLOSED'
                      CHECK(state IN ('CLOSED','OPEN','HALF_OPEN')),
    failure_count     INTEGER DEFAULT 0,
    success_count     INTEGER DEFAULT 0,
    failure_threshold INTEGER DEFAULT 5,         -- fallos para OPEN
    success_threshold INTEGER DEFAULT 2,         -- éxitos para CLOSED desde HALF_OPEN
    timeout_sec       INTEGER DEFAULT 30,        -- duración de OPEN antes de HALF_OPEN
    last_failure_at   DATETIME,
    opened_at         DATETIME,
    half_open_at      DATETIME,
    closed_at         DATETIME,
    total_opens       INTEGER DEFAULT 0,
    updated_at        DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW'))
);

-- ── 14. NODE HEALTH — Estado de nodos del clúster ─────────────────────────────
CREATE TABLE IF NOT EXISTS node_health (
    node_id        INTEGER PRIMARY KEY,
    role           TEXT NOT NULL CHECK(role IN ('PRIMARY','REPLICA_SYNC','REPLICA_ASYNC','ANALYTICS')),
    shard_ids      TEXT,
    status         TEXT DEFAULT 'UP' CHECK(status IN ('UP','DOWN','DEGRADED','SYNCING')),
    last_heartbeat DATETIME,
    lag_ms         INTEGER DEFAULT 0,
    events_pending INTEGER DEFAULT 0,
    updated_at     DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ── 15. FAILOVER LOG — Historial de promociones de nodo ───────────────────────
-- Registra cada vez que un nodo réplica fue promovido a PRIMARY, indicando
-- el evento que lo disparó y el estado de los datos al momento del failover.
CREATE TABLE IF NOT EXISTS failover_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    failed_node     INTEGER NOT NULL,
    promoted_node   INTEGER NOT NULL,
    trigger_cause   TEXT,                         -- 'HEARTBEAT_TIMEOUT','MANUAL','DISK_FULL'
    game_id         TEXT,
    clock_ms_at     INTEGER,                      -- reloj de juego en el momento del fallo
    events_lost     INTEGER DEFAULT 0,            -- eventos que no alcanzaron a replicarse
    recovery_time_ms INTEGER,                     -- tiempo hasta que el sistema fue estable
    detected_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
    recovered_at    DATETIME
);

-- ── 16. REPLICATION LOG — Pipeline de replicación ─────────────────────────────
CREATE TABLE IF NOT EXISTS replication_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source_node  INTEGER NOT NULL,
    target_node  INTEGER NOT NULL,
    table_name   TEXT    NOT NULL,
    record_id    TEXT    NOT NULL,
    operation    TEXT    NOT NULL CHECK(operation IN ('INSERT','UPDATE','DELETE')),
    payload      TEXT,
    status       TEXT    DEFAULT 'PENDING'
                 CHECK(status IN ('PENDING','SENT','ACK','FAILED','RETRY')),
    retry_count  INTEGER DEFAULT 0,
    sent_at      DATETIME,
    ack_at       DATETIME,
    created_at   DATETIME DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f','NOW'))
);

-- ==============================================================================
-- VISTAS PARA MONITOREO EN TIEMPO REAL
-- ==============================================================================

-- Vista: marcador en vivo
CREATE VIEW IF NOT EXISTS v_live_scoreboard AS
SELECT g.game_id, t_home.full_name AS home_team, t_away.full_name AS away_team,
       g.home_score, g.away_score, g.quarter, g.clock_ms, g.possession, g.status,
       (SELECT COUNT(*) FROM game_events e WHERE e.game_id = g.game_id) AS total_events
FROM games g
JOIN teams t_home ON g.home_team_id = t_home.team_id
JOIN teams t_away ON g.away_team_id = t_away.team_id;

-- Vista: transacciones activas con su estado 2PC
CREATE VIEW IF NOT EXISTS v_active_transactions AS
SELECT tx_id, tx_type, coordinator_node, phase,
       json_array_length(participants) AS participant_count,
       ROUND(JULIANDAY('NOW') - JULIANDAY(started_at), 4) * 86400 AS age_sec,
       CASE WHEN phase IN ('COMMITTED','ABORTED') THEN 0 ELSE 1 END AS is_active
FROM transaction_log
WHERE phase NOT IN ('COMMITTED','ABORTED')
ORDER BY started_at DESC;

-- Vista: estado de locks distribuidos (semáforos de BD)
CREATE VIEW IF NOT EXISTS v_lock_status AS
SELECT dl.lock_id, dl.resource_type, dl.lock_type,
       dl.holder_node,
       CASE WHEN dl.holder_node IS NULL THEN 'LIBRE' ELSE 'RETENIDO' END AS state,
       dl.waiter_count,
       COUNT(lw.id) AS actual_waiters,
       dl.acquire_count
FROM distributed_locks dl
LEFT JOIN lock_waiters lw ON dl.lock_id = lw.lock_id AND lw.wait_type = 'BLOCKED'
GROUP BY dl.lock_id;

-- Vista: estado del outbox (entrega de eventos)
CREATE VIEW IF NOT EXISTS v_outbox_health AS
SELECT
    topic,
    COUNT(*)                                                AS total,
    SUM(CASE WHEN status = 'PENDING'   THEN 1 ELSE 0 END) AS pending,
    SUM(CASE WHEN status = 'DELIVERED' THEN 1 ELSE 0 END) AS delivered,
    SUM(CASE WHEN status = 'FAILED'    THEN 1 ELSE 0 END) AS failed,
    SUM(CASE WHEN status = 'DEAD'      THEN 1 ELSE 0 END) AS dead,
    AVG(attempts)                                           AS avg_attempts
FROM event_outbox GROUP BY topic;

-- Vista: sagas en ejecución
CREATE VIEW IF NOT EXISTS v_active_sagas AS
SELECT sl.saga_id, sl.saga_type, sl.status, sl.current_step, sl.total_steps,
       COUNT(ss.id) AS steps_done,
       COUNT(CASE WHEN ss.status = 'COMPENSATED' THEN 1 END) AS steps_compensated
FROM saga_log sl
LEFT JOIN saga_steps ss ON sl.saga_id = ss.saga_id AND ss.status IN ('DONE','COMPENSATED')
WHERE sl.status IN ('RUNNING','COMPENSATING')
GROUP BY sl.saga_id;

-- Vista: detector de deadlocks activos
CREATE VIEW IF NOT EXISTS v_active_deadlocks AS
SELECT a.waiter_node, a.holder_node, a.lock_id, a.detected_at
FROM deadlock_graph a
JOIN deadlock_graph b ON a.waiter_node = b.holder_node AND a.holder_node = b.waiter_node
WHERE a.resolved = 0
ORDER BY a.detected_at DESC;

-- Vista: health del circuito breaker (por nodo)
CREATE VIEW IF NOT EXISTS v_circuit_health AS
SELECT cb.node_id, nh.role, cb.state,
       cb.failure_count, cb.failure_threshold,
       ROUND(cb.failure_count * 100.0 / NULLIF(cb.failure_threshold,0), 0) AS failure_pct,
       cb.total_opens,
       nh.lag_ms AS replication_lag_ms,
       nh.status AS node_status
FROM circuit_breaker cb
JOIN node_health nh ON cb.node_id = nh.node_id;

-- Vista: quórum de escrituras recientes
CREATE VIEW IF NOT EXISTS v_quorum_status AS
SELECT qs.quorum_id, qs.operation, qs.required_acks, qs.received_acks,
       qs.quorum_reached, qs.timed_out,
       ROUND(JULIANDAY('NOW') - JULIANDAY(qs.started_at), 6) * 86400 AS age_sec
FROM quorum_state qs
WHERE qs.started_at > DATETIME('NOW', '-60 seconds')
ORDER BY qs.started_at DESC LIMIT 20;

-- Vista: métricas de semáforos (existente)
CREATE VIEW IF NOT EXISTS v_semaphore_metrics AS
SELECT semaphore_id,
       COUNT(*) AS total_ops,
       SUM(CASE WHEN operation LIKE 'WAIT%'   THEN 1 ELSE 0 END) AS total_waits,
       SUM(CASE WHEN operation LIKE 'SIGNAL%' THEN 1 ELSE 0 END) AS total_signals,
       SUM(CASE WHEN operation = 'WAIT_QUEUED' THEN 1 ELSE 0 END) AS times_blocked,
       MAX(queue_length) AS max_queue_depth,
       AVG(queue_length) AS avg_queue_depth
FROM semaphore_transactions GROUP BY semaphore_id;

-- Vista: health del sistema de replicación
CREATE VIEW IF NOT EXISTS v_replication_health AS
SELECT rl.target_node, nh.role, nh.status,
       COUNT(CASE WHEN rl.status = 'PENDING' THEN 1 END) AS pending_records,
       COUNT(CASE WHEN rl.status = 'FAILED'  THEN 1 END) AS failed_records,
       MAX(nh.lag_ms)   AS replication_lag_ms,
       MAX(rl.created_at) AS last_activity
FROM replication_log rl
JOIN node_health nh ON rl.target_node = nh.node_id
GROUP BY rl.target_node, nh.role, nh.status;

-- ==============================================================================
-- ÍNDICES OPTIMIZADOS
-- ==============================================================================

-- game_events
CREATE INDEX IF NOT EXISTS idx_events_game_time ON game_events(game_id, event_time_ms DESC);
CREATE INDEX IF NOT EXISTS idx_events_type       ON game_events(game_id, type, quarter);
CREATE INDEX IF NOT EXISTS idx_events_tx         ON game_events(tx_id) WHERE tx_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_replicated ON game_events(replicated, created_at) WHERE replicated = 0;

-- player_game_stats
CREATE INDEX IF NOT EXISTS idx_pgs_game_team ON player_game_stats(game_id, team_id, on_court DESC);

-- Distributed locks
CREATE INDEX IF NOT EXISTS idx_locks_holder ON distributed_locks(holder_node, resource_type);
CREATE INDEX IF NOT EXISTS idx_locks_expiry ON distributed_locks(expires_at) WHERE holder_node IS NOT NULL;

-- Lock waiters
CREATE INDEX IF NOT EXISTS idx_waiters_lock ON lock_waiters(lock_id, requested_at) WHERE wait_type = 'BLOCKED';

-- 2PC
CREATE INDEX IF NOT EXISTS idx_tx_phase   ON transaction_log(phase, started_at) WHERE phase NOT IN ('COMMITTED','ABORTED');
CREATE INDEX IF NOT EXISTS idx_tx_game    ON transaction_log(game_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_tx_timeout ON transaction_log(timeout_at) WHERE phase NOT IN ('COMMITTED','ABORTED');

-- Saga
CREATE INDEX IF NOT EXISTS idx_saga_active ON saga_log(status, started_at) WHERE status IN ('RUNNING','COMPENSATING');

-- Outbox
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON event_outbox(status, next_retry_at) WHERE status IN ('PENDING','FAILED');
CREATE INDEX IF NOT EXISTS idx_outbox_event   ON event_outbox(event_id);

-- Vector clocks
CREATE INDEX IF NOT EXISTS idx_vc_game_node ON vector_clocks(game_id, node_id);

-- Quórum
CREATE INDEX IF NOT EXISTS idx_quorum_active ON quorum_state(quorum_reached, timed_out, started_at);

-- Circuit breaker
CREATE INDEX IF NOT EXISTS idx_cb_state ON circuit_breaker(state) WHERE state != 'CLOSED';

-- Semáforos
CREATE INDEX IF NOT EXISTS idx_sem_game_ts     ON semaphore_transactions(game_id, wall_ts DESC);
CREATE INDEX IF NOT EXISTS idx_ai_game_clock   ON ai_projections(game_id, clock_ms DESC);
CREATE INDEX IF NOT EXISTS idx_repl_status     ON replication_log(status, target_node, created_at) WHERE status IN ('PENDING','FAILED');
CREATE INDEX IF NOT EXISTS idx_exc_unresolved  ON system_exceptions(resolved, game_id) WHERE resolved = 0;
CREATE INDEX IF NOT EXISTS idx_dlq_unreplayed  ON event_dead_letter(replayed) WHERE replayed = 0;

-- ==============================================================================
-- TRIGGERS DE INTEGRIDAD Y COORDINACIÓN
-- ==============================================================================

-- Trigger: Al hacer INSERT en game_events, crear entrada en event_outbox (Transactional Outbox)
CREATE TRIGGER IF NOT EXISTS trg_outbox_on_event
    AFTER INSERT ON game_events
BEGIN
    INSERT INTO event_outbox(game_id, event_id, tx_id, topic, payload, target_nodes, vector_clock)
    VALUES (
        NEW.game_id,
        NEW.event_id,
        NEW.tx_id,
        'game.events',
        json_object('event_id', NEW.event_id, 'type', NEW.type,
                    'clock_ms', NEW.clock_ms, 'team_id', NEW.team_id,
                    'player_name', NEW.player_name, 'quarter', NEW.quarter),
        '[1,2,3]',
        NEW.vector_clock
    );
END;

-- Trigger: Detectar posible deadlock entre nodos (ciclo waiter→holder)
CREATE TRIGGER IF NOT EXISTS trg_deadlock_detect
    AFTER INSERT ON lock_waiters
BEGIN
    -- Si el nodo que retiene el lock que yo espero TAMBIÉN está esperando un lock que YO tengo → deadlock
    INSERT INTO deadlock_graph(waiter_node, holder_node, lock_id, game_id)
    SELECT NEW.waiter_node, dl.holder_node, NEW.lock_id, dl.game_id
    FROM distributed_locks dl
    JOIN lock_waiters existing_wait ON existing_wait.lock_id != NEW.lock_id
         AND existing_wait.waiter_node = dl.holder_node
         AND existing_wait.wait_type = 'BLOCKED'
    JOIN distributed_locks my_lock ON my_lock.holder_node = NEW.waiter_node
         AND existing_wait.lock_id = my_lock.lock_id
    WHERE dl.lock_id = NEW.lock_id
      AND dl.holder_node IS NOT NULL;
END;

-- Trigger: Expirar transacciones 2PC que superaron su timeout
CREATE TRIGGER IF NOT EXISTS trg_tx_timeout_check
    AFTER INSERT ON transaction_log
BEGIN
    UPDATE transaction_log
    SET phase = 'ABORT',
        error_msg = 'TIMEOUT: transacción expiró antes de alcanzar PREPARED'
    WHERE timeout_at < DATETIME('NOW')
      AND phase NOT IN ('COMMITTED','ABORTED','COMPENSATED');
END;

-- Trigger: Actualizar version y last_updated en games al modificar
CREATE TRIGGER IF NOT EXISTS trg_games_occ
    AFTER UPDATE ON games
BEGIN
    UPDATE games
    SET version      = OLD.version + 1,
        last_updated = STRFTIME('%Y-%m-%d %H:%M:%f','NOW')
    WHERE game_id = OLD.game_id;
END;

-- Trigger: Mover a DLQ si outbox supera max_attempts
CREATE TRIGGER IF NOT EXISTS trg_outbox_to_dlq
    AFTER UPDATE OF attempts ON event_outbox
    WHEN NEW.attempts >= NEW.max_attempts AND NEW.status != 'DEAD'
BEGIN
    UPDATE event_outbox SET status = 'DEAD' WHERE outbox_id = NEW.outbox_id;
    INSERT INTO event_dead_letter(outbox_id, game_id, event_id, topic, payload, total_attempts)
    VALUES (NEW.outbox_id, NEW.game_id, NEW.event_id, NEW.topic, NEW.payload, NEW.attempts);
END;

-- Trigger: CRDT merge en player_game_stats (Last-Write-Wins por version)
CREATE TRIGGER IF NOT EXISTS trg_pgs_crdt
    BEFORE UPDATE ON player_game_stats
    WHEN NEW.version <= OLD.version AND NEW.node_updated != OLD.node_updated
BEGIN
    SELECT RAISE(IGNORE);  -- descartar escritura obsoleta
END;

-- ==============================================================================
-- DATOS INICIALES (SEED)
-- ==============================================================================

INSERT OR IGNORE INTO teams(team_id, full_name, city, conference, division) VALUES
    ('LAL','Los Angeles Lakers','Los Angeles','West','Pacific'),
    ('BOS','Boston Celtics','Boston','East','Atlantic');

-- Inicializar distributed_locks para los recursos críticos del sistema
INSERT OR IGNORE INTO distributed_locks(lock_id, game_id, resource_type, lock_type) VALUES
    ('score:NBA_LAL_BOS_2026',     'NBA_LAL_BOS_2026', 'SCORE',     'EXCLUSIVE'),
    ('stats:LAL',                  'NBA_LAL_BOS_2026', 'STATS',     'EXCLUSIVE'),
    ('stats:BOS',                  'NBA_LAL_BOS_2026', 'STATS',     'EXCLUSIVE'),
    ('queue:NBA_LAL_BOS_2026',     'NBA_LAL_BOS_2026', 'QUEUE',     'EXCLUSIVE'),
    ('possession:NBA_LAL_BOS_2026','NBA_LAL_BOS_2026', 'POSSESSION','EXCLUSIVE'),
    ('clock:NBA_LAL_BOS_2026',     'NBA_LAL_BOS_2026', 'CLOCK',     'SHARED'),
    ('ai:NBA_LAL_BOS_2026',        'NBA_LAL_BOS_2026', 'AI',        'EXCLUSIVE');

-- Inicializar circuit breakers (uno por nodo)
INSERT OR IGNORE INTO circuit_breaker(node_id, state) VALUES (0,'CLOSED'),(1,'CLOSED'),(2,'CLOSED'),(3,'CLOSED');

-- Inicializar nodos del clúster
INSERT OR IGNORE INTO node_health(node_id, role, shard_ids, status, last_heartbeat) VALUES
    (0,'PRIMARY',       '[0,1,2,3,4]','UP',CURRENT_TIMESTAMP),
    (1,'REPLICA_SYNC',  '[1,2,3]',    'UP',CURRENT_TIMESTAMP),
    (2,'REPLICA_ASYNC', '[2]',        'UP',CURRENT_TIMESTAMP),
    (3,'ANALYTICS',     '[4]',        'UP',CURRENT_TIMESTAMP);

-- Inicializar vector clocks en cero para cada nodo
INSERT OR IGNORE INTO vector_clocks(game_id, node_id) VALUES
    ('NBA_LAL_BOS_2026',0),('NBA_LAL_BOS_2026',1),
    ('NBA_LAL_BOS_2026',2),('NBA_LAL_BOS_2026',3);
