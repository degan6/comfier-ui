import { Controller } from "@hotwired/stimulus"

// Asks the server how long the job in the surrounding form would take, and where, whenever the
// form changes. Shows the privacy notice when it may run on someone else's server.
export default class extends Controller {
  static targets = ["summary", "notice"]
  static values = { url: String }

  connect() {
    this.form = this.element.closest("form")
    this.onChange = () => this.refresh()
    this.form?.addEventListener("change", this.onChange)
    this.refresh()
  }

  disconnect() {
    this.form?.removeEventListener("change", this.onChange)
    clearTimeout(this.timer)
  }

  refresh() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.load(), 250)
  }

  async load() {
    if (!this.form) return
    const params = new URLSearchParams()
    for (const [key, value] of new FormData(this.form)) {
      if (typeof value === "string" && key.startsWith("generation[") && !key.includes("prompt")) params.append(key, value)
    }
    const response = await fetch(`${this.urlValue}?${params}`, { headers: { Accept: "application/json" } })
    if (!response.ok) return
    const data = await response.json()
    this.summaryTarget.textContent = data.summary || ""
    this.noticeTarget.textContent = data.notice || ""
    this.noticeTarget.classList.toggle("d-none", !data.notice)
  }
}
