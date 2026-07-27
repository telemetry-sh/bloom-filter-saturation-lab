"use strict";

const form = document.querySelector("#controls");
const stateLabel = document.querySelector("#request-state");
const summaryStrip = document.querySelector("#summary-strip");
const strategyCards = document.querySelector("#strategy-cards");
const chartLegend = document.querySelector("#chart-legend");
const traceBody = document.querySelector("#trace-body");
const tracePolicy = document.querySelector("#trace-policy");
const canvas = document.querySelector("#curve-chart");
const bitLattice = document.querySelector("#bit-lattice");

const valueFormatters = {
  candidates_per_second: (value) => `${compact(value)}/s`,
  new_key_percent: (value) => `${value}%`,
  expected_items: (value) => compact(value),
  bits_per_item: (value) => `${value} bits`,
  hash_functions: (value) => value,
  run_seconds: (value) => `${value}s`,
  rotate_window_seconds: (value) => `${value}s`,
  layer_threshold_percent: (value) => `${value}%`,
  backend_p99_ms: (value) => `${value} ms`,
  seed: (value) => value,
};

let response = null;
let selectedPolicy = "fixed_definitive";
let requestSequence = 0;
let debounceTimer = null;

function compact(value) {
  return Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

function integer(value) {
  return Intl.NumberFormat("en").format(value);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function queryString() {
  return new URLSearchParams(new FormData(form)).toString();
}

function updateOutputs() {
  for (const input of form.elements) {
    if (!(input instanceof HTMLInputElement)) continue;
    const output = form.querySelector(`[data-for="${input.name}"]`);
    if (!output) continue;
    output.value = valueFormatters[input.name]?.(Number(input.value)) ?? input.value;
  }
}

function selectedStrategy() {
  return response?.strategies.find((strategy) => strategy.policy === selectedPolicy)
    ?? response?.strategies[0];
}

function renderSummary() {
  const fixed = response.strategies.find((item) => item.policy === "fixed_definitive");
  const verify = response.strategies.find((item) => item.policy === "fixed_verify_positive");
  const scalable = response.strategies.find((item) => item.policy === "scalable_layers");
  const rotating = response.strategies.find((item) => item.policy === "rotating_generations");
  summaryStrip.innerHTML = `
    <div><span>fixed peak fpp</span><strong>${fixed.metrics.peakEstimatedFppPercent}%</strong></div>
    <div><span>valid events lost</span><strong>${integer(fixed.metrics.lostValidEvents)}</strong></div>
    <div><span>verification reads</span><strong>${integer(verify.metrics.backendVerifications)}</strong></div>
    <div><span>scalable / rotating</span><strong>${scalable.metrics.layers} layers · ${rotating.metrics.rotations} turns</strong></div>
  `;
}

function renderStrategies() {
  strategyCards.innerHTML = response.strategies.map((strategy) => {
    const metrics = strategy.metrics;
    const selected = strategy.policy === selectedPolicy;
    return `
      <button
        class="strategy-card ${selected ? "selected" : ""}"
        data-policy="${escapeHtml(strategy.policy)}"
        style="--strategy:${escapeHtml(strategy.color)}"
        aria-pressed="${selected}"
      >
        <span class="strategy-index">${String(response.strategies.indexOf(strategy) + 1).padStart(2, "0")}</span>
        <span class="strategy-kicker">${escapeHtml(strategy.kicker)}</span>
        <strong>${escapeHtml(strategy.name)}${strategy.recommended ? '<small>recommended</small>' : ""}</strong>
        <span class="strategy-description">${escapeHtml(strategy.description)}</span>
        <span class="metric-pair">
          <span><em>peak fpp</em><b>${metrics.peakEstimatedFppPercent}%</b></span>
          <span><em>lost valid</em><b>${compact(metrics.lostValidEvents)}</b></span>
          <span><em>memory</em><b>${metrics.memoryMiB} MiB</b></span>
          <span><em>decision p99</em><b>${metrics.decisionP99Ms} ms</b></span>
        </span>
        <span class="strategy-tradeoff">${escapeHtml(strategy.tradeoff)}</span>
      </button>
    `;
  }).join("");

  strategyCards.querySelectorAll("[data-policy]").forEach((card) => {
    card.addEventListener("click", () => {
      selectedPolicy = card.dataset.policy;
      renderStrategies();
      renderSelected();
    });
  });
}

function createBitLattice() {
  bitLattice.innerHTML = Array.from({ length: 72 }, (_, index) => (
    `<span style="--delay:${index % 11}"></span>`
  )).join("");
}

function renderBitLattice(strategy) {
  const fill = strategy.metrics.finalFillPercent / 100;
  const threshold = Math.round(fill * bitLattice.children.length);
  [...bitLattice.children].forEach((cell, index) => {
    const hashed = (index * 37 + 17) % bitLattice.children.length;
    cell.classList.toggle("set", hashed < threshold);
    cell.classList.toggle("collision", hashed < threshold && index % 13 === 0);
  });
}

function renderSelected() {
  const strategy = selectedStrategy();
  if (!strategy) return;
  const metrics = strategy.metrics;
  document.querySelector("#hero-fpp").textContent = `${metrics.finalEstimatedFppPercent}%`;
  document.querySelector("#hero-fill").textContent = `${metrics.finalFillPercent}%`;
  document.querySelector("#hero-lost").textContent = integer(metrics.lostValidEvents);
  document.querySelector("#hero-authority").textContent = strategy.policy === "fixed_verify_positive"
    ? "source of truth"
    : "probability";
  document.querySelector("#hero-command").textContent = strategy.policy === "fixed_verify_positive"
    ? `check("evt_9f2") → maybe → verify`
    : `check("evt_9f2") → maybe-present`;
  tracePolicy.textContent = strategy.name;
  renderBitLattice(strategy);
  renderTrace(strategy);
}

function renderTrace(strategy) {
  traceBody.innerHTML = strategy.events.map((event) => `
    <tr>
      <td><code>+${(event.timestampMs / 1000).toFixed(0)}s</code></td>
      <td><code>L${event.layer} / G${event.generation}</code></td>
      <td>${event.bitFillPercent}%</td>
      <td class="${event.estimatedFppPercent > 1 ? "danger-cell" : ""}">${event.estimatedFppPercent}%</td>
      <td>${escapeHtml(event.filterDecision)}</td>
      <td>${escapeHtml(event.authority)}</td>
      <td><span class="outcome ${event.outcome.includes("dropped") ? "bad" : "good"}">${escapeHtml(event.outcome)}</span></td>
    </tr>
  `).join("");
}

function renderLegend() {
  chartLegend.innerHTML = response.strategies.map((strategy) => `
    <button data-legend-policy="${escapeHtml(strategy.policy)}">
      <i style="--strategy:${escapeHtml(strategy.color)}"></i>
      ${escapeHtml(strategy.name)}
    </button>
  `).join("");
  chartLegend.querySelectorAll("button").forEach((button) => {
    button.addEventListener("click", () => {
      selectedPolicy = button.dataset.legendPolicy;
      renderStrategies();
      renderSelected();
    });
  });
}

function chartY(value, top, height) {
  const minimum = -2;
  const maximum = 2;
  const log = Math.log10(Math.max(0.01, value));
  return top + height - ((log - minimum) / (maximum - minimum)) * height;
}

function drawChart() {
  if (!response) return;
  const rect = canvas.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return;
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(rect.width * ratio);
  canvas.height = Math.round(rect.height * ratio);
  const context = canvas.getContext("2d");
  context.scale(ratio, ratio);

  const width = rect.width;
  const height = rect.height;
  const inset = { top: 18, right: 18, bottom: 34, left: 52 };
  const plotWidth = width - inset.left - inset.right;
  const plotHeight = height - inset.top - inset.bottom;

  context.clearRect(0, 0, width, height);
  context.font = "11px ui-monospace, SFMono-Regular, Menlo, monospace";
  context.textAlign = "right";
  context.textBaseline = "middle";

  [0.01, 0.1, 1, 10, 100].forEach((tick) => {
    const y = chartY(tick, inset.top, plotHeight);
    context.beginPath();
    context.strokeStyle = tick === 1 ? "#ef476f" : "rgba(12, 47, 55, 0.12)";
    context.setLineDash(tick === 1 ? [6, 5] : []);
    context.moveTo(inset.left, y);
    context.lineTo(width - inset.right, y);
    context.stroke();
    context.fillStyle = tick === 1 ? "#c1264f" : "#60767b";
    context.fillText(`${tick}%`, inset.left - 9, y);
  });
  context.setLineDash([]);

  const runSeconds = response.config.runSeconds;
  [0, 0.25, 0.5, 0.75, 1].forEach((position) => {
    const x = inset.left + plotWidth * position;
    context.fillStyle = "#60767b";
    context.textAlign = position === 0 ? "left" : position === 1 ? "right" : "center";
    context.fillText(`${Math.round(runSeconds * position)}s`, x, height - 12);
  });

  response.strategies.forEach((strategy) => {
    context.beginPath();
    context.strokeStyle = strategy.color;
    context.lineWidth = strategy.policy === selectedPolicy ? 3.5 : 1.8;
    context.globalAlpha = strategy.policy === selectedPolicy ? 1 : 0.55;
    strategy.timeline.forEach((point, index) => {
      const x = inset.left + (point.second / runSeconds) * plotWidth;
      const y = chartY(point.estimatedFppPercent, inset.top, plotHeight);
      if (index === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    });
    context.stroke();
  });
  context.globalAlpha = 1;
}

function renderAll() {
  renderSummary();
  renderStrategies();
  renderLegend();
  renderSelected();
  drawChart();
}

async function loadSimulation() {
  const sequence = ++requestSequence;
  stateLabel.textContent = "running model…";
  stateLabel.classList.remove("error");
  try {
    const result = await fetch(`/api/simulate?${queryString()}`, {
      headers: { Accept: "application/json" },
    });
    if (!result.ok) throw new Error(`HTTP ${result.status}`);
    const payload = await result.json();
    if (sequence !== requestSequence) return;
    response = payload;
    stateLabel.textContent = `${compact(payload.config.candidatesPerSecond * payload.config.runSeconds)} decisions replayed`;
    renderAll();
  } catch (error) {
    if (sequence !== requestSequence) return;
    stateLabel.textContent = `model unavailable · ${error.message}`;
    stateLabel.classList.add("error");
  }
}

form.addEventListener("input", () => {
  updateOutputs();
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(loadSimulation, 130);
});

form.addEventListener("reset", () => {
  setTimeout(() => {
    updateOutputs();
    loadSimulation();
  }, 0);
});

new ResizeObserver(drawChart).observe(canvas);
createBitLattice();
updateOutputs();
loadSimulation();
