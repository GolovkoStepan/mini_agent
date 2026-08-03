# frozen_string_literal: true

module MiniAgent
  # Что выполнять молча, а что спрашивать.
  #
  # ВАЖНО ПОНИМАТЬ ГРАНИЦЫ. Здесь два списка поверх строки, которую составляет
  # сама модель: денилист заведомо разрушительного (DANGEROUS_PATTERNS) и
  # список заведомо читающего (ReadOnly). Оба — фильтры, а не песочница:
  # тривиальное переписывание команды (переменные, кавычки, base64) обходит
  # любой такой список. Не полагайтесь на них как на границу безопасности при
  # работе с недоверенной моделью.
  #
  # Политика выбирает, как поступать с тем, что не попало ни в один список:
  #
  #   :deny   — выполнять молча. Спрашиваем только по денилисту (умолчание).
  #   :ask    — спрашивать. Молча идёт только заведомо читающее.
  #   :unsafe — выполнять всё, про денилист лишь предупреждать.
  #
  # Умолчанием оставлен :deny, а не :ask: агента зовут работать, и на первой
  # же задаче вида «запусти тесты» строгая политика превращает работу в череду
  # подтверждений. Кто хочет её — включает флагом осознанно.
  class CommandGuard
    POLICIES = %i[deny ask unsafe].freeze

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

    def initialize(policy: :deny, prompt: Prompt.new, ui: nil)
      @policy = policy
      @prompt = prompt
      @ui = ui
    end

    def self.dangerous?(command)
      DANGEROUS_PATTERNS.any? { |pattern| command.to_s.match?(pattern) }
    end

    # true — команду можно выполнять.
    #
    # Порядок ветвлений существен. Денилист проверяется раньше списка
    # читающих: у команды с подстановкой или перенаправлением ReadOnly и так
    # ответит «нет», но полагаться на это нельзя — при добавлении в список
    # чего-нибудь вроде `find` опасная форма прошла бы молча.
    def authorize?(command)
      dangerous = self.class.dangerous?(command)

      if @policy == :unsafe
        warn_only(command) if dangerous
        return true
      end

      return confirm?(Messages::DANGEROUS_COMMAND, command) if dangerous
      return true if @policy == :deny || ReadOnly.command?(command)

      confirm?(Messages::WRITING_COMMAND, command)
    end

    private

    def confirm?(warning, command)
      @ui&.warn(format(warning, command: command))
      @prompt.confirm?(Messages::CONFIRM_PROMPT)
    end

    # Предупреждаем только об опасном: при :unsafe человек уже сказал, что
    # обычные команды его не интересуют, и строка на каждый `ls` из полезной
    # пометки превратилась бы в шум, за которым не видно настоящей.
    def warn_only(command)
      @ui&.warn(format(Messages::DANGEROUS_COMMAND_ALLOWED, command: command))
    end
  end
end
