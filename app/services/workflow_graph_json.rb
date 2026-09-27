# Parses workflow JSON that may contain bare {{placeholders}} in numeric slots.
class WorkflowGraphJson
  BARE_PLACEHOLDER = /\A\{\{\s*(\w+)\s*\}\}/

  def self.normalize(text) = new(text).normalize

  # Uploaded files often arrive as ASCII-8BIT; views need UTF-8 strings.
  def self.utf8_string(text)
    str = text.to_s.dup
    return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

    str = str.force_encoding(Encoding::UTF_8)
    return str if str.valid_encoding?

    str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end

  def initialize(text)
    @text = self.class.utf8_string(text)
  end

  def normalize # rubocop:disable Metrics/MethodLength -- small scanner; splitting would obscure the state machine
    out = +''
    i = 0
    in_string = false
    escaped = false

    while i < @text.length
      if in_string
        char = @text[i]
        out << char
        escaped, in_string = next_string_state(char, escaped, in_string)
        i += 1
      elsif (match = @text[i..].match(BARE_PLACEHOLDER))
        out << '"' << match[0] << '"'
        i += match[0].length
      else
        char = @text[i]
        out << char
        in_string = true if char == '"'
        i += 1
      end
    end

    out
  end

  private

  def next_string_state(char, escaped, in_string)
    return [false, in_string] if escaped
    return [true, in_string] if char == '\\'
    return [false, false] if char == '"'

    [false, in_string]
  end
end
