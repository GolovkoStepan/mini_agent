# frozen_string_literal: true

module MiniAgent
  module Tools
    # Единственный инструмент агента: выполнение shell-команды.
    class Bash
      NAME = "bash"

      SCHEMA = {
        "type" => "function",
        "function" => {
          "name" => NAME,
          "description" => "Execute a shell command and return the output.",
          "parameters" => {
            "type" => "object",
            "properties" => {
              "command" => {
                "type" => "string",
                "description" => "The bash command to execute."
              }
            },
            "required" => ["command"]
          }
        }
      }.freeze

      def initialize(guard:, runner:)
        @guard = guard
        @runner = runner
      end

      def name = NAME

      def schema = SCHEMA

      # Всегда возвращает строку: ошибки выполнения — это тоже результат,
      # который модель должна увидеть и обработать, а не исключение,
      # роняющее цикл агента.
      def call(arguments)
        command = arguments["command"].to_s
        return Messages::EMPTY_COMMAND if command.strip.empty?

        # Два отказа с разным объяснением: человек отклонил именно эту команду
        # (пробовать иначе можно) — или идёт планирование, где не выполняется
        # целый класс команд и следующая попытка кончится тем же.
        case @guard.verdict(command)
        when :cancelled then Messages::CANCELLED
        when :planning then Messages::PLAN_REFUSED
        else execute(command)
        end
      end

      private

      def execute(command)
        result = @runner.call(command)
        format_result(result)
      rescue TimeoutError => e
        e.message
      rescue StandardError => e
        format(Messages::EXECUTION_FAILED, message: e.message)
      end

      def format_result(result)
        output = +format(Messages::EXIT_CODE, code: result.exit_code)
        output << "\n" << result.stdout
        output << format(Messages::STDERR_SECTION, stderr: result.stderr) unless result.stderr.empty?
        output
      end
    end
  end
end
