import { Controller } from "@hotwired/stimulus"

// Adds a hand-picked placeholder to the review table. Picking an input that already has a row replaces it.
export default class extends Controller {
  static targets = ["rows", "template", "target", "placeholder", "empty"]

  add() {
    const option = this.targetTarget.selectedOptions[0]
    if (!option) return

    const [node, input] = JSON.parse(option.value)
    const placeholder = this.placeholderTarget.value
    const values = {
      node, input, placeholder,
      token: `{{${placeholder}}}`,
      label: option.dataset.label,
      value: option.dataset.value
    }

    this.rowsTarget.querySelector(`tr[data-key="${CSS.escape(option.value)}"]`)?.remove()
    const row = this.templateTarget.content.firstElementChild.cloneNode(true)
    const index = Date.now()
    row.dataset.key = option.value
    row.querySelectorAll("[name]").forEach((field) => { field.name = field.name.replace("__INDEX__", index) })
    row.querySelectorAll("[data-field]").forEach((field) => { field.value = values[field.dataset.field] })
    row.querySelectorAll("[data-text]").forEach((element) => { element.textContent = values[element.dataset.text] })
    this.rowsTarget.append(row)
    this.emptyTargets.forEach((element) => element.remove())
  }
}
