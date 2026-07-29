# frozen_string_literal: true

module MiniAgent
  # Проверка команд на очевидно разрушительные конструкции.
  #
  # ВАЖНО ПОНИМАТЬ ГРАНИЦЫ. Это денилист регулярных выражений поверх строки,
  # которую составляет сама модель. Он ловит случайный `rm -rf` и опечатки,
  # но песочницей не является: тривиальное переписывание команды
  # (переменные, кавычки, base64) обходит любой такой список. Не полагайтесь
  # на него как на границу безопасности при работе с недоверенной моделью.
  class CommandGuard
    DANGEROUS_PATTERNS = [
      /\brm\s+(-[a-z]*\s+)*-[a-z]*[rf]/i, # rm -rf, rm -r -f, rm --force
      /\bsudo\b/,
      /\bdoas\b/,
      /\bchmod\s+-?R?\s*777\b/,
      /\bdd\s+if=/,
      /\bmkfs\./,
      /\bcurl\b.*\|\s*(sudo\s+)?(ba|z|k)?sh\b/, # curl ... | sh
      /\bwget\b.*\|\s*(sudo\s+)?(ba|z|k)?sh\b/,
      %r{>\s*/dev/(sd|nvme|hd|disk|rdisk)}, # перезапись блочного устройства
      /\bshutdown\b|\breboot\b|\bhalt\b/,
      /:\(\)\s*\{\s*:\|\s*:&\s*\}\s*;\s*:/ # форк-бомба
    ].freeze

    def initialize(allow_unsafe: false, prompt: Prompt.new, ui: nil)
      @allow_unsafe = allow_unsafe
      @prompt = prompt
      @ui = ui
    end

    def self.dangerous?(command)
      DANGEROUS_PATTERNS.any? { |pattern| command.to_s.match?(pattern) }
    end

    # true — команду можно выполнять.
    def authorize?(command)
      return true unless self.class.dangerous?(command)

      if @allow_unsafe
        warn_only(command)
        return true
      end

      @ui&.warn(format(Messages::DANGEROUS_COMMAND, command: command))
      @prompt.confirm?(Messages::CONFIRM_PROMPT)
    end

    private

    def warn_only(command)
      @ui&.warn(format(Messages::DANGEROUS_COMMAND_ALLOWED, command: command))
    end
  end
end
