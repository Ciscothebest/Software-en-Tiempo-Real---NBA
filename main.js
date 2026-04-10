/**
 * LÓGICA PRINCIPAL - NBA REAL-TIME SYSTEM (V1.1)
 * Gestiona la simulación, los hilos de ejecución (concurrencia) 
 * y la exclusión mutua (semáforos).
 */

// 1. SEMÁFOROS DE DIJKSTRA (Implementación de Exclusión Mutua)
class Semaphore {
    constructor(initialValue = 1, id = 'Mutex') {
        this.counter = initialValue;
        this.queue = [];
        this.id = id;
        this.waitCalls = 0;
        this.signalCalls = 0;
    }

    wait(callback) {
        this.waitCalls++;
        if (this.counter > 0) {
            this.counter--;
            callback(); // Adquirir de inmediato
        } else {
            this.queue.push(callback); // Encolar proceso
        }
        this.updateStats();
    }

    signal() {
        this.signalCalls++;
        if (this.queue.length > 0) {
            const nextInQueue = this.queue.shift();
            nextInQueue(); // Desbloquear proceso en cola
        } else {
            this.counter++; // Liberar valor
        }
        this.updateStats();
    }

    updateStats() {
        const el = document.getElementById(`sem-${this.id.toLowerCase()}-state`);
        if (el) el.textContent = this.counter > 0 ? 'OPEN' : 'LOCKED';
        
        // Métricas globales
        const waitEl = document.getElementById('metricSemWait');
        if (waitEl) waitEl.textContent = (parseInt(waitEl.textContent) || 0) + 1;
        const signalEl = document.getElementById('metricSemSignal');
        if (signalEl) signalEl.textContent = (parseInt(signalEl.textContent) || 0) + 1;
    }
}

// 2. CONCURRENCIA: Inicializar Web Worker como BLOB (Compatible con file://)
const workerCode = `
self.onmessage = function(e) {
    const { action, data } = e.data;
    if (action === 'PREDICT_OUTCOME') {
        const t0 = performance.now();
        const prediction = runRecursiveSimulation(
            data.homeScore, 
            data.awayScore, 
            data.timeLeft / 1000,
            data.possession,
            0
        );
        const t1 = performance.now();
        self.postMessage({
            action: 'PREDICTION_RESULT',
            prediction: {
                winProbHome: prediction.winProbHome,
                winProbAway: 1 - prediction.winProbHome,
                projectedScoreHome: Math.round(data.homeScore + prediction.projPointsHome),
                projectedScoreAway: Math.round(data.awayScore + prediction.projPointsAway),
                scenariosTested: prediction.scenarios,
                executionTime: t1 - t0,
                recursionDepth: prediction.maxDepthReached,
                logs: prediction.traces
            }
        });
    }
};

function runRecursiveSimulation(hS, aS, time, poss, depth) {
    const MAX_DEPTH = 16;
    const AVG_POSSESSION_TIME = 15;
    const traces = [];
    let scenarios = 0;

    function recurse(h, a, t, p, d) {
        scenarios++;
        if (t <= 0) return h > a ? 1 : 0; 
        if (d >= MAX_DEPTH) {
            return (h + (h/200)*t) > (a + (a/200)*t) ? 0.6 : 0.4;
        }
        const pMake = 0.45;
        const pMiss = 0.55;
        const pts = 2.2; 
        if (p === 'home') {
            const outcomeMake = recurse(h + pts, a, t - AVG_POSSESSION_TIME, 'away', d + 1);
            const outcomeMiss = recurse(h, a, t - AVG_POSSESSION_TIME, 'away', d + 1);
            const winRate = (outcomeMake * pMake) + (outcomeMiss * pMiss);
            if (d < 3) traces.push("[D" + d + "] Prob. Victoria Home: " + (winRate * 100).toFixed(1) + "%");
            return winRate;
        } else {
            const outcomeMake = recurse(h, a + pts, t - AVG_POSSESSION_TIME, 'home', d + 1);
            const outcomeMiss = recurse(h, a, t - AVG_POSSESSION_TIME, 'home', d + 1);
            return (outcomeMake * pMake) + (outcomeMiss * pMiss);
        }
    }

    const finalWinProb = recurse(hS, aS, time, poss, 0);
    const remainingPossessions = time / AVG_POSSESSION_TIME;
    return {
        winProbHome: finalWinProb,
        projPointsHome: 1.1 * remainingPossessions * (poss === 'home' ? 0.6 : 0.4),
        projPointsAway: 1.1 * remainingPossessions * (poss === 'away' ? 0.6 : 0.4),
        scenarios: scenarios,
        maxDepthReached: MAX_DEPTH,
        traces: traces.slice(0, 15)
    };
}
`;

const blob = new Blob([workerCode], { type: 'application/javascript' });
const workerUrl = URL.createObjectURL(blob);
const aiWorker = new Worker(workerUrl);

aiWorker.onmessage = function(e) {
    const { action, prediction } = e.data;
    if (action === 'PREDICTION_RESULT') {
        updateAIPredictions(prediction);
    }
};

// 3. ESTADO DEL JUEGO
const game = {
    state: 'stopped', // stopped, playing, paused, final
    quarter: 1,
    clockMs: 12 * 60 * 1000,
    score: { home: 0, away: 0 },
    possession: 'home',
    speed: 1,
    eventsCount: 0,
    interval: null,
    
    // Semáforos para secciones críticas
    sem: {
        queue: new Semaphore(1, 'Queue'),
        stats: new Semaphore(1, 'Stats'),
        score: new Semaphore(1, 'Score')
    }
};

// 4. FUNCIONES DE CONTROL
function startGame() {
    if (game.state === 'playing') return;
    game.state = 'playing';
    document.getElementById('btnStart').disabled = true;
    document.getElementById('btnPause').disabled = false;
    document.getElementById('gameStatus').textContent = 'EN VIVO';
    document.getElementById('gameStatus').className = 'status status-live';
    
    runGameLoop();
}

function pauseGame() {
    game.state = 'paused';
    clearInterval(game.interval);
    document.getElementById('btnStart').disabled = false;
    document.getElementById('btnPause').disabled = true;
    document.getElementById('gameStatus').textContent = 'PAUSADO';
    document.getElementById('gameStatus').className = 'status status-paused';
}

function resetGame() {
    location.reload();
}

function changeSpeed() {
    const slider = document.getElementById('speedControl');
    game.speed = parseInt(slider.value);
    document.getElementById('speedValue').textContent = `${game.speed}x`;
    
    if (game.state === 'playing') {
        clearInterval(game.interval);
        runGameLoop();
    }
}

// 5. BUCLE DE JUEGO (Simulación en Hilo Principal)
function runGameLoop() {
    const TICK_DELAY = 100 / game.speed;
    
    game.interval = setInterval(() => {
        try {
            if (game.state !== 'playing') return;

            // Avance del reloj (100ms por pulso)
            game.clockMs -= 100;
            
            // Lógica de Evento Aleatorio (Probabilidad ajustada para ticks de 100ms)
            if (Math.random() < 0.008) {
                handleGameEvent();
            }

            // --- CONCURRENCIA ---
            // Solicitar predicción al Web Worker cada 3 segundos de juego (Aprox)
            if (!game.lastAiUpdate || (game.lastAiUpdate - game.clockMs) >= 3000) {
                game.lastAiUpdate = game.clockMs;
                console.log("Main: Requesting AI Prediction (Concurrent)...");
                aiWorker.postMessage({
                    action: 'PREDICT_OUTCOME',
                    data: {
                        homeScore: game.score.home,
                        awayScore: game.score.away,
                        timeLeft: (4 - game.quarter) * 12 * 60 * 1000 + game.clockMs,
                        possession: game.possession
                    }
                });
            }

            // Final del cuarto
            if (game.clockMs <= 0) {
                if (game.quarter < 4) {
                    game.quarter++;
                    game.clockMs = 12 * 60 * 1000;
                    addLog('FIN DE CUARTO', `Iniciando Cuarto ${game.quarter}...`);
                } else {
                    game.state = 'final';
                    clearInterval(game.interval);
                    addLog('GAME OVER', 'El partido ha finalizado.');
                    document.getElementById('gameStatus').textContent = 'FINAL';
                    document.getElementById('gameStatus').className = 'status status-final';
                }
            }
            
            updateUI();
        } catch (err) {
            console.error("Critical Runtime Error:", err);
            pauseGame();
        }
    }, TICK_DELAY);
}

// 6. MANEJO DE EVENTOS (Uso de Semáforos)
function handleGameEvent() {
    const eventType = Math.random() < 0.8 ? 'SHOT' : 'TURNOVER';
    
    // SECCIÓN CRÍTICA: Proteger actualización de estadísticas y marcador
    game.sem.score.wait(() => {
        if (eventType === 'SHOT') {
            const made = Math.random() < 0.45;
            if (made) {
                const points = Math.random() < 0.3 ? 3 : 2;
                game.score[game.possession] += points;
                addLog('ANOTACIÓN', `${game.possession.toUpperCase()} encesta ${points} puntos!`, 'shot');
                // Cambio de posesión
                game.possession = game.possession === 'home' ? 'away' : 'home';
            } else {
                addLog('FALLO', `${game.possession.toUpperCase()} ha errat el tiro.`, 'miss');
                // Rebote (Cambio o retención)
                if (Math.random() < 0.7) game.possession = game.possession === 'home' ? 'away' : 'home';
            }
        } else {
            addLog('TURNOVER', `${game.possession.toUpperCase()} ha perdido el balón.`, 'turnover');
            game.possession = game.possession === 'home' ? 'away' : 'home';
        }
        
        game.eventsCount++;
        document.getElementById('metricProcessed').textContent = game.eventsCount;
        
        // Liberar recurso compartilhado
        game.sem.score.signal();
    });
}

// 7. ACTUALIZACIÓN UI
function updateUI() {
    document.getElementById('homeScore').textContent = game.score.home;
    document.getElementById('awayScore').textContent = game.score.away;
    
    const min = Math.floor(game.clockMs / 60000);
    const sec = Math.floor((game.clockMs % 60000) / 1000);
    document.getElementById('gameClock').textContent = `${min}:${sec.toString().padStart(2, '0')}`;
    document.getElementById('quarterInfo').textContent = `CUARTO ${game.quarter}`;
    
    document.getElementById('homePossession').style.display = game.possession === 'home' ? 'block' : 'none';
    document.getElementById('awayPossession').style.display = game.possession === 'away' ? 'block' : 'none';
}

function addLog(type, msg, styleClass = '') {
    const logEl = document.getElementById('eventLog');
    const entry = document.createElement('div');
    entry.className = `event-entry ${styleClass}`;
    entry.innerHTML = `<span><strong>${type}:</strong> ${msg}</span><span style="opacity:0.6">${document.getElementById('gameClock').textContent}</span>`;
    
    logEl.prepend(entry);
    if (logEl.children.length > 50) logEl.lastChild.remove();
}

function updateAIPredictions(pred) {
    // Actualizar Barras de Probabilidad
    const homeBar = document.getElementById('prob-home');
    const awayBar = document.getElementById('prob-away');
    
    homeBar.style.width = `${pred.winProbHome * 100}%`;
    homeBar.textContent = `${(pred.winProbHome * 100).toFixed(0)}%`;
    
    awayBar.style.width = `${pred.winProbAway * 100}%`;
    awayBar.textContent = `${(pred.winProbAway * 100).toFixed(0)}%`;
    
    // Proyección
    document.getElementById('proj-score').textContent = `${pred.projectedScoreHome} - ${pred.projectedScoreAway}`;
    document.getElementById('scenarios-count').textContent = pred.scenariosTested.toLocaleString();
    document.getElementById('worker-load').textContent = `${pred.executionTime.toFixed(1)}ms`;
    
    // Logs de recursión
    const logContainer = document.getElementById('recursionLogs');
    logContainer.innerHTML = pred.logs.map(l => `<div>${l}</div>`).join('');
    
    // Status visual
    const aiStatus = document.getElementById('ai-status');
    aiStatus.className = 'status-pill status-live';
    document.querySelector('#ai-status .status-text').textContent = 'AI Prediction: ACTIVE';
}
