"use strict";

const state = { all: [], filtered: [], hours: 24, config: {} };
const colors = { grid: "#20364a", text: "#8fa9bf", download: "#33d6c5", upload: "#4b8cff", ping: "#ffb84d", jitter: "#a889ff", loss: "#ff6577" };
const $ = (id) => document.getElementById(id);

function number(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(String(value).replace(",", "."));
  return Number.isFinite(parsed) ? parsed : null;
}

function parseDate(value) {
  const match = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/);
  if (!match) return null;
  return new Date(+match[1], +match[2] - 1, +match[3], +match[4], +match[5], +match[6]);
}

function normalize(row) {
  return {
    date: parseDate(row.DataHora), dateText: row.DataHora || "—",
    download: number(row.DownloadMbps), upload: number(row.UploadMbps),
    ping: number(row.PingMs), jitter: number(row.JitterMs), loss: number(row.PerdaPacotesPct),
    isp: row.ISP || "", server: row.Servidor || "—", location: row.LocalServidor || "",
    url: row.URLResultado || "", status: row.Status || "Erro", message: row.Mensagem || ""
  };
}

const fmt = (value, digits = 1) => value === null || !Number.isFinite(value) ? "—" :
  value.toLocaleString("pt-BR", { minimumFractionDigits: digits, maximumFractionDigits: digits });
const avg = (rows, key) => {
  const values = rows.map(r => r[key]).filter(Number.isFinite);
  return values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
};

function applyRange() {
  const valid = state.all.filter(row => row.date);
  if (!state.hours) state.filtered = valid;
  else {
    const cutoff = new Date(Date.now() - state.hours * 3600000);
    state.filtered = valid.filter(row => row.date >= cutoff);
  }
  render();
}

function setMetric(id, value, threshold, direction) {
  $(id).textContent = fmt(value, 2);
  const card = $(id).closest(".metric");
  const alert = Number.isFinite(value) && Number.isFinite(threshold) &&
    (direction === "min" ? value < threshold : value > threshold);
  card.classList.toggle("alert", alert);
}

function render() {
  const rows = state.filtered;
  const latest = [...state.all].reverse().find(r => r.status === "Sucesso");
  const lastRecord = state.all[state.all.length - 1];
  $("dashboard").classList.toggle("hidden", state.all.length === 0);
  $("emptyState").classList.toggle("hidden", state.all.length !== 0);
  $("historyLink").classList.toggle("hidden", state.all.length === 0);
  if (!state.all.length) return;

  setMetric("downloadNow", latest?.download ?? null, number(state.config.downloadMinMbps), "min");
  setMetric("uploadNow", latest?.upload ?? null, number(state.config.uploadMinMbps), "min");
  setMetric("pingNow", latest?.ping ?? null, number(state.config.pingMaxMs), "max");
  setMetric("jitterNow", latest?.jitter ?? null, number(state.config.jitterMaxMs), "max");
  setMetric("lossNow", latest?.loss ?? null, number(state.config.packetLossMaxPct), "max");

  const successes = rows.filter(r => r.status === "Sucesso");
  $("downloadAvg").textContent = `${fmt(avg(successes, "download"))} Mbps`;
  $("uploadAvg").textContent = `${fmt(avg(successes, "upload"))} Mbps`;
  $("availability").textContent = rows.length ? `${fmt(successes.length * 100 / rows.length)}%` : "—";
  $("testCount").textContent = rows.length.toLocaleString("pt-BR");

  const ageMinutes = lastRecord?.date ? (Date.now() - lastRecord.date.getTime()) / 60000 : Infinity;
  const configuredInterval = number(state.config.collectionIntervalMinutes);
  const staleLimit = number(state.config.staleAfterMinutes) ??
    (Number.isFinite(configuredInterval) ? configuredInterval * 2.5 : 150);
  const pill = $("statusPill");
  pill.className = "pill";
  pill.removeAttribute("title");
  if (lastRecord?.status !== "Sucesso") {
    pill.textContent = "Última coleta falhou";
    pill.classList.add("bad");
    if (lastRecord?.message) pill.title = lastRecord.message;
  } else if (ageMinutes > staleLimit) {
    pill.textContent = "Dados desatualizados";
    pill.classList.add("warn");
  } else {
    pill.textContent = "Conexão medida";
    pill.classList.add("good");
  }

  if (lastRecord?.status !== "Sucesso" && lastRecord?.date) {
    const previousSuccess = latest?.date ?
      ` · Último sucesso: ${latest.date.toLocaleString("pt-BR")}` : "";
    $("freshness").textContent =
      `Última tentativa: ${lastRecord.date.toLocaleString("pt-BR")} · falhou${previousSuccess}`;
  } else {
    $("freshness").textContent = lastRecord?.date ?
      `Última coleta: ${lastRecord.date.toLocaleString("pt-BR")} · ${lastRecord.isp || "provedor não informado"}` :
      "Horário da última coleta indisponível";
  }

  drawChart($("speedChart"), successes, [
    { key: "download", color: colors.download }, { key: "upload", color: colors.upload }
  ], "Mbps");
  drawChart($("latencyChart"), successes, [
    { key: "ping", color: colors.ping }, { key: "jitter", color: colors.jitter }
  ], "ms");
  drawChart($("lossChart"), successes, [{ key: "loss", color: colors.loss }], "%");
  renderTable([...rows].reverse().slice(0, 30));
}

function renderTable(rows) {
  $("historyBody").innerHTML = rows.map(row => {
    const statusClass = row.status === "Sucesso" ? "status-ok" : "status-error";
    const status = row.status === "Sucesso" ? "Sucesso" : `Erro${row.message ? `: ${escapeHtml(row.message)}` : ""}`;
    return `<tr>
      <td>${row.date ? row.date.toLocaleString("pt-BR") : escapeHtml(row.dateText)}</td>
      <td>${fmt(row.download, 2)}</td><td>${fmt(row.upload, 2)}</td>
      <td>${fmt(row.ping, 2)}</td><td>${fmt(row.jitter, 2)}</td><td>${fmt(row.loss, 2)}</td>
      <td title="${escapeHtml(row.location)}">${escapeHtml(row.server)}</td>
      <td class="${statusClass}">${status}</td>
    </tr>`;
  }).join("");
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
}

function drawChart(canvas, rows, series, unit) {
  const rect = canvas.getBoundingClientRect();
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.max(300, Math.floor(rect.width * dpr));
  canvas.height = Math.max(180, Math.floor(rect.height * dpr));
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  const width = canvas.width / dpr, height = canvas.height / dpr;
  const pad = { l: 48, r: 12, t: 12, b: 30 };
  const plotW = width - pad.l - pad.r, plotH = height - pad.t - pad.b;
  const values = rows.flatMap(row => series.map(s => row[s.key])).filter(Number.isFinite);
  let max = values.length ? Math.max(...values) : 1;
  max = max <= 0 ? 1 : max * 1.12;

  ctx.clearRect(0, 0, width, height);
  ctx.font = "11px Segoe UI";
  ctx.textAlign = "right";
  ctx.textBaseline = "middle";
  for (let i = 0; i <= 4; i++) {
    const y = pad.t + plotH * i / 4;
    const value = max * (1 - i / 4);
    ctx.strokeStyle = colors.grid; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(pad.l, y); ctx.lineTo(width - pad.r, y); ctx.stroke();
    ctx.fillStyle = colors.text; ctx.fillText(`${compact(value)} ${i === 0 ? unit : ""}`, pad.l - 8, y);
  }
  if (!rows.length) {
    ctx.fillStyle = colors.text; ctx.textAlign = "center";
    ctx.fillText("Sem dados neste período", pad.l + plotW / 2, pad.t + plotH / 2);
    return;
  }

  const times = rows.map(r => r.date.getTime());
  const minTime = Math.min(...times), maxTime = Math.max(...times);
  const span = Math.max(1, maxTime - minTime);
  series.forEach(s => {
    ctx.strokeStyle = s.color; ctx.lineWidth = 2; ctx.lineJoin = "round"; ctx.lineCap = "round";
    ctx.beginPath(); let started = false;
    rows.forEach(row => {
      const value = row[s.key];
      if (!Number.isFinite(value)) { started = false; return; }
      const x = pad.l + (row.date.getTime() - minTime) / span * plotW;
      const y = pad.t + plotH - value / max * plotH;
      if (!started) { ctx.moveTo(x, y); started = true; } else ctx.lineTo(x, y);
    });
    ctx.stroke();
  });

  ctx.fillStyle = colors.text; ctx.textBaseline = "top";
  ctx.textAlign = "left"; ctx.fillText(rows[0].date.toLocaleDateString("pt-BR"), pad.l, height - 20);
  ctx.textAlign = "right"; ctx.fillText(rows[rows.length - 1].date.toLocaleDateString("pt-BR"), width - pad.r, height - 20);
}

function compact(value) {
  return value >= 1000 ? `${(value / 1000).toFixed(1)}k` : value.toFixed(value < 10 ? 1 : 0);
}

function load() {
  $("refreshButton").disabled = true;
  try {
    const raw = window.INTERNET_MONITOR_DATA || [];
    state.config = window.INTERNET_MONITOR_CONFIG || {};
    state.all = (Array.isArray(raw) ? raw : raw ? [raw] : []).map(normalize).filter(r => r.date).sort((a, b) => a.date - b.date);
    applyRange();
  } catch (error) {
    $("statusPill").textContent = "Falha ao carregar";
    $("statusPill").className = "pill bad";
    $("freshness").textContent = error.message;
  } finally {
    $("refreshButton").disabled = false;
  }
}

document.querySelectorAll(".range-picker button").forEach(button => button.addEventListener("click", () => {
  document.querySelectorAll(".range-picker button").forEach(b => b.classList.remove("active"));
  button.classList.add("active");
  state.hours = Number(button.dataset.hours);
  applyRange();
}));
$("refreshButton").addEventListener("click", () => location.reload());
window.addEventListener("resize", () => render());
load();
setInterval(() => location.reload(), 60000);
