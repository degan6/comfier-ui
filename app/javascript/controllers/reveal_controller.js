import { Controller } from "@hotwired/stimulus"

// Shows the element after `after` seconds (e.g. troubleshooting tips once a wait gets long).
export default class extends Controller {
  static values = { after: Number }

  connect() {
    if (this.afterValue <= 0) return this.show()
    this.timer = setTimeout(() => this.show(), this.afterValue * 1000)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  show() {
    this.element.classList.remove("d-none")
  }
}
