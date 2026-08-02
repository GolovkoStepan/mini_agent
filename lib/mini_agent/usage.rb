# frozen_string_literal: true

module MiniAgent
  # Расход токенов за сессию.
  #
  # Токены генерации складываются, а токены промпта — нет: история уходит
  # модели целиком на каждом ходу, и `prompt_tokens` растёт от запроса
  # к запросу (измерено на LM Studio: 13 → 32 → 57 за три хода одного
  # диалога). Их сумма — 102 — не значит ничего, а вот последнее значение
  # осмысленно: это текущий размер контекста, то самое число, которое
  # упирается в окно модели.
  #
  # `reasoning_tokens` из `completion_tokens_details` отдельно не считается:
  # живая проверка показала, что он входит в `completion_tokens`, а не идёт
  # сверх (`completion=150, reasoning=150`, и `prompt + completion == total`).
  class Usage
    def initialize
      @sent = 0
      @generated = 0
      @context = 0
      @requests = 0
    end

    # Всего отправлено модели за сессию — сумма промптов со всех запросов.
    # Число честное, но означает «сколько прокачано через сеть», а не размер
    # диалога: одни и те же сообщения уходят повторно на каждом ходу.
    attr_reader :sent

    # Сгенерировано моделью за сессию.
    attr_reader :generated

    # Промпт последнего запроса — текущий размер контекста.
    attr_reader :context

    # Сколько запросов учтено. Нужен, чтобы отличить «ещё не спрашивали»
    # от «спросили, но сервер не прислал usage».
    attr_reader :requests

    # usage приходит из ответа как есть и может отсутствовать вовсе:
    # спецификация его не требует, и не всякий сервер шлёт. Отсутствие —
    # не ошибка, просто считать нечего.
    def add(usage)
      return self unless usage.is_a?(Hash)

      @sent += number(usage, "prompt_tokens")
      @generated += number(usage, "completion_tokens")
      @context = number(usage, "prompt_tokens")
      @requests += 1
      self
    end

    def empty?
      @requests.zero?
    end

    def to_h
      { sent: @sent, generated: @generated, context: @context, requests: @requests }
    end

    private

    # Ключи могут прийти строками (из JSON) или символами (из тестов и
    # рукописных стабов) — принимаем оба вида, чтобы источник не имел значения.
    def number(usage, key)
      value = usage[key] || usage[key.to_sym]
      value.to_i
    end
  end
end
