# frozen_string_literal: true

module MiniAgent
  # Запрос подтверждения у пользователя.
  #
  # Выделен в отдельный класс, чтобы CommandGuard не обращался к STDIN
  # напрямую: в тестах подставляется StringIO или готовый ответ, и примеры
  # не зависают в ожидании ввода.
  class Prompt
    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
    end

    # Подтверждением считается только явное "y" — обрыв ввода (Ctrl+D),
    # пустая строка и что угодно ещё означают отказ.
    def confirm?(question)
      @output.print(question)
      @output.flush if @output.respond_to?(:flush)

      answer = @input.gets
      return false if answer.nil?

      answer.strip.downcase == "y"
    end

    # Заглушка для тестов и неинтерактивных сценариев: всегда «да».
    class AutoApprove
      def confirm?(_question) = true
    end

    # Заглушка для тестов и неинтерактивных сценариев: всегда «нет».
    class AutoDeny
      def confirm?(_question) = false
    end
  end
end
