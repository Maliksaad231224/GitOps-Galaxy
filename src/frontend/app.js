async function fetchServedBy() {
  try {
    const res = await fetch("/", { method: "GET", cache: "no-store" });
    const servedBy = res.headers.get("X-Served-By") || "unknown";
    document.getElementById("servedBy").textContent = `Served by: ${servedBy}`;
  } catch {
    document.getElementById("servedBy").textContent = "Served by: unknown";
  }
}

function fmtBytes(bytes) {
  if (bytes == null) return "-";
  const units = ["B","KB","MB","GB","TB"];
  let val = Number(bytes);
  let i = 0;
  while (val >= 1024 && i < units.length - 1) {
    val /= 1024;
    i++;
  }
  return `${val.toFixed(1)} ${units[i]}`;
}

async function loadHealth() {
  const el = document.getElementById("health");
  try {
    const res = await fetch("/api/health", { cache: "no-store" });
    el.textContent = res.ok ? "OK" : `ERROR (${res.status})`;
  } catch {
    el.textContent = "ERROR";
  }
}

async function loadMetrics() {
  const raw = document.getElementById("raw");
  const lastUpdate = document.getElementById("lastUpdate");

  try {
    const res = await fetch("/api/metrics-json", { cache: "no-store" });
    const data = await res.json();

    lastUpdate.textContent = new Date().toLocaleString();

    document.getElementById("bh").textContent = data.backend_instance?.hostname ?? "-";
    document.getElementById("bip").textContent = data.backend_instance?.primary_ip ?? "-";

    const os = data.os?.os_release?.PRETTY_NAME || data.os?.platform || "-";
    document.getElementById("os").textContent = os;

    document.getElementById("uptime").textContent = data.system?.uptime ?? "-";
    document.getElementById("cpu").textContent = String(data.cpu?.logical_cores ?? "-");

    const used = data.memory?.ram_used_bytes;
    const total = data.memory?.ram_total_bytes;
    document.getElementById("ram").textContent = (used != null && total != null)
      ? `${fmtBytes(used)} / ${fmtBytes(total)}`
      : "-";

    raw.textContent = JSON.stringify(data, null, 2);
  } catch (e) {
    raw.textContent = `Failed to load /api/metrics-json: ${String(e)}`;
  }
}

document.getElementById("refreshBtn").addEventListener("click", async () => {
  await fetchServedBy();
  await loadHealth();
  await loadMetrics();
});

(async function init() {
  await fetchServedBy();
  await loadHealth();
  await loadMetrics();
})();