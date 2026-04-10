const fs = require('fs');

const origPath = 'c:\\Users\\franc\\OneDrive\\Escritorio\\Aplicación en tiempo real.html';
const destPath = 'index.html'; // In current directory

let content = fs.readFileSync(origPath, 'utf8');

const aiHtml = `

            <!-- ANÁLISIS PREDICTIVO (CONCURRENTE) -->
            <div class="card" style="border-left: 4px solid #9c27b0;">
                <h2 style="color: #e0e0e0;">🧠 Análisis Predictivo (IA Concurrente)</h2>
                <div style="display: flex; flex-direction: column; gap: 15px;">
                    <div>
                        <div style="display: flex; justify-content: space-between; margin-bottom: 5px; font-size: 14px;">
                            <span>Lakers Victoria: <strong id="prob-home">50%</strong></span>
                            <span>Celtics Victoria: <strong id="prob-away">50%</strong></span>
                        </div>
                        <div style="height: 24px; background: #333; border-radius: 12px; overflow: hidden; display: flex;">
                            <div id="bar-home" style="width: 50%; background: #17408b; transition: width 0.5s ease;"></div>
                            <div id="bar-away" style="width: 50%; background: #4caf50; transition: width 0.5s ease;"></div>
                        </div>
                    </div>
                    <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px;">
                        <div style="background: rgba(255,255,255,0.05); padding: 10px; border-radius: 6px; text-align: center;">
                            <div style="font-size: 11px; color: #aaa;">PROYECCIÓN FINAL</div>
                            <div id="proj-score" style="font-size: 16px; font-weight: bold; color: #ffeb3b;">-- / --</div>
                        </div>
                        <div style="background: rgba(255,255,255,0.05); padding: 10px; border-radius: 6px; text-align: center;">
                            <div style="font-size: 11px; color: #aaa;">ESCENARIOS SIMULADOS</div>
                            <div id="scenarios-count" style="font-size: 16px; font-weight: bold; color: #ff9800;">0</div>
                        </div>
                        <div style="background: rgba(255,255,255,0.05); padding: 10px; border-radius: 6px; text-align: center;">
                            <div style="font-size: 11px; color: #aaa;">CARGA WORKER</div>
                            <div id="worker-load" style="font-size: 16px; font-weight: bold; color: #4caf50;">0ms</div>
                        </div>
                    </div>
                    <div>
                        <h4 style="font-size:12px; color:#999; margin-bottom:5px;">Rastros de Algoritmo Recursivo:</h4>
                        <div id="recursionLogs" style="background:#111; border-radius:4px; padding:10px; font-family:monospace; font-size:11px; color:#4caf50; height:120px; overflow-y:auto; border: 1px solid #333;">
                            Esperando datos de simulación concurrente...
                        </div>
                    </div>
                </div>
            </div>
`;

// Insert the AI HTML 
content = content.replace(
    '<h2>📈 Métricas del Sistema RT</h2>',
    aiHtml + '\n                <h2>📈 Métricas del Sistema RT</h2>'
);

const workerJs = `
        // --- INICIO WORKER IA CONCURRENTE ---
        const workerCode = \`
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
        \`;

        const blob = new Blob([workerCode], { type: 'application/javascript' });
        const workerUrl = URL.createObjectURL(blob);
        const aiWorker = new Worker(workerUrl);

        aiWorker.onmessage = function(e) {
            const { action, prediction } = e.data;
            if (action === 'PREDICTION_RESULT') {
                document.getElementById('prob-home').textContent = (prediction.winProbHome * 100).toFixed(0) + '%';
                document.getElementById('bar-home').style.width = (prediction.winProbHome * 100) + '%';
                
                document.getElementById('prob-away').textContent = (prediction.winProbAway * 100).toFixed(0) + '%';
                document.getElementById('bar-away').style.width = (prediction.winProbAway * 100) + '%';
                
                document.getElementById('proj-score').textContent = prediction.projectedScoreHome + ' - ' + prediction.projectedScoreAway;
                document.getElementById('scenarios-count').textContent = prediction.scenariosTested.toLocaleString();
                document.getElementById('worker-load').textContent = prediction.executionTime.toFixed(1) + 'ms';
                
                document.getElementById('recursionLogs').innerHTML = prediction.logs.map(l => '<div>' + l + '</div>').join('');
            }
        };
        // --- FIN WORKER IA CONCURRENTE ---
`;

// Insert the worker JS right before "let game = new NBAGame();"
content = content.replace(
    'let game = new NBAGame();',
    workerJs + '\n\n        let game = new NBAGame();'
);

// Add lastAiUpdate to constructor
content = content.replace(
    'this.quarter = 1;',
    'this.quarter = 1;\n                this.lastAiUpdate = 0;'
);
content = content.replace(
    'this.quarter = 1;',
    'this.quarter = 1;\n                this.lastAiUpdate = 0;'
); // Will handle reset() method too

// Inject the worker trigger into the game loop
const workerTrigger = `
                    // --- CONCURRENCIA ---
                    if (!this.lastAiUpdate || (this.lastAiUpdate - this.clockMs) >= 3000) {
                        this.lastAiUpdate = this.clockMs;
                        console.log("Main: Requesting AI Prediction...");
                        aiWorker.postMessage({
                            action: 'PREDICT_OUTCOME',
                            data: {
                                homeScore: this.score.home,
                                awayScore: this.score.away,
                                timeLeft: (4 - this.quarter) * 12 * 60 * 1000 + this.clockMs,
                                possession: this.possession
                            }
                        });
                    }
                    if (this.clockMs <= 0) {
`;

// Only replace the first occurrence inside startGameLoop!
const regex = /if \(this\.clockMs <= 0\) \{/;
content = content.replace(regex, workerTrigger);

fs.writeFileSync(destPath, content);
console.log('Fusion completed successfully.');
