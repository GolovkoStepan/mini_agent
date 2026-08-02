# frozen_string_literal: true

require "securerandom"

module MiniAgent
  # История диалога в формате OpenAI chat completions.
  #
  # Ключи всегда нормализуются в символы: в исходном скрипте свои сообщения
  # складывались с символьными ключами, а пришедшие от модели tool_calls —
  # со строковыми, и по массиву приходилось ходить с оглядкой на источник.
  class Conversation
    # project_context — описание проекта (AGENTS.md и подобные). Дописывается
    # к системному промпту, а не отдельным сообщением: шаблоны чата ряда
    # моделей (Qwen и другие) требуют, чтобы system-сообщение было ровно одно
    # и первое, и отвечают HTTP 400 на второе.
    # transcript — необязательный журнал (см. Transcript). Пишет отсюда, а не
    # из Agent: сообщения добавляются и мимо цикла ходов — системный промпт
    # здесь же в конструкторе, а Repl по /clear заводит историю заново, и
    # логирование в Agent пришлось бы дублировать на каждом таком месте.
    def initialize(system_prompt: Messages::SYSTEM_PROMPT, project_context: nil, transcript: nil)
      @messages = []
      @transcript = transcript
      prompt = build_prompt(system_prompt, project_context)
      system(prompt) if prompt
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

    # Отметка, к которой можно вернуться, если ход не удался. Возвращаемое
    # значение непрозрачно для вызывающего кода: сегодня это размер истории,
    # но опираться на это снаружи не следует.
    def mark
      @messages.size
    end

    # Откат неудачного хода: снимает всё, что добавилось после отметки.
    #
    # Нужен потому, что провалившийся запрос оставляет за собой мусор, из-за
    # которого падает и следующий: висящее user-сообщение без ответа, а при
    # упоре в контекстное окно — ещё и результат инструмента, который туда
    # не влез. Без отката сессия оставалась мёртвой до /clear (проверено
    # живьём: следующий вопрос к модели уже не доходил).
    #
    # Журнал при этом не переписывается: он протоколирует то, что реально
    # уходило модели, и задним числом чистить его нельзя. Вместо удаления
    # пишется отдельная запись об откате.
    def rollback(mark)
      removed = @messages.size - mark
      return 0 unless removed.positive?

      @messages.pop(removed)
      @transcript&.rollback(removed)
      removed
    end

    # Идентификатор для tool-ответа: модель обязана присылать id, но не все
    # локальные сборки это делают, а без него ответ инструмента не сматчится.
    def self.tool_call_id(tool_call)
      id = tool_call["id"] || tool_call[:id]
      return id if id && !id.to_s.empty?

      "call_#{SecureRandom.hex(8)}"
    end

    private

    # Контекст без промпта тоже осмыслен: --system-prompt отключён, а описание
    # проекта модели всё равно нужно.
    def build_prompt(system_prompt, project_context)
      return system_prompt if project_context.nil? || project_context.strip.empty?

      block = format(Messages::PROJECT_CONTEXT, content: project_context.strip)
      "#{system_prompt}#{block}"
    end

    def push(message)
      @messages << message
      @transcript&.message(message)
      message
    end

    def normalize_content(content)
      return nil if content.nil?

      text = content.to_s
      text.empty? ? nil : text
    end
  end
end
