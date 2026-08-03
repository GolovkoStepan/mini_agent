# frozen_string_literal: true

module MiniAgent
  # Печать отчёта /context: таблица категорий, токены, заполнение окна
  # и предупреждения.
  #
  # Отдельно от UI по тому же сигналу, что развёл LLMClient с ErrorResponse
  # и ChatResponse: класс перерос Metrics/ClassLength, и это в четвёртый раз
  # оказалось верно. Весь остальной UI — маркер, отступ и цвет; здесь же
  # решается, что показывать: три источника чисел (свой счёт знаков, usage
  # от сервера, размер окна), у каждого своё «неизвестно», и два разных
  # предупреждения с разным лечением.
  #
  # Печатает через UI, а не в поток напрямую: владелец вывода и раскраски
  # по-прежнему один.
  class ContextView
    def initialize(ui)
      @ui = ui
    end

    def call(report)
      return @ui.puts(Messages::CMD_CONTEXT_EMPTY) if report.empty?

      table(report)
      @ui.puts("")
      tokens(report)
      window(report.window)
      warnings(report)
    end

    private

    # Знаки и токены разделены пустой строкой намеренно: первые посчитаны
    # здесь и точны, вторые — то, что сообщил сервер. Смешивать измеренное
    # с полученным извне в одной таблице значит выдавать их за однородные.
    def table(report)
      @ui.puts(format(Messages::CMD_CONTEXT_HEADER, count: Plural.with(report.messages, *Messages::MESSAGES_WORD)))
      @ui.puts("")
      report.sizes.each { |name, size| line(name, size, report.share(name)) }
      @ui.puts(Messages::CMD_CONTEXT_RULE)
      @ui.puts(format(Messages::CMD_CONTEXT_TOTAL, name: Messages::CMD_CONTEXT_TOTAL_NAME, size: chars(report.total)))
    end

    def line(name, size, share)
      label = Messages::CMD_CONTEXT_NAMES.fetch(name, name.to_s)
      @ui.puts(format(Messages::CMD_CONTEXT_LINE, name: label, size: chars(size), share: share))
    end

    def chars(count) = Plural.with(count, *Messages::CHARS)

    # Отсутствие числа и ноль — разные вещи: сервер мог не прислать usage
    # вовсе, и промолчать об этом честнее, чем показать «0 токенов».
    def tokens(report)
      count = report.tokens
      return gray(Messages::CMD_CONTEXT_NO_TOKENS) if count.nil?

      gray(format(Messages::CMD_CONTEXT_TOKENS, count: Plural.with(count, *Messages::TOKENS)))
    end

    # Незнание размера окна показывается прямо. Молчание выглядело бы как
    # «процентов нет, потому что считать нечего», хотя причина другая:
    # протокол этого числа не передаёт, и его надо задать самому.
    def window(window)
      return gray(Messages::CMD_CONTEXT_WINDOW_UNKNOWN) unless window.known?
      return unless window.measurable?

      gray(format(
             Messages::CMD_CONTEXT_WINDOW,
             occupied: window.occupied, size: window.size, percent: window.percent
           ))
    end

    # Три беды с тремя разными лечениями: описание проекта правится файлом,
    # теснота лечится /compact, нехватка места под ответ — уменьшением
    # max_tokens. Слитые в одно, они посылали бы за лечением не туда.
    #
    # Про тесноту и про описание проекта говорится одной строкой, когда
    # верно и то и другое: раздельно они противоречили друг другу — «/compact
    # его не тронет» и тут же «пора звать /compact». Найдено живой проверкой;
    # по отдельности каждое предупреждение было верным, и тесты молчали.
    def warnings(report)
      tight_warning(report)
      starved_warning(report.window)
    end

    def tight_warning(report)
      window = report.window
      return @ui.warn(Messages::CMD_CONTEXT_FIXED) if report.project_dominates? && !window.tight?
      return unless window.tight?

      template = report.project_dominates? ? Messages::CMD_CONTEXT_TIGHT_PROJECT : Messages::CMD_CONTEXT_TIGHT
      @ui.warn(format(template, percent: window.percent))
    end

    def starved_warning(window)
      return unless window.starved?

      @ui.warn(format(Messages::CMD_CONTEXT_STARVED, free: window.free, limit: window.max_tokens))
    end

    def gray(text) = @ui.puts(@ui.paint(text, :gray))
  end
end
