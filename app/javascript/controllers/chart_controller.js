import { Controller } from "@hotwired/stimulus"
import { Chart, registerables } from "chart.js"

Chart.register(...registerables)

// Draws a line or bar chart from JSON { labels, datasets: [{ label, data, muted?, danger? }] },
// either inline (data-chart-data-value) or fetched (data-chart-url-value, optionally under
// data-chart-key-value). Series are neutral grey unless they mean something (danger = red).
export default class extends Controller {
  static values = { url: String, key: String, type: { type: String, default: "line" }, data: Object }

  async connect() {
    const payload = this.hasUrlValue ? await this.fetchData() : this.dataValue
    if (!payload) return
    const series = this.keyValue ? payload[this.keyValue] : payload
    if (!series || !series.labels) return
    this.draw(series)
  }

  disconnect() {
    this.chart?.destroy()
  }

  async fetchData() {
    const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
    return response.ok ? response.json() : null
  }

  draw(series) {
    const styles = getComputedStyle(document.documentElement)
    const text = styles.getPropertyValue("--bs-secondary-color").trim() || "#9aa0a6"
    const grid = styles.getPropertyValue("--bs-border-color-translucent").trim() || "rgba(255,255,255,0.1)"
    const neutral = styles.getPropertyValue("--bs-gray-500").trim() || "#adb5bd"
    const muted = styles.getPropertyValue("--bs-gray-700").trim() || "#495057"
    const danger = styles.getPropertyValue("--bs-danger").trim() || "#dc3545"

    const datasets = series.datasets.map((set) => {
      const color = set.danger ? danger : set.muted ? muted : neutral
      return { label: set.label, data: set.data, borderColor: color, backgroundColor: color,
               borderWidth: 1.5, pointRadius: 0, tension: 0.2 }
    })

    this.chart = new Chart(this.element, {
      type: this.typeValue,
      data: { labels: series.labels.map((label) => this.formatLabel(label)), datasets },
      options: {
        animation: false,
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: datasets.length > 1, labels: { color: text, font: { size: 12 }, boxWidth: 10 } } },
        scales: {
          x: { ticks: { color: text, font: { size: 12 }, maxTicksLimit: 8 }, grid: { color: grid } },
          y: { beginAtZero: true, ticks: { color: text, font: { size: 12 } }, grid: { color: grid } }
        }
      }
    })
    this.element.dataset.chartRendered = "true"
  }

  formatLabel(label) {
    const date = new Date(label)
    if (Number.isNaN(date.getTime()) || !/^\d{4}-\d{2}-\d{2}/.test(label)) return label
    return label.length > 10 ? date.toLocaleString([], { month: "short", day: "numeric", hour: "numeric" })
                             : date.toLocaleDateString([], { month: "short", day: "numeric" })
  }
}
