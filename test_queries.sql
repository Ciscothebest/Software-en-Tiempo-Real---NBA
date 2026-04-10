INSERT INTO games (game_id, home_team, away_team, status) VALUES ('GAME_111', 'LAKERS', 'CELTICS', 'VALIDATED_OK');
INSERT INTO game_events (event_id, game_id, quarter, clock_time, type, team, player, description) 
VALUES ('EVT_777', 'GAME_111', 1, '12:00', 'INTEGRITY_CHECK', 'Home', 'System', 'Data Pipeline Validated');
INSERT INTO semaphore_transactions (semaphore_id, operation, current_value, queue_length) 
VALUES ('Mutex_01', 'SIGNAL', 1, 0);
INSERT INTO ai_projections (game_id, clock_time, win_prob_home, win_prob_away, projected_score_home, projected_score_away, scenarios_simulated)
VALUES ('GAME_111', '12:00', 0.52, 0.48, 105, 102, 131000);
SELECT g.home_team, e.type, e.description FROM games g JOIN game_events e ON g.game_id = e.game_id;
SELECT * FROM semaphore_transactions;
SELECT * FROM ai_projections;
