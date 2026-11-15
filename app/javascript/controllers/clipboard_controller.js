import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "icon", "status"]
  static values = { text: String }

  async copy() {
    const text = this.hasTextValue ? this.textValue : (this.sourceTarget.value || this.sourceTarget.textContent)
    try {
      await navigator.clipboard.writeText(text.trim())
      this.showCopied()
      if (this.hasStatusTarget) this.statusTarget.textContent = "Copied to clipboard."
    } catch {
      if (this.hasStatusTarget) this.statusTarget.textContent = "Copy failed. Open the Markdown version to copy the text."
    }
  }

  showCopied() {
    if (!this.hasIconTarget) return

    const icon = this.iconTarget
    clearTimeout(this.resetTimer)
    icon.classList.replace("bi-clipboard", "bi-check-lg")
    this.resetTimer = setTimeout(() => icon.classList.replace("bi-check-lg", "bi-clipboard"), 1500)
  }

  disconnect() {
    clearTimeout(this.resetTimer)
  }
}
