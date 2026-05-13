import os
import time
import socket
import platform
import logging
from datetime import datetime, timezone

import psutil
from flask import Flask, jsonify, request, Response
from prometheus_client import (
    Counter,
    Histogram,
    Gauge,
    generate_latest,
    CONTENT_TYPE_LATEST,
)
from pythonjsonlogger import jsonlogger

app = Flask(__name__)

START_TS = time.time()
HOSTNAME = socket.gethostname()

logger = logging.getLogger("sherlock_logs_backend")
logger.setLevel(logging.INFO)
_handler = logging.StreamHandler()
_formatter = jsonlogger.JsonFormatter(
    fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
    rename_fields={"asctime": "ts", "levelname": "level", "name": "logger"},
)
_handler.setFormatter(_formatter)
logger.handlers.clear()
logger.addHandler(_handler)
logger.propagate = False

HTTP_REQUESTS_TOTAL = Counter(
    "sherlock_http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)
HTTP_REQUEST_DURATION = Histogram(
    "sherlock_http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
)

APP_UPTIME_SECONDS = Gauge(
    "sherlock_app_uptime_seconds",
    "Backend application uptime in seconds",
)

CUSTOM_ACTIVE_USERS = Gauge(
    "sherlock_custom_active_users",
    "Custom application metric (demo) - active users estimate",
)

def read_os_release() -> dict:
    data = {}
    try:
        with open("/etc/os-release", "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k] = v.strip().strip('"')
    except Exception:
        pass
    return data


def get_primary_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "unknown"


def seconds_to_human(seconds: float) -> str:
    seconds = int(seconds)
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, sec = divmod(rem, 60)
    if days > 0:
        return f"{days}d {hours}h {minutes}m {sec}s"
    if hours > 0:
        return f"{hours}h {minutes}m {sec}s"
    if minutes > 0:
        return f"{minutes}m {sec}s"
    return f"{sec}s"


@app.before_request
def _start_timer():
    request._start_ts = time.time()


@app.after_request
def _record_metrics(resp):
    try:
        duration = max(0.0, time.time() - getattr(request, "_start_ts", time.time()))
        method = request.method

        raw_path = request.path or "/"
        path = raw_path
        if raw_path not in ("/health", "/metrics", "/metrics-json"):
            path = "/" + raw_path.strip("/").split("/")[0]

        HTTP_REQUEST_DURATION.labels(method=method, path=path).observe(duration)
        HTTP_REQUESTS_TOTAL.labels(method=method, path=path, status=str(resp.status_code)).inc()

        APP_UPTIME_SECONDS.set(time.time() - START_TS)
        try:
            load_1 = os.getloadavg()[0]
            CUSTOM_ACTIVE_USERS.set(max(0.0, min(1000.0, load_1 * 25.0)))
        except Exception:
            pass

        logger.info(
            "request",
            extra={
                "event": "http_request",
                "method": method,
                "path": raw_path,
                "status": resp.status_code,
                "duration_ms": round(duration * 1000.0, 2),
                "client_ip": request.headers.get("X-Real-IP") or request.remote_addr,
                "host": HOSTNAME,
            },
        )
    except Exception:
        pass
    return resp


@app.get("/health")
def health():
    return "OK", 200


@app.get("/metrics")
def metrics_prometheus():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.get("/metrics-json")
def metrics_json():
    hostname = HOSTNAME
    osr = read_os_release()

    vm = psutil.virtual_memory()
    sm = psutil.swap_memory()

    cpu_count_logical = psutil.cpu_count(logical=True)
    cpu_count_physical = psutil.cpu_count(logical=False)

    load_1, load_5, load_15 = os.getloadavg() if hasattr(os, "getloadavg") else (None, None, None)

    boot_ts = psutil.boot_time()
    uptime_seconds = time.time() - boot_ts

    payload = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "backend_instance": {
            "hostname": hostname,
            "primary_ip": get_primary_ip(),
            "pid": os.getpid(),
            "app_uptime": seconds_to_human(time.time() - START_TS),
        },
        "os": {
            "platform": platform.platform(),
            "system": platform.system(),
            "release": platform.release(),
            "version": platform.version(),
            "os_release": osr,
        },
        "cpu": {
            "logical_cores": cpu_count_logical,
            "physical_cores": cpu_count_physical,
            "load_avg_1": load_1,
            "load_avg_5": load_5,
            "load_avg_15": load_15,
        },
        "memory": {
            "ram_total_bytes": vm.total,
            "ram_used_bytes": vm.used,
            "ram_available_bytes": vm.available,
            "ram_percent": vm.percent,
            "swap_total_bytes": sm.total,
            "swap_used_bytes": sm.used,
            "swap_percent": sm.percent,
        },
        "system": {
            "uptime": seconds_to_human(uptime_seconds),
            "boot_time_epoch": boot_ts,
        },
    }
    return jsonify(payload)


if __name__ == "__main__":
    logger.info(
        "startup",
        extra={"event": "startup", "host": HOSTNAME, "pid": os.getpid()},
    )
    app.run(host="0.0.0.0", port=5000)