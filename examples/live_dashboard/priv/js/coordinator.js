const CPU_WORKER_CODE = `
  self.onmessage = function(e) {
    if (e.data === "collect") {
      var ch = new BroadcastChannel("dashboard");
      var usage = Math.random() * 100;
      var loadAvg = [
        Math.round((1 + Math.random() * 3) * 100) / 100,
        Math.round((1 + Math.random() * 2) * 100) / 100,
        Math.round((0.5 + Math.random() * 1.5) * 100) / 100
      ];
      ch.postMessage({
        source: "cpu",
        data: {
          usage: Math.round(usage * 10) / 10,
          cores: 8,
          load_avg: loadAvg
        }
      });
      ch.close();
      self.postMessage({ ack: "cpu" });
    }
  };
`;

const MEMORY_WORKER_CODE = `
  self.onmessage = function(e) {
    if (e.data === "collect") {
      var ch = new BroadcastChannel("dashboard");
      var total = 16384;
      var used = Math.round(4096 + Math.random() * 8192);
      ch.postMessage({
        source: "memory",
        data: {
          total_mb: total,
          used_mb: used,
          free_mb: total - used,
          usage_percent: Math.round(used / total * 1000) / 10
        }
      });
      ch.close();
      self.postMessage({ ack: "memory" });
    }
  };
`;

const REQUESTS_WORKER_CODE = `
  self.onmessage = function(e) {
    if (e.data === "collect") {
      var ch = new BroadcastChannel("dashboard");
      var rps = Math.round(500 + Math.random() * 2000);
      var avgMs = Math.round((5 + Math.random() * 45) * 10) / 10;
      var errorRate = Math.round(Math.random() * 5 * 10) / 10;
      ch.postMessage({
        source: "requests",
        data: {
          rps: rps,
          avg_latency_ms: avgMs,
          error_rate: errorRate,
          active_connections: Math.round(50 + Math.random() * 200)
        }
      });
      ch.close();
      self.postMessage({ ack: "requests" });
    }
  };
`;

var dashboard = {
  cpu: null,
  memory: null,
  requests: null,
  last_updated: null,
  collection_count: 0
};

var channel = new BroadcastChannel("dashboard");
channel.onmessage = function(e) {
  var msg = e.data;
  if (msg && msg.source) {
    dashboard[msg.source] = msg.data;
    dashboard.last_updated = new Date().toISOString();
  }
};

var workers = [];

function spawnWorkers() {
  workers.push(new Worker(CPU_WORKER_CODE));
  workers.push(new Worker(MEMORY_WORKER_CODE));
  workers.push(new Worker(REQUESTS_WORKER_CODE));
}

spawnWorkers();

function collectMetrics() {
  dashboard.collection_count++;
  for (var i = 0; i < workers.length; i++) {
    workers[i].postMessage("collect");
  }
}

function getDashboard() {
  return dashboard;
}

function getWorkerCount() {
  return workers.length;
}
