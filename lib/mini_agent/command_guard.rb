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
  # Поверх политики стоит режим планирования (PlanMode): пока он включён,
  # выполняется только заведомо читающее, а всё остальное отвергается без
  # вопросов. Спросить там было бы неверно: план на то и план, что его
  # сначала показывают целиком, а потом одобряют — а не по команде за раз.
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

    def initialize(policy: :deny, prompt: Prompt.new, ui: nil, plan_mode: PlanMode.new)
      @policy = policy
      @prompt = prompt
      @ui = ui
      @plan_mode = plan_mode
    end

    def self.dangerous?(command)
      DANGEROUS_PATTERNS.any? { |pattern| command.to_s.match?(pattern) }
    end

    # Что делать с командой: :allow — выполнять, :cancelled — человек
    # отказался, :planning — режим планирования не выполняет ничего, кроме
    # чтения. Символ, а не булев признак: два отказа объясняются модели
    # по-разному, и различить их постфактум было бы не по чему.
    #
    # Порядок ветвлений существен, и режим планирования стоит первым — раньше
    # даже денилиста. Иначе на `rm -rf` в планировании появился бы вопрос
    # «выполнять?» — предложение сделать ровно то, ради невыполнения чего
    # режим и включён.
    #
    # Дальше денилист проверяется раньше списка читающих: у команды с
    # подстановкой или перенаправлением ReadOnly и так ответит «нет», но
    # полагаться на это нельзя — при добавлении в список чего-нибудь вроде
    # `find` опасная форма прошла бы молча. Сам порядок живёт в decide.
    def verdict(command)
      decide(command, read_only: ReadOnly.command?(command), dangerous: self.class.dangerous?(command))
    end

    # То же решение для операции, которая командой shell не является.
    # Файловые инструменты знают про себя точно, читают они или пишут, — и
    # выяснять это разбором строки, со всеми границами ReadOnly, здесь незачем.
    # Ради этого разделение и заводилось: режим планирования переставал
    # пропускать чтение по недоразумению.
    #
    # `action` — описание для человека («write_file lib/foo.rb»), а не команда:
    # выполняться оно не будет нигде, поэтому денилист к нему неприменим.
    # Опасность файловой операции — это её путь, а пути денилист не разбирает.
    def verdict_for(action, read_only:)
      decide(action, read_only: read_only, dangerous: false)
    end

    private

    # Порядок ветвлений — тот самый, что описан у verdict: сперва режим
    # планирования (для команд он же и есть проверка на чтение), затем
    # денилист, и только потом политика.
    def decide(subject, read_only:, dangerous:)
      return :planning unless @plan_mode.permits?(read_only: read_only)

      if @policy == :unsafe
        warn_only(subject) if dangerous
        return :allow
      end

      return confirmed(Messages::DANGEROUS_COMMAND, subject) if dangerous
      return :allow if @policy == :deny || read_only

      confirmed(Messages::WRITING_COMMAND, subject)
    end

    def confirmed(warning, command)
      @ui&.warn(format(warning, command: command))
      @prompt.confirm?(Messages::CONFIRM_PROMPT) ? :allow : :cancelled
    end

    # Предупреждаем только об опасном: при :unsafe человек уже сказал, что
    # обычные команды его не интересуют, и строка на каждый `ls` из полезной
    # пометки превратилась бы в шум, за которым не видно настоящей.
    def warn_only(command)
      @ui&.warn(format(Messages::DANGEROUS_COMMAND_ALLOWED, command: command))
    end
  end
end
