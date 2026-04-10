/**
 * Web Worker para el Procesamiento de Inteligencia Artificial (AI-Worker)
 * Este worker realiza cálculos intensivos de forma concurrente para no bloquear
 * el hilo principal de la interfaz de usuario.
 */

self.onmessage = function(e) {
    const { action, data } = e.data;

    if (action === 'PREDICT_OUTCOME') {
        const t0 = performance.now();
        
        // Ejecutar el algoritmo recursivo para estimar probabilidades
        const prediction = runRecursiveSimulation(
            data.homeScore, 
            data.awayScore, 
            data.timeLeft / 1000, // segundos
            data.possession,
            0 // profundidad inicial
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

/**
 * Algoritmo de Simulación Recursiva de Partido
 * Implementa una exploración de árbol de decisión para predecir el resultado.
 * 
 * @param {number} hS - Puntos equipo local
 * @param {number} aS - Puntos equipo visitante
 * @param {number} time - Tiempo restante en segundos
 * @param {string} poss - Posesión actual ('home', 'away')
 * @param {number} depth - Profundidad actual de recursión
 */
function runRecursiveSimulation(hS, aS, time, poss, depth) {
    const MAX_DEPTH = 35; // Nivel de recursión controlado para tiempo real
    const AVG_POSSESSION_TIME = 15; // Segundos promedio por jugada
    const traces = [];
    let scenarios = 0;

    // Función interna recursiva (Clausura)
    function recurse(h, a, t, p, d) {
        scenarios++;
        
        // CASOS BASE (Condiciones de parada de recursión)
        // 1. Se acabó el tiempo
        if (t <= 0) {
            return h > a ? 1 : 0; 
        }
        
        // 2. Límite de profundidad alcanzado (heurística de proyección)
        if (d >= MAX_DEPTH) {
            // Proyección lineal simple en el nodo hoja
            const driftH = (h / (MAX_DEPTH * AVG_POSSESSION_TIME)) * t;
            const driftA = (a / (MAX_DEPTH * AVG_POSSESSION_TIME)) * t;
            return (h + driftH) > (a + driftA) ? 0.6 : 0.4;
        }

        // RAMIFICACIÓN (Paso Recursivo)
        // Simulamos dos caminos: Tiro Exitoso (Made) y Fallo (Missed)
        // Probabilidades genéricas NBA
        const pMake = 0.45;
        const pMiss = 0.55;
        const pts = 2.2; // Promedio de puntos por jugada efectiva

        let winRate = 0;

        if (p === 'home') {
            // Camino A: Local encesta (recursión profunda)
            const outcomeMake = recurse(h + pts, a, t - AVG_POSSESSION_TIME, 'away', d + 1);
            // Camino B: Local falla (recursión profunda)
            const outcomeMiss = recurse(h, a, t - AVG_POSSESSION_TIME, 'away', d + 1);
            
            winRate = (outcomeMake * pMake) + (outcomeMiss * pMiss);
            
            if (d < 3) traces.push(`[D${d}] Prob. Victoria Home: ${(winRate * 100).toFixed(1)}%`);
        } else {
            // Camino A: Visitante encesta
            const outcomeMake = recurse(h, a + pts, t - AVG_POSSESSION_TIME, 'home', d + 1);
            // Camino B: Visitante falla
            const outcomeMiss = recurse(h, a, t - AVG_POSSESSION_TIME, 'home', d + 1);
            
            winRate = (outcomeMake * pMake) + (outcomeMiss * pMiss);
        }

        return winRate;
    }

    // Ejecutar recursión
    const finalWinProb = recurse(hS, aS, time, poss, depth);
    
    // Proyección de puntos basada en el tiempo restante
    const remainingPossessions = time / AVG_POSSESSION_TIME;
    const projPointsPerPoss = 1.1; 
    
    return {
        winProbHome: finalWinProb,
        projPointsHome: (poss === 'home' ? 0.6 : 0.4) * remainingPossessions * projPointsPerPoss,
        projPointsAway: (poss === 'away' ? 0.6 : 0.4) * remainingPossessions * projPointsPerPoss,
        scenarios: scenarios,
        maxDepthReached: MAX_DEPTH,
        traces: traces.slice(0, 15) // Top logs
    };
}
