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
    def confirm?(question) = ask(question) == "y"

    # Ответ как он есть, приведённый к нижнему регистру. Нужен там, где
    # ответов больше двух: у плана их три (да, правка, нет), и булев
    # признак слил бы правку с отказом. Обрыв ввода — пустая строка,
    # то есть ни один из названных ответов.
    def ask(question)
      @output.print(question)
      @output.flush if @output.respond_to?(:flush)

      @input.gets.to_s.strip.downcase
    end

    # Заглушка для тестов и неинтерактивных сценариев: всегда «да».
    class AutoApprove
      def confirm?(_question) = true
      def ask(_question) = "y"
    end

    # Заглушка для тестов и неинтерактивных сценариев: всегда «нет».
    class AutoDeny
      def confirm?(_question) = false
      def ask(_question) = "n"
    end
  end
end
