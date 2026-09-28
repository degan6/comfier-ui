import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["thread", "form", "input", "file", "preview", "previewImage", "submit"]

  connect() {
    this.scrollToBottom()
  }

  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.formTarget.requestSubmit()
    }
  }

  previewImage() {
    const file = this.fileTarget.files[0]
    if (!file) {
      this.clearImage()
      return
    }

    this.previewImageTarget.src = URL.createObjectURL(file)
    this.previewTarget.classList.remove("d-none")
  }

  clearImage() {
    this.fileTarget.value = ""
    this.previewImageTarget.removeAttribute("src")
    this.previewTarget.classList.add("d-none")
  }

  submit() {
    if (this.hasSubmitTarget) this.submitTarget.disabled = true
  }

  scrollToBottom() {
    if (!this.hasThreadTarget) return
    this.threadTarget.scrollTop = this.threadTarget.scrollHeight
  }
}
