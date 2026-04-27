[Unit]
Description=milvus-onprem peer-down watchdog (alert mode)
Documentation=https://github.com/codeadeel/milvus-onprem
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
ExecStart=${REPO_ROOT}/milvus-onprem watchdog
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
# Keep alert lines unbuffered so journalctl shows them in real time.
Environment=PYTHONUNBUFFERED=1
# Watchdog only does TCP probes, no privileged actions; running as root
# is the simplest path because cluster.env is mode 600 and may be owned
# by the install-time user. Override with `sudo systemctl edit
# milvus-watchdog` if you want to drop privileges.

[Install]
WantedBy=multi-user.target
