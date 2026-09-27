import { Controller } from "@hotwired/stimulus"

// Hides list items whose data-text doesn't contain the query; opens groups that have matches.
export default class extends Controller {
  static targets = ["item", "group"]

  filter(event) {
    const query = event.target.value.trim().toLowerCase()
    this.itemTargets.forEach((item) => {
      item.hidden = query !== "" && !item.dataset.text.includes(query)
    })
    this.groupTargets.forEach((group) => {
      const visible = group.querySelectorAll("[data-filter-list-target='item']:not([hidden])").length
      group.hidden = query !== "" && visible === 0
      group.open = query !== "" && visible > 0
    })
  }
}
