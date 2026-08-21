# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module MiniAgent
  # Каталог сохранённых сессий: куда пишется журнал, когда --log не задан,
  # и какой файл продолжает --resume без аргумента.
  #
  # Своего формата здесь нет намеренно — пишет всё тот же Transcript, читает
  # Replay. Второй писатель того же содержимого разошёлся бы с первым при
  # первой правке формата, а разница была бы видна только по невозможности
  # продолжить старую сессию.
  #
  # Сохранение включено по умолчанию, в отличие от --log, и это не
  # противоречие: --log называет файл, который человек кладёт куда захочет
  # и потом кому-то показывает, а здесь файл в своём каталоге с правами 0700,
  # без которого --resume нечего продолжать. О записи всё равно сообщается
  # строкой в выводе — молчаливого сохранения задач и прочитанных файлов
  # быть не должно (тот же довод, что у LOG_STARTED).
  class SessionStore
    DIR = "~/.mini_agent/sessions"

    # Слаг из имени рабочего каталога: в `ls` иначе видны одни даты, а
    # выбирают сессию как раз по проекту. Полный путь в имя не годится —
    # он длиннее любого разумного имени файла, и он же лежит в заголовке.
    SLUG_LIMIT = 40
    ALLOWED = /[[:alnum:]]+/
    FALLBACK_SLUG = "session"

    # clock инъектируется ради теста — по той же причине, что и у PlanStore:
    # имя файла содержит время.
    def initialize(dir: DIR, clock: Time)
      @dir = File.expand_path(dir)
      @clock = clock
      @error = nil
    end

    attr_reader :error

    # Путь нового файла сессии либо nil, если каталог не создался. Причина
    # остаётся в #error: сохранение — не та работа, ради которой запускали
    # агента, и права на каталог не повод не начинать задачу.
    def path(cwd)
      @error = nil
      FileUtils.mkdir_p(@dir, mode: 0o700)
      free_path(slug(cwd))
    rescue SystemCallError => e
      @error = e.message
      nil
    end

    # Последняя сессия ЭТОГО рабочего каталога либо nil.
    #
    # Каталог сверяется по заголовку, а не по имени файла: слаг обрезан и
    # у ~/work/agent совпадает с ~/tmp/agent. Продолжить чужую сессию молча
    # хуже, чем не найти ни одной: история уедет модели целиком, и понять,
    # почему та рассуждает о другом проекте, будет не по чему.
    def latest(cwd)
      files.find { |file| header(file)&.fetch("cwd", nil) == cwd }
    end

    private

    # По времени изменения, а не по имени: имя содержит время создания, а
    # продолжают ту сессию, в которой работали последней.
    def files
      Dir.glob(File.join(@dir, "*.jsonl")).sort_by { |file| -File.mtime(file).to_i }
    rescue SystemCallError
      []
    end

    # Заголовок — первая строка файла (Transcript пишет его сразу после
    # открытия). Битую строку молча пропускаем: файл мог остаться от убитого
    # процесса, и это не повод падать при выборе сессии.
    def header(file)
      record = JSON.parse(File.foreach(file).first.to_s)
      record["type"] == "session" ? record : nil
    rescue JSON::ParserError, SystemCallError, IOError
      nil
    end

    # Секунды в имени, и всё равно с проверкой на занятость: оценочные задачи
    # запускают агента подряд, и две сессии в одну секунду — обычное дело.
    def free_path(slug)
      base = "#{@clock.now.strftime("%Y-%m-%d-%H%M%S")}-#{slug}"
      path = File.join(@dir, "#{base}.jsonl")
      suffix = 1
      path = File.join(@dir, "#{base}-#{suffix += 1}.jsonl") while File.exist?(path)
      path
    end

    def slug(cwd)
      words = File.basename(cwd.to_s).downcase.scan(ALLOWED)
      return FALLBACK_SLUG if words.empty?

      words.join("-")[0, SLUG_LIMIT].sub(/-\z/, "")
    end
  end
end
