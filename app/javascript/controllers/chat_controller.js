import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["thread", "form", "input", "file", "preview", "previewImage", "submit"]

  connect() {
    this.scrollToBottom()
    document.addEventListener("turbo:before-stream-render", this.onStreamRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.onStreamRender)
  }

  onStreamRender = (event) => {
    if (!this.shouldScrollForStream(event.target)) return

    requestAnimationFrame(() => {
      requestAnimationFrame(() => this.scrollToBottom())
    })
  }

  shouldScrollForStream(streamElement) {
    if (!this.hasThreadTarget || !streamElement?.getAttribute) return false

    const target = streamElement.getAttribute("target") || ""
    if (target === "chat_thread") return true
    if (target.startsWith("chat_message_")) return true

    return this.threadTarget.contains(document.getElementById(target))
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
