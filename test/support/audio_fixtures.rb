module AudioFixtures
  def wav_audio
    samples = Array.new(32_000) { |i| (Math.sin(2 * Math::PI * 220 * i / 8000) * 6000).to_i }.pack('s<*')
    header = [16, 1, 1, 8000, 16_000, 2, 16].pack('VvvVVvv')
    "RIFF#{[36 + samples.bytesize].pack('V')}WAVEfmt #{header}data#{[samples.bytesize].pack('V')}#{samples}"
  end
end
