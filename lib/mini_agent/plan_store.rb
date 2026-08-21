# frozen_string_literal: true

require "fileutils"
require "time"

module MiniAgent
  # Готовый план — в файл на диске.
  #
  # Заведено ради двух вещей сразу. Первая: с --plan план и есть единственный
  # продукт запуска, а живёт он до прокрутки буфера терминала. Вторая важнее —
  # после одобрения история планирования выбрасывается и собирается заново
  # (см. Planner#execute), и текст плана обязан существовать где-то, кроме неё.
  #
  # Отдельный класс, а не метод Planner: файловая система — чужая задача.
  # Тем же порогом из Config в своё время выделился Paths.
  #
  # Незаписанный файл сессию не рушит: save возвращает nil и оставляет причину
  # в #error, а работа продолжается. Тот же выбор, что у Transcript, и по той
  # же причине — план нужен человеку, а не агенту, и потеря файла не отменяет
  # уже проделанной работы.
  class PlanStore
    DIR = "~/.mini_agent/plans"

    # Имя длиннее этого не читается в `ls`, а короче — не отличает один план
    # от другого. Знаков, а не байтов: слаг кириллический, и байтовая мера
    # обрезала бы русское имя вдвое раньше английского при равной длине.
    SLUG_LIMIT = 60

    # Белый список, а не чёрный: имя файла собирается из текста, который писал
    # человек, и перечислить всё, чего в нём быть не должно, нельзя.
    #
    # [[:alnum:]], а не \w: тот в Ruby ограничен ASCII, и русская задача
    # схлопнулась бы в пустое имя целиком. Ровно те же грабли уже описаны
    # у SlashCommands::PATTERN.
    ALLOWED = /[[:alnum:]]+/

    # Слаг из одних недопустимых знаков (например «???») даёт пустую строку,
    # и файл получил бы имя из одной даты. Отличать такие планы друг от друга
    # было бы нечем.
    FALLBACK_SLUG = "plan"

    # Чтение записанного файла живёт рядом с записью, а не у PlanEditor:
    # шапка и её разбор — это формат и его разбор, а такая пара обязана
    # меняться вместе (прецедент EXIT_CODE и EXIT_CODE_PATTERN у Tools::Bash).
    # Ошибки чтения не ловятся здесь намеренно: save возвращает nil потому,
    # что план уже составлен и терять работу из-за прав на каталог незачем,
    # а здесь терять нечего — правку либо перечитали, либо нет.
    def self.body(path)
      lines = File.read(path).lines
      lines.drop(lines.take_while { |line| line.match?(Messages::PLAN_FILE_HEADER) }.size).join.strip
    end

    # clock инъектируется ради теста: имя файла содержит время, и без этого
    # проверять пришлось бы регулярным выражением, то есть не проверять вовсе.
    def initialize(dir: DIR, clock: Time)
      @dir = File.expand_path(dir)
      @clock = clock
      @error = nil
    end

    attr_reader :error

    # Возвращает путь к записанному файлу либо nil. Причина неудачи остаётся
    # в #error — печатать её здесь нельзя: класс не знает, куда выводить,
    # а вызывающий знает и решает сам, предупреждение это или отказ.
    def save(plan, task:, config: nil)
      @error = nil
      FileUtils.mkdir_p(@dir, mode: 0o700)
      path = free_path(slug(task))
      File.write(path, document(plan, task: task, config: config))
      File.chmod(0o600, path)
      path
    rescue SystemCallError, IOError => e
      @error = e.message
      nil
    end

    private

    # Права 0o700 на каталог и 0o600 на файл: план пересказывает содержимое
    # рабочего проекта, а тот бывает закрытым. Каталог общий на все планы,
    # так что достаточно один раз, но mkdir_p с mode ставит их только при
    # создании — существующий каталог остаётся как есть, и это верно:
    # человек мог поменять права осознанно.
    def document(plan, task:, config: nil)
      header = [
        format(Messages::PLAN_FILE_TASK, task: task),
        format(Messages::PLAN_FILE_TIME, time: @clock.now.iso8601)
      ]
      header << format(Messages::PLAN_FILE_MODEL, model: config.model) if config
      header << format(Messages::PLAN_FILE_CWD, path: config.cwd || Dir.pwd) if config
      "#{header.join("\n")}\n\n#{plan.strip}\n"
    end

    # Перезаписи не бывает никогда: два плана по одной задаче в одну минуту —
    # это обычная итерация «уточнить и переспросить», и второй затирал бы
    # первый ровно в тот момент, когда их и хотели сравнить.
    def free_path(slug)
      base = "#{@clock.now.strftime("%Y-%m-%d-%H%M")}-#{slug}"
      path = File.join(@dir, "#{base}.md")
      suffix = 1
      path = File.join(@dir, "#{base}-#{suffix += 1}.md") while File.exist?(path)
      path
    end

    # Транслитерации нет намеренно: задачи здесь пишут по-русски, и
    # `pochini-testy` читается хуже исходного, а таблица перевода стала бы
    # ещё одним местом, которое надо поддерживать.
    def slug(task)
      words = task.to_s.downcase.scan(ALLOWED)
      return FALLBACK_SLUG if words.empty?

      slug = words.join("-")[0, SLUG_LIMIT]
      slug.sub(/-\z/, "")
    end
  end
end
