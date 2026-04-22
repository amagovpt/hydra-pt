module.exports = {
  apps: [
    {
      name: "hydra-crawler",
      script: "uv",
      args: ["run", "udata-hydra-crawl"],
      interpreter: "none",
      restart_delay: 10000, // Opcional: espera 10s antes de reiniciar se o crawl terminar
      autorestart: true
    },
    {
      name: "hydra-worker",
      script: "uv",
      args: ["run", "rq", "worker", "-c", "udata_hydra.worker"],
      interpreter: "none",
      instances: 1,
      autorestart: true
    },
    {
      name: "hydra-app",
      script: "uv",
      args: ["run", "adev", "runserver", "udata_hydra/app.py"],
      interpreter: "none",
      env: {
        // Exemplo: forçar porta se o adev permitir via env
        // PORT: 5000 
      }
    }
  ]
}