# 🏀 Infraestructura de Datos Distribuida — NBA Real-Time System v3.0
> Ingeniería de Software en Tiempo Real · UNIBE  
> Incluye: Entidades · Relaciones · Restricciones · Sincronización · Transacciones

---

## 1. Arquitectura General del Sistema

### 1.1 Topología del Clúster

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CLÚSTER NBA-RT (4 Nodos)                     │
│                                                                     │
│  ┌──────────────┐  Repl. Síncrona  ┌──────────────┐                │
│  │   NODO 0     │ ────────────────► │   NODO 1     │                │
│  │  PRIMARY     │                  │ REPLICA_SYNC  │                │
│  │  Shards 0-4  │ ────────────────► │  Shards 1-3  │                │
│  └──────┬───────┘  Repl. Asíncrona └──────────────┘                │
│         │                                                           │
│         │           Repl. Async    ┌──────────────┐                │
│         └────────────────────────► │   NODO 2     │                │
│                                    │ REPLICA_ASYNC │                │
│                                    │   Shard 2    │                │
│                                    └──────────────┘                │
│                                                                     │
│                                    ┌──────────────┐                │
│                                    │   NODO 3     │                │
│                                    │  ANALYTICS   │                │
│                                    │   Shard 4    │                │
│                                    └──────────────┘                │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 Capas del Sistema

| Capa | Propósito | Tablas |
|------|-----------|--------|
| **Maestros** | Catálogo estático, raramente mutable | `teams`, `players` |
| **Partidos** | Estado transaccional del juego activo | `games`, `game_quarters` |
| **Eventos RT** | Stream de jugadas en tiempo real | `game_events`, `cold_events` |
| **Estadísticas** | G-Counter CRDT por jugador | `player_game_stats` |
| **Analítica IA** | Proyecciones del Web Worker recursivo | `ai_projections`, `system_exceptions` |
| **Sincronización** | Mecanismos de coordinación inter-nodo | `distributed_locks`, `lock_waiters`, `deadlock_graph` |
| **Transacciones** | 2PC + Saga: atomicidad distribuida | `transaction_log`, `tx_participants`, `saga_log`, `saga_steps` |
| **Entrega** | Garantías at-least-once + DLQ | `event_outbox`, `event_dead_letter`, `delivery_ack` |
| **Coherencia** | Orden causal y quórum de escritura | `vector_clocks`, `quorum_state` |
| **Disponibilidad** | Circuit breaker + failover | `circuit_breaker`, `node_health`, `failover_log` |
| **Control** | Auditoría y replicación | `semaphore_transactions`, `replication_log` |

---

## 2. Modelo Entidad-Relación Completo (ERD)

### 2.1 Diagrama de Entidades Principales

```
┌──────────┐         ┌──────────┐         ┌──────────────────┐
│  teams   │────────<│  players │         │   node_health    │
│ (PK:id)  │  1:N    │(PK:id)   │         │ (PK: node_id)    │
└──────┬───┘         └──────────┘         └────────┬─────────┘
       │                                           │
       │(1)                                        │(1)
       │                                           │
┌──────▼───────────────────────────────────────────▼─────────┐
│                         games                              │
│  PK: game_id                                               │
│  FK: home_team_id → teams(team_id)                         │
│  FK: away_team_id → teams(team_id)                         │
│  Atributos: quarter, clock_ms, home_score, away_score,     │
│             possession, status, version, checksum          │
└──────┬─────────────────────────────────────────────────────┘
       │(1)
       │
       ├──────────────────────────────────────────────────────┐
       │                                                      │
  ┌────▼────────┐  ┌──────────────┐  ┌───────────────────┐   │
  │game_quarters│  │  game_events │  │player_game_stats  │   │
  │(PK:id)      │  │(PK:event_id) │  │(PK:id)            │   │
  │FK:game_id   │  │FK:game_id    │  │FK:game_id         │   │
  │FK:quarter   │  │FK:team_id    │  │FK:team_id         │   │
  └─────────────┘  │FK:tx_id      │  │CRDT: version,     │   │
                   └──────┬───────┘  │node_updated       │   │
                          │          └───────────────────┘   │
                     ┌────▼────────────────────────────────  │
                     │  event_outbox                         │
                     │  (PK: outbox_id)                      │
                     │  FK: event_id → game_events           │
                     │  FK: tx_id → transaction_log          │
                     └────┬──────────────────────────────────│
                          │                                  │
                   ┌──────▼─────────┐  ┌──────────────────┐ │
                   │ delivery_ack   │  │event_dead_letter │ │
                   │(FK:outbox_id)  │  │(FK:outbox_id)    │ │
                   └────────────────┘  └──────────────────┘ │
                                                             │
       ┌─────────────────────────────────────────────────────┘
       │
  ┌────▼───────────────────┐  ┌──────────────────────────────┐
  │   transaction_log      │  │        saga_log              │
  │ (PK: tx_id)            │  │ (PK: saga_id)                │
  │ FK: game_id → games    │  │ FK: game_id → games          │
  └──────┬─────────────────┘  └──────────────────────────────┘
         │                              │
  ┌──────▼──────────┐          ┌────────▼──────────────┐
  │ tx_participants  │          │     saga_steps        │
  │ (PK: id)        │          │ (PK: id)              │
  │ FK: tx_id       │          │ FK: saga_id           │
  └─────────────────┘          └───────────────────────┘
```

### 2.2 Diagrama ERD — Capa de Disponibilidad y Coherencia

```
┌──────────────────┐        ┌───────────────────────────┐
│  circuit_breaker │        │       vector_clocks       │
│ (PK: node_id)    │        │ (PK: id)                  │
│ JOIN node_health │        │ FK: game_id → games       │
└──────────────────┘        │ UNIQUE(game_id, node_id)  │
                            └───────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                  distributed_locks                      │
│ (PK: lock_id)                                           │
│ FK: game_id → games                                     │
└─────────────────────┬───────────────────────────────────┘
                      │ (1:N)
         ┌────────────┴──────────────┐
  ┌──────▼────────┐        ┌─────────▼──────────┐
  │ lock_waiters  │        │  deadlock_graph    │
  │ (PK: id)      │        │ (PK: id)           │
  │ FK: lock_id   │        │ FK: lock_id        │
  └───────────────┘        └────────────────────┘

┌────────────────────────────────────────┐
│            quorum_state                │
│ (PK: quorum_id)                        │
│ FK: tx_id → transaction_log            │
└────────────────────────────────────────┘
```

---

## 3. Catálogo completo de Entidades

### Capa 0 — Datos Maestros

#### `teams`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `team_id` | TEXT (PK) | Código del equipo ('LAL', 'BOS') |
| `full_name` | TEXT NOT NULL | Nombre completo |
| `city` | TEXT NOT NULL | Ciudad |
| `conference` | TEXT CHECK('East','West') | Conferencia |
| `division` | TEXT NOT NULL | División |
| `created_at` | DATETIME | Timestamp de registro |

#### `players`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `player_id` | INTEGER (PK, AUTOINCREMENT) | Identificador interno |
| `name` | TEXT NOT NULL | Nombre del jugador |
| `team_id` | TEXT FK→teams | Equipo al que pertenece |
| `position` | TEXT CHECK('PG','SG','SF','PF','C') | Posición |
| `rating` | INTEGER CHECK(50-99) | Rating de habilidad |
| `is_starter` | INTEGER DEFAULT 0 | Bandera titular |
| `active` | INTEGER DEFAULT 1 | Activo en el roster |

---

### Capa 1 — Partidos

#### `games`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `game_id` | TEXT (PK) | Identificador del partido |
| `shard_id` | INTEGER | Nodo de shard asignado |
| `home_team_id` | TEXT FK→teams | Equipo local |
| `away_team_id` | TEXT FK→teams | Equipo visitante |
| `quarter` | INTEGER CHECK(1-6) | Cuarto (5-6 = OT) |
| `clock_ms` | INTEGER | Ms restantes en el cuarto |
| `home_score` | INTEGER | Puntos local |
| `away_score` | INTEGER | Puntos visitante |
| `possession` | TEXT CHECK('home','away') | Posesión actual |
| `status` | TEXT CHECK('SCHEDULED'…'SUSPENDED') | Estado del partido |
| `version` | INTEGER DEFAULT 1 | Versión OCC (se auto-incrementa por trigger) |
| `checksum` | TEXT | Hash del estado para validación inter-nodo |

#### `game_quarters`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER (PK) | Autoincremental |
| `game_id` | TEXT FK→games | Partido |
| `quarter` | INTEGER CHECK(1-6) | Cuarto |
| `home_score` | INTEGER | Puntos del equipo local en este cuarto |
| `away_score` | INTEGER | Puntos del equipo visitante |
| `duration_ms` | INTEGER | Duración real del cuarto |
| **UNIQUE** | (game_id, quarter) | Un solo registro por cuarto |

---

### Capa 2 — Eventos en Tiempo Real

#### `game_events`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `event_id` | TEXT (PK) | ID único del evento (ej. 'EVT_042') |
| `game_id` | TEXT FK→games | Partido al que pertenece |
| `quarter` | INTEGER NOT NULL | Cuarto en que ocurrió |
| `clock_ms` | INTEGER NOT NULL | Reloj de juego |
| `event_time_ms` | INTEGER NOT NULL | Ms desde inicio del partido |
| `type` | TEXT CHECK(SHOT, REBOUND, FOUL…) | Tipo canónico |
| `shot_type` | TEXT CHECK('2PT','3PT','FT') | Solo si type='SHOT' |
| `shot_made` | INTEGER | 1=anotado, 0=fallado |
| `reb_type` | TEXT CHECK('DEF','OFF') | Solo si type='REBOUND' |
| `foul_type` | TEXT CHECK('PERSONAL','SHOOTING','TECHNICAL') | Solo si type='FOUL' |
| `latency_ms` | REAL **VIRTUAL GENERATED** | `processed_at_ms - received_at_ms` |
| `is_late` | INTEGER DEFAULT 0 | 1 si llegó fuera de orden |
| `tx_id` | TEXT FK→transaction_log | Transacción 2PC que lo originó |
| `vector_clock` | TEXT JSON | Estado del vector clock al crear el evento |

#### `player_game_stats`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER (PK) | Autoincremental |
| `game_id` | TEXT FK→games | Partido |
| `player_name` | TEXT NOT NULL | Jugador |
| `team_id` | TEXT FK→teams | Equipo |
| `pts, reb, ast…` | INTEGER | Contadores G-Counter (solo incrementan) |
| `version` | INTEGER | Número de versión para merge CRDT |
| `node_updated` | INTEGER | Nodo que actualizó por última vez |
| **UNIQUE** | (game_id, player_name) | Un registro por jugador por partido |

---

### Capa de Sincronización

#### `distributed_locks`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `lock_id` | TEXT (PK) | Recurso protegido ('score:game_id') |
| `resource_type` | TEXT CHECK('SCORE','STATS','QUEUE','POSSESSION','CLOCK','AI') | Tipo de recurso |
| `lock_type` | TEXT CHECK('EXCLUSIVE','SHARED','INTENT_EXCL') | Modo de exclusión |
| `holder_node` | INTEGER NULL | Nodo que retiene el lock; NULL = libre |
| `holder_tx_id` | TEXT | Transacción titular para trazabilidad |
| `expires_at` | DATETIME | TTL anti-deadlock |
| `waiter_count` | INTEGER | Nodos en espera (cola FIFO) |
| `acquire_count` | INTEGER | Historial de adquisiciones |

#### `lock_waiters`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER (PK) | Autoincremental |
| `lock_id` | TEXT FK→distributed_locks | Lock esperado |
| `waiter_node` | INTEGER | Nodo bloqueado |
| `waiter_tx` | TEXT | Transacción bloqueada |
| `wait_type` | TEXT CHECK('BLOCKED','TIMED_OUT','ACQUIRED','CANCELLED') | Estado de la espera |

#### `deadlock_graph`
Registra aristas del grafo Wait-For entre nodos. Un ciclo en este grafo = deadlock.

---

### Capa de Transacciones

#### `transaction_log`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `tx_id` | TEXT (PK) | UUID de la transacción |
| `tx_type` | TEXT CHECK('SHOT_MADE','TURNOVER','FOUL_CALL'…) | Tipo de operación |
| `coordinator_node` | INTEGER NOT NULL | Nodo coordinador del 2PC |
| `phase` | TEXT CHECK('INIT','PREPARE','PREPARED','COMMIT','COMMITTED','ABORT','ABORTED','RECOVERING') | Estado actual del 2PC |
| `participants` | TEXT JSON | Lista de nodos y shards participantes |
| `prepare_votes` | TEXT JSON | Votos recibidos en Phase 1 |
| `payload` | TEXT JSON | Datos de la transacción |
| `timeout_at` | DATETIME | Aborto automático si se supera |
| `vector_clock_at` | TEXT JSON | Vector clock al inicio (causalidad) |

#### `tx_participants`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `tx_id` | TEXT FK→transaction_log | Transacción |
| `node_id` | INTEGER | Nodo participante |
| `vote` | TEXT CHECK('PREPARE_OK','VOTE_COMMIT','VOTE_ABORT') | Voto de Phase 1 |
| `ack` | TEXT CHECK('COMMIT_ACK','ABORT_ACK') | Confirmación de Phase 2 |
| **UNIQUE** | (tx_id, node_id) | Un voto por nodo por transacción |

#### `saga_log` y `saga_steps`
Implementan el patrón Saga para transacciones largas con compensación.  
Cada `saga_step` tiene `action_type`, `action_payload` y su compensación (`compensation_type`, `compensation_payload`).

---

### Capa de Entrega

#### `event_outbox`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `outbox_id` | INTEGER (PK) | Autoincremental |
| `event_id` | TEXT UNIQUE | Clave de **idempotencia** |
| `tx_id` | TEXT FK→transaction_log | Transacción que lo generó |
| `topic` | TEXT | Canal de entrega ('game.events', 'game.stats', 'game.ai') |
| `status` | TEXT CHECK('PENDING','RELAYING','DELIVERED','FAILED','DEAD') | Estado en el pipeline |
| `target_nodes` | TEXT JSON | Nodos destino |
| `delivered_to` | TEXT JSON | Nodos que ya enviaron ACK |
| `attempts` | INTEGER | Reintentos realizados |
| `max_attempts` | INTEGER DEFAULT 5 | Límite antes de DLQ |
| `vector_clock` | TEXT JSON | Clock causal para garantizar orden en el receptor |

#### `event_dead_letter`
Eventos que superaron `max_attempts`. Permiten inspección manual y replay controlado.

---

### Capa de Coherencia

#### `vector_clocks`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `game_id` | TEXT FK→games | Contexto del partido |
| `node_id` | INTEGER | Nodo propietario de este registro |
| `clock_n0..n3` | INTEGER | Contador local de cada nodo |
| **UNIQUE** | (game_id, node_id) | Un vector clock por nodo por partido |

**Algoritmo de merge:**
```
Al recibir mensaje de nodo S:
  VC_receptor[i] = MAX(VC_receptor[i], VC_mensaje[i])  para todo i
  VC_receptor[receptor]++   (tick propio)
```

#### `quorum_state`
Registra el tracking de ACKs para cada escritura crítica.  
`required_acks = floor(N/2) + 1 = 3` con N=4 nodos.

---

### Capa de Disponibilidad

#### `circuit_breaker`
| Columna | Tipo | Descripción |
|---------|------|-------------|
| `node_id` | INTEGER (PK) | Nodo monitorizado |
| `state` | TEXT CHECK('CLOSED','OPEN','HALF_OPEN') | Estado del circuito |
| `failure_count` | INTEGER | Fallos consecutivos actuales |
| `failure_threshold` | INTEGER DEFAULT 5 | Límite para abrir el circuito |
| `timeout_sec` | INTEGER DEFAULT 30 | Tiempo en OPEN antes de probar HALF_OPEN |
| `total_opens` | INTEGER | Historial de aperturas |

**Máquina de estados:**
```
CLOSED ──(≥5 fallos)──► OPEN ──(30s)──► HALF_OPEN ──(2 éxitos)──► CLOSED
                                                    └─(1 fallo)──► OPEN
```

#### `node_health`, `failover_log`, `replication_log`
Control operativo: heartbeat, historial de failover y pipeline de replicación.

---

## 4. Relaciones y Cardinalidades

| Relación | Cardinalidad | Restricción |
|----------|-------------|-------------|
| `teams` → `players` | 1:N | FK obligatoria, ON DELETE RESTRICT |
| `teams` → `games` (home/away) | 1:N | Dos FK al mismo padre; NOT NULL |
| `games` → `game_quarters` | 1:N | UNIQUE(game_id, quarter); max 6 cuartos |
| `games` → `game_events` | 1:N | FK + índice compuesto (game_id, event_time_ms) |
| `games` → `player_game_stats` | 1:N | UNIQUE(game_id, player_name) |
| `games` → `ai_projections` | 1:N | Batch cada 3s de juego |
| `games` → `transaction_log` | 1:N | Cada tx tiene un coordinador y participantes |
| `transaction_log` → `tx_participants` | 1:N | UNIQUE(tx_id, node_id) |
| `transaction_log` → `game_events` | 1:N | game_events.tx_id → transaction_log (trazabilidad) |
| `transaction_log` → `event_outbox` | 1:N | Cada tx genera n entradas en outbox |
| `event_outbox` → `delivery_ack` | 1:N | Un ACK por nodo destino |
| `event_outbox` → `event_dead_letter` | 1:1 | Solo si attempts ≥ max_attempts |
| `saga_log` → `saga_steps` | 1:N | UNIQUE(saga_id, step_number); orden garantizado |
| `distributed_locks` → `lock_waiters` | 1:N | Cola FIFO; wait_type indica estado |
| `distributed_locks` → `deadlock_graph` | N:M | Grafo Wait-For; ciclo = deadlock |
| `node_health` → `circuit_breaker` | 1:1 | Un circuito por nodo |
| `quorum_state` → `transaction_log` | N:1 | Una votación por escritura crítica |
| `vector_clocks` → `games` | N:1 | UNIQUE(game_id, node_id) |

---

## 5. Restricciones de Integridad

### 5.1 Restricciones de Dominio (CHECK)

| Tabla.Columna | Restricción | Justificación |
|---------------|------------|---------------|
| `teams.conference` | IN ('East','West') | Solo dos conferencias NBA |
| `players.position` | IN ('PG','SG','SF','PF','C') | Posiciones reglamentarias |
| `players.rating` | BETWEEN 50 AND 99 | Escala de habilidad válida |
| `games.quarter` | BETWEEN 1 AND 6 | Cuartos 5-6 son overtime |
| `games.possession` | IN ('home','away') | Solo dos posibles poseedores |
| `games.status` | IN (SCHEDULED, LIVE, HALFTIME, FINAL, SUSPENDED) | Estados finitos del partido |
| `game_events.type` | IN (SHOT, REBOUND, ASSIST...) | Vocabulario canónico de eventos |
| `game_events.shot_type` | IN ('2PT','3PT','FT') OR NULL | Solo si es un tiro |
| `ai_projections.win_prob_*` | BETWEEN 0 AND 1 | Probabilidades válidas |
| `transaction_log.phase` | IN (INIT, PREPARE, PREPARED, COMMIT...) | FSM del protocolo 2PC |
| `distributed_locks.lock_type` | IN (EXCLUSIVE, SHARED, INTENT_EXCL) | Tipos de exclusión |
| `circuit_breaker.state` | IN (CLOSED, OPEN, HALF_OPEN) | FSM del circuit breaker |
| `system_exceptions.exception_type` | IN (late_event, deadlock_warning, dlq_overflow…) | Taxonomía cerrada |
| `quorum_state.operation` | IN (READ, WRITE) | Tipo de operación quórum |
| `tx_participants.vote` | IN (PREPARE_OK, VOTE_COMMIT, VOTE_ABORT) OR NULL | Votos 2PC válidos |

### 5.2 Restricciones de Unicidad

| Tabla | UNIQUE | Semántica |
|-------|--------|-----------|
| `game_quarters` | (game_id, quarter) | Solo un registro por cuarto por partido |
| `player_game_stats` | (game_id, player_name) | Un jugador una vez por partido |
| `tx_participants` | (tx_id, node_id) | Un voto por nodo por transacción |
| `saga_steps` | (saga_id, step_number) | Orden lineal dentro del saga |
| `delivery_ack` | (outbox_id, target_node) | Un ACK por nodo destino por mensaje |
| `vector_clocks` | (game_id, node_id) | Un vector clock por nodo por partido |
| `event_outbox` | event_id | **Clave de idempotencia** — mismo evento nunca dos veces |

### 5.3 Restricciones de Integridad Referencial (FK)

Todas las FK con `PRAGMA foreign_keys = ON`. Política general:

| Relación | ON DELETE | ON UPDATE | Justificación |
|----------|-----------|-----------|---------------|
| players → teams | RESTRICT | CASCADE | No eliminar un equipo con jugadores asociados |
| games → teams | RESTRICT | CASCADE | El partido referencia dos equipos |
| game_events → games | CASCADE | — | Al borrar un partido (histórico), expiran sus eventos |
| player_game_stats → games | CASCADE | — | Stats ligadas al partido |
| game_events → transaction_log | SET NULL | — | Evento puede existir sin tx si fue directo |
| event_outbox → transaction_log | SET NULL | — | Outbox válido aunque tx se archive |
| delivery_ack → event_outbox | CASCADE | — | ACKs se eliminan con el outbox |
| event_dead_letter → event_outbox | RESTRICT | — | DLQ conserva referencia al outbox original |
| saga_steps → saga_log | CASCADE | — | Pasos eliminados con el saga |
| tx_participants → transaction_log | CASCADE | — | Votos eliminados con la tx |
| lock_waiters → distributed_locks | CASCADE | — | Cola vacía al liberar el lock |
| quorum_state → transaction_log | SET NULL | — | Quórum puede sobrevivir al archive de tx |

### 5.4 Restricciones de Concurrencia (CRDT)

El trigger `trg_pgs_crdt` aplica la política **Last-Write-Wins por versión** en `player_game_stats`:

```sql
-- Regla: si la versión entrante ≤ versión local Y viene de otro nodo → IGNORAR
BEFORE UPDATE ON player_game_stats
WHEN NEW.version <= OLD.version AND NEW.node_updated != OLD.node_updated
→ RAISE(IGNORE)
```

**Merge semántico G-Counter:**
- Los contadores (`pts`, `reb`, `ast`…) son **monotónicamente crecientes**.
- El merge de dos réplicas es: `MAX(version_A, version_B)`.
- Nunca se decrementan → sin conflictos de escritura entre nodos.

### 5.5 Restricciones de Orden Causal (Vector Clocks)

Cada `game_events.vector_clock` captura el estado del reloj vectorial en el momento de creación. El receptor valida:

```
Si VC_evento[i] > VC_local[i] para algún i → evento TARDÍO (is_late = 1)
Si VC_evento ∥ VC_local               → eventos CONCURRENTES (log a system_exceptions)
Si VC_evento < VC_local en todo i     → evento DUPLICADO (is_duplicate = 1)
```

### 5.6 Restricciones Derivadas (Columnas Virtuales)

```sql
-- latency_ms: calculada automáticamente, nunca se escribe directamente
game_events.latency_ms GENERATED ALWAYS AS (
  CASE WHEN processed_at_ms IS NOT NULL
       THEN CAST(processed_at_ms - received_at_ms AS REAL)
       ELSE NULL END
) VIRTUAL
```

---

## 6. Mecanismos de Sincronización y su relación con las Entidades

### 6.1 Flujo 2-Phase Commit (SHOT_MADE)

```
game_events ──INSERT──► transaction_log (phase=INIT)
                              │
                         PHASE 1: PREPARE
                              │
               ┌──────────────┼────────────────┐
         ┌─────▼────┐  ┌──────▼──────┐  ┌──────▼──────┐
         │ Shard 1  │  │  Shard 2   │  │  Shard 3   │
         │ UPDATE   │  │  INSERT    │  │  UPDATE    │
         │ games    │  │game_events │  │player_stats│
         │ (score)  │  │            │  │ (pts, fgm) │
         └─────┬────┘  └──────┬──────┘  └──────┬──────┘
               │              │                │
         tx_participants.vote = VOTE_COMMIT (×3)
               │              │                │
               └──────────────┼────────────────┘
                         PHASE 2: COMMIT
                              │
                    quorum_state.quorum_reached = 1
                              │
                       event_outbox (PENDING)
                              │
                       delivery_ack (×3 nodos)
```

### 6.2 Flujo Saga (FOUL_WITH_FREE_THROWS)

```
Trigger: FOUL evento → saga_log (RUNNING)
  Step 1: register_foul     → player_game_stats.pf++
  Step 2: suspend_clock     → games.clock_ms congelado
  Step 3: emit_FT_1         → game_events (type=SHOT, shot_type=FT)
  Step 4: emit_FT_2         → game_events (type=SHOT, shot_type=FT)
  Step 5: resolve_possession→ games.possession actualizado

  Si Step 4 falla:           saga_log (COMPENSATING)
    Compensar Step 3: borrar FT_1 → game_events.is_duplicate = 1
    Compensar Step 2: restaurar clock
    Compensar Step 1: player.pf--
    saga_log (COMPENSATED)   → system_exceptions (saga_compensation)
```

### 6.3 Relación Lock–Semáforo–Transacción

```
distributed_locks.lock_id = 'score:NBA_LAL_BOS_2026'
       ↓
holder_tx_id → transaction_log.tx_id
       ↓
Si holder_node IS NULL → lock libre → transaction puede proceder
Si holder_node IS NOT NULL → INSERT en lock_waiters (Cola Dijkstra)
       ↓ (al RELEASE del holder)
trigger trg_deadlock_detect → deadlock_graph (si hay ciclo)
```

---

## 7. Políticas de Consistencia (CAP Theorem)

```
┌──────────────────────────────────────────────────────────┐
│  CP durante el partido activo (Consistency + Partition)  │
│                                                          │
│  Escrituras críticas (score, possession):                │
│    → 2PC con quórum N/2+1 = 3 nodos                     │
│    → Todos los participantes deben VOTE_COMMIT           │
│    → ACK obligatorio de Nodo 1 (síncrono)               │
│                                                          │
│  Lecturas analíticas (ai_projections):                  │
│    → Consistencia eventual: lag máximo ~500ms           │
│    → Nodo 3 puede tener datos ligeramente desactualizados│
│                                                          │
│  En split-brain (partición de red):                     │
│    → Nodo con mayor quórum continúa como PRIMARY         │
│    → El nodo aislado activa circuit_breaker OPEN        │
│    → Al reconectar: resync por vector_clock              │
└──────────────────────────────────────────────────────────┘
```

---

## 8. Índices y Optimización de Consultas

| Query | Índice | Latencia objetivo |
|-------|--------|-------------------|
| Play-by-play últimos eventos | `idx_events_game_time` | < 0.5ms |
| Transacciones activas (2PC) | `idx_tx_phase` (parcial: NOT COMMITTED) | < 0.3ms |
| Outbox pendiente de relay | `idx_outbox_pending` (parcial: PENDING/FAILED) | < 0.2ms |
| Locks expirados (anti-deadlock) | `idx_locks_expiry` (parcial: holder_node IS NOT NULL) | < 0.1ms |
| Circuit breakers OPEN | `idx_cb_state` (parcial: state != CLOSED) | < 0.1ms |
| Sagas activas | `idx_saga_active` (parcial: RUNNING/COMPENSATING) | < 0.2ms |
| Player stats por equipo on-court | `idx_pgs_game_team` | < 0.3ms |
| DLQ no reproducido | `idx_dlq_unreplayed` (parcial: replayed = 0) | < 0.1ms |

---

## 9. Benchmark de Rendimiento

| Operación | Latencia P50 | Latencia P99 | Throughput estimado |
|-----------|-------------|-------------|---------------------|
| INSERT game_events + outbox (atomico) | 0.4ms | 1.0ms | 2,500 tx/s |
| 2PC completo (prepare + commit) | 2ms | 8ms | 500 tx/s |
| Saga (5 pasos sin fallo) | 75ms | 200ms | 13 sagas/s |
| Lock acquire (recurso libre) | 0.1ms | 0.5ms | 10,000 ops/s |
| Lock acquire (con waiter) | 35ms | 100ms | 28 ops/s |
| Quórum write (3 ACKs) | 3ms | 12ms | 333 tx/s |
| Vector clock update | 0.05ms | 0.2ms | 20,000 ops/s |
| Circuit breaker check | 0.02ms | 0.1ms | 50,000 ops/s |

---

*Documento técnico generado para el proyecto NBA Real-Time Statistics System — UNIBE*  
*Ingeniería de Software en Tiempo Real — Versión 3.0*
