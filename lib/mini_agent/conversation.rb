# frozen_string_literal: true

require "securerandom"
require "rbconfig"

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
    # cwd — каталог, в котором выполняются команды. Попадает в промпт, потому
    # что иначе модель его выдумывает (см. Messages::ENVIRONMENT).
    def initialize(system_prompt: Messages::SYSTEM_PROMPT, project_context: nil, transcript: nil, cwd: nil)
      @messages = []
      @transcript = transcript
      @project_context_size = 0
      prompt = build_prompt(system_prompt, project_context, cwd)
      system(prompt) if prompt
    end

    # Сколько знаков системного сообщения занимает описание проекта.
    #
    # Запоминается при сборке, а не вычисляется потом разбором готового
    # промпта по образцу разметки: пара «формат и его разбор» уже есть
    # в проекте (EXIT_CODE / EXIT_CODE_PATTERN) и держится рядом только
    # под присмотром. Заводить вторую такую пару ради одной цифры значит
    # создать место, которое молча разойдётся при первой правке разметки.
    attr_reader :project_context_size

    def system(content)
      push({ role: "system", content: content })
    end

    def user(content)
      push({ role: "user", content: content })
    end

    # content намеренно может быть nil: когда модель возвращает только
    # tool_calls без текста, спецификация API требует именно null, а не "".
    #
    # usage уходит только в журнал и НЕ попадает в сообщение: история целиком
    # отправляется модели через to_a, и лишнее поле поехало бы вместе с ней.
    # В логе же оно на месте — по нему видно, на каком ходу раздулся контекст.
    def assistant(content, tool_calls: nil, usage: nil)
      message = { role: "assistant", content: normalize_content(content) }
      message[:tool_calls] = tool_calls if tool_calls && !tool_calls.empty?
      push(message, usage: usage)
    end

    def tool(tool_call_id, content)
      push({ role: "tool", tool_call_id: tool_call_id, content: content })
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
    def build_prompt(system_prompt, project_context, cwd)
      prompt = system_prompt ? "#{system_prompt}#{environment(cwd)}" : system_prompt
      return prompt if project_context.nil? || project_context.strip.empty?

      block = format(Messages::PROJECT_CONTEXT, content: project_context.strip)
      @project_context_size = block.length
      "#{prompt}#{block}"
    end

    # Без системного промпта блок не приклеивается: он часть того же
    # объяснения, как устроен инструмент, и в одиночку описывал бы окружение
    # агента, о котором модели ничего не сказано. Описание проекта тем и
    # отличается — оно нужно ей независимо от того, объяснили ли ей правила.
    def environment(cwd)
      return "" unless cwd

      format(Messages::ENVIRONMENT, cwd: cwd, os: RbConfig::CONFIG["host_os"])
    end

    # В историю кладётся само сообщение, а в журнал — оно же плюс расход
    # токенов: в @messages ему нельзя, иначе уедет модели вместе с историей.
    def push(message, usage: nil)
      @messages << message
      @transcript&.message(usage ? message.merge(usage: usage) : message)
      message
    end

    def normalize_content(content)
      return nil if content.nil?

      text = content.to_s
      text.empty? ? nil : text
    end
  end
end
