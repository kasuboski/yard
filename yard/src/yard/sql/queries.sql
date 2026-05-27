-- -- Providers -------------------------------------------------

-- name: GetProvider :one
SELECT id, api_key, base_url, model
FROM providers
LIMIT 1;

-- name: SaveProvider :exec
DELETE FROM providers;

-- name: InsertProvider :exec
INSERT INTO providers (id, api_key, base_url, model, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?);

-- -- Agents ----------------------------------------------------

-- name: ListAgents :many
SELECT id, name, status, actor_hash
FROM agents
ORDER BY updated_at DESC;

-- name: GetAgent :one
SELECT id, name, description, chute_source, actor_hash, status
FROM agents
WHERE id = ?;

-- name: GetAgentByName :one
SELECT id, name, description, chute_source, actor_hash, status
FROM agents
WHERE name = ?;

-- name: InsertAgent :exec
INSERT INTO agents (id, name, description, chute_source, actor_hash, status, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?);

-- name: UpdateAgentStatus :exec
UPDATE agents SET status = ?, updated_at = ?
WHERE id = ?;

-- -- Agent Handlers --------------------------------------------

-- name: GetAgentHandlers :many
SELECT effect_name, handler_name
FROM agent_handlers
WHERE agent_id = ?;

-- name: InsertAgentHandler :exec
INSERT INTO agent_handlers (id, agent_id, effect_name, handler_name, created_at)
VALUES (?, ?, ?, ?, ?);

-- -- Skills ----------------------------------------------------

-- name: ListSkills :many
SELECT id, name, description, tags, status
FROM skills
WHERE status = 'active'
ORDER BY updated_at DESC;

-- name: GetSkill :one
SELECT id, name, description, chute_source, tags, status
FROM skills
WHERE id = ?;

-- name: GetSkillByName :one
SELECT id, name, description, chute_source, tags, status
FROM skills
WHERE name = ?;

-- name: InsertSkill :exec
INSERT INTO skills (id, name, description, chute_source, tags, status, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?);

-- name: UpdateSkill :exec
UPDATE skills SET description = ?, chute_source = ?, tags = ?, updated_at = ?
WHERE id = ?;

-- name: DeactivateSkill :exec
UPDATE skills SET status = 'inactive', updated_at = ?
WHERE id = ?;

-- -- Schedules -------------------------------------------------

-- name: ListActiveSchedules :many
SELECT id, agent_id, skill_id, cron_expr, status, last_fired_at, next_fire_at
FROM schedules
WHERE status = 'active'
ORDER BY next_fire_at ASC;

-- name: GetSchedule :one
SELECT id, agent_id, skill_id, cron_expr, status, last_fired_at, next_fire_at
FROM schedules
WHERE id = ?;

-- name: InsertSchedule :exec
INSERT INTO schedules (id, agent_id, skill_id, cron_expr, status, next_fire_at, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?);

-- name: UpdateScheduleFire :exec
UPDATE schedules SET last_fired_at = ?, next_fire_at = ?, updated_at = ?
WHERE id = ?;

-- name: DeactivateSchedule :exec
UPDATE schedules SET status = 'inactive', updated_at = ?
WHERE id = ?;

-- -- Deployments -----------------------------------------------

-- name: ListDeployments :many
SELECT id, agent_id, trigger_type, status
FROM deployments
WHERE status = 'active'
ORDER BY deployed_at DESC;

-- -- Runs ------------------------------------------------------

-- name: GetActorRuns :many
SELECT id, status, trigger_type, COALESCE(result, '') as result, COALESCE(duration_ms, 0) as duration_ms, started_at
FROM runs
WHERE agent_id = ?
ORDER BY started_at DESC
LIMIT ?;

-- name: InsertRun :exec
INSERT INTO runs (id, agent_id, deployment_id, trigger_type, trigger_source, status, started_at)
VALUES (?, ?, ?, ?, ?, ?, ?);

-- name: CompleteRun :exec
UPDATE runs SET status = ?, result = ?, gas_used = ?, duration_ms = ?, completed_at = ?
WHERE id = ?;

-- -- Chat Sessions ---------------------------------------------

-- name: GetActiveSession :one
SELECT id
FROM chat_sessions
WHERE status = 'active'
ORDER BY created_at DESC
LIMIT 1;

-- name: GetSessionByUserKey :one
SELECT id
FROM chat_sessions
WHERE user_key = ? AND status = 'active'
LIMIT 1;

-- name: CreateSessionWithUserKey :exec
INSERT INTO chat_sessions (id, user_key, status, created_at, updated_at)
VALUES (?, ?, 'active', ?, ?);

-- name: CreateSession :exec
INSERT INTO chat_sessions (id, status, created_at, updated_at)
VALUES (?, 'active', ?, ?);

-- name: CompleteSession :exec
UPDATE chat_sessions SET status = 'completed', updated_at = ?
WHERE id = ?;

-- name: SaveChatMessage :exec
INSERT INTO chat_messages (id, session_id, role, content, created_at)
VALUES (?, ?, ?, ?, ?);

-- name: GetChatMessages :many
SELECT id, content, role, created_at
FROM chat_messages
WHERE session_id = ?
ORDER BY created_at ASC;

-- name: GetRecentMessages :many
SELECT id, content, role, created_at
FROM chat_messages
WHERE session_id = ?
ORDER BY rowid DESC
LIMIT ?;
