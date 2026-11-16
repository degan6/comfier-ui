import { Controller } from "@hotwired/stimulus"
import WaveSurfer from "wavesurfer.js"

// Draws a result's saved waveform over its audio element and stands in for the browser's own controls, which
// come back whenever the waveform can't be had. The player is data-turbo-permanent: a page refresh leaves it
// alone, so a song that's playing carries on.
export default class extends Controller {
  static targets = ["audio", "interface", "waveform", "seek", "tick", "play", "icon", "playLabel",
    "current", "duration", "speed", "mute", "notice"]
  static values = { waveformUrl: String }

  connect() {
    this.reset()
    this.abortController = new AbortController()
    // Load the saved envelope near the viewport; audio itself remains a streaming media element.
    this.visibilityObserver = new IntersectionObserver((entries) => {
      if (entries.some(entry => entry.isIntersecting)) {
        this.visibilityObserver.disconnect()
        this.load()
      }
    }, { rootMargin: "200px" })
    this.visibilityObserver.observe(this.element)
    this.themeObserver = new MutationObserver(() => this.wave?.setOptions(this.colors()))
    this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-bs-theme"] })
    this.sync()
  }

  async load() {
    if (this.audioTarget.error) return this.unavailable()
    const signal = this.abortController.signal
    try {
      const data = await this.fetchWaveform(signal)
      if (signal.aborted) return
      this.wave = WaveSurfer.create({
        container: this.waveformTarget,
        media: this.audioTarget,
        peaks: data.peaks,
        duration: data.duration,
        height: 108,
        normalize: false,
        interact: false,
        ...this.colors()
      })
      this.wave.on("ready", () => {
        this.audioTarget.hidden = true
        this.interfaceTarget.hidden = false
        this.noticeTarget.hidden = true
        this.sync()
      })
      this.wave.on("error", () => this.unavailable())
    } catch {
      if (!signal.aborted) this.unavailable()
    }
  }

  async fetchWaveform(signal) {
    for (let attempt = 0; attempt < 30; attempt++) {
      const response = await fetch(this.waveformUrlValue, { signal, headers: { Accept: "application/json" } })
      if (response.status === 202) {
        this.noticeTarget.textContent = "Preparing waveform…"
        await new Promise(resolve => { this.pollTimer = setTimeout(resolve, 2000) })
        continue
      }
      if (!response.ok) throw new Error("Waveform unavailable")
      return response.json()
    }
    throw new Error("Waveform preparation timed out")
  }

  unavailable() {
    this.wave?.destroy()
    this.wave = null
    this.interfaceTarget.hidden = true
    this.audioTarget.hidden = false
    this.noticeTarget.textContent = "Waveform unavailable. You can still use the audio player."
    this.noticeTarget.hidden = false
  }

  // Back to how the server rendered it, which a page restored from Turbo's cache isn't.
  reset() {
    this.waveformTarget.replaceChildren()
    this.interfaceTarget.hidden = true
    this.audioTarget.hidden = false
    this.noticeTarget.textContent = "Loading waveform…"
    this.noticeTarget.hidden = false
  }

  // The page is going away; a removed audio element would otherwise keep playing.
  disconnect() {
    this.visibilityObserver.disconnect()
    this.themeObserver.disconnect()
    this.abortController.abort()
    clearTimeout(this.pollTimer)
    this.audioTarget.pause()
    this.wave?.destroy()
    this.wave = null
  }

  colors() {
    const style = getComputedStyle(this.element)
    return {
      waveColor: style.getPropertyValue("--bs-secondary-color").trim(),
      progressColor: style.getPropertyValue("--bs-primary").trim(),
      cursorColor: style.getPropertyValue("--bs-body-color").trim()
    }
  }

  sync() {
    const audio = this.audioTarget
    const duration = Number.isFinite(audio.duration) ? audio.duration : 0
    this.currentTarget.textContent = this.time(audio.currentTime)
    this.durationTarget.textContent = this.time(duration)
    this.seekTarget.max = duration || 100
    this.seekTarget.value = audio.currentTime
    this.seekTarget.setAttribute("aria-valuetext", `${this.time(audio.currentTime)} of ${this.time(duration)}`)
    this.tickTargets.forEach((tick, index) => { tick.textContent = this.time(duration * index / 4) })
    this.playLabelTarget.textContent = audio.paused ? "Play" : "Pause"
    this.playTarget.setAttribute("aria-label", audio.paused ? "Play audio" : "Pause audio")
    this.iconTarget.className = `bi bi-${audio.paused ? "play" : "pause"} me-1`
    this.muteTarget.textContent = audio.muted ? "Unmute" : "Mute"
    this.muteTarget.setAttribute("aria-pressed", String(audio.muted))
    this.speedTarget.value = audio.playbackRate
  }

  async toggle() {
    if (!this.audioTarget.paused) return this.audioTarget.pause()
    try {
      await this.audioTarget.play()
      this.noticeTarget.hidden = true
    } catch {
      this.noticeTarget.textContent = "Audio could not start. Try pressing Play again."
      this.noticeTarget.hidden = false
    }
  }

  seek() {
    this.wave.setTime(Number(this.seekTarget.value))
    this.sync()
  }

  speed() {
    this.audioTarget.playbackRate = Number(this.speedTarget.value)
  }

  mute() {
    this.audioTarget.muted = !this.audioTarget.muted
  }

  time(seconds) {
    const value = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0
    return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`
  }
}
