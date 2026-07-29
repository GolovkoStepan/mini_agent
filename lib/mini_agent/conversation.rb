# frozen_string_literal: true

require "securerandom"

module MiniAgent
  # История диалога в формате OpenAI chat completions.
  #
  # Ключи всегда нормализуются в символы: в исходном скрипте свои сообщения
  # складывались с символьными ключами, а пришедшие от модели tool_calls —
  # со строковыми, и по массиву приходилось ходить с оглядкой на источник.
  class Conversation
    def initialize(system_prompt: Messages::SYSTEM_PROMPT)
      @messages = []
      system(system_prompt) if system_prompt
    end

    def system(content)
      push(role: "system", content: content)
    end

    def user(content)
      push(role: "user", content: content)
    end

    # content намеренно может быть nil: когда модель возвращает только
    # tool_calls без текста, спецификация API требует именно null, а не "".
    def assistant(content, tool_calls: nil)
      message = { role: "assistant", content: normalize_content(content) }
      message[:tool_calls] = tool_calls if tool_calls && !tool_calls.empty?
      push(message)
    end

    def tool(tool_call_id, content)
      push(role: "tool", tool_call_id: tool_call_id, content: content)
    end

    def to_a
      @messages.map(&:dup)
    end

    def last
      @messages.last
    end

    def size
      @messages.size
    end

    def empty?
      @messages.empty?
    end

    # Идентификатор для tool-ответа: модель обязана присылать id, но не все
    # локальные сборки это делают, а без него ответ инструмента не сматчится.
    def self.tool_call_id(tool_call)
      id = tool_call["id"] || tool_call[:id]
      return id if id && !id.to_s.empty?

      "call_#{SecureRandom.hex(8)}"
    end

    private

    def push(message)
      @messages << message
      message
    end

    def normalize_content(content)
      return nil if content.nil?

      text = content.to_s
      text.empty? ? nil : text
    end
  end
end
