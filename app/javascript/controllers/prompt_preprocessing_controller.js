import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "settings", "prompt"]

  connect() {
    this.update()
  }

  update() {
    const enabled = this.toggleTarget.checked
    this.settingsTarget.hidden = !enabled
    this.promptTarget.required = enabled
    this.toggleTarget.setAttribute("aria-expanded", String(enabled))
  }
}
