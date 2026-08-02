# frozen_string_literal: true

module MiniAgent
  # Описание проекта, дописываемое к системному промпту.
  #
  # Без него агент выясняет устройство проекта заново на каждом запуске: чем
  # запускаются тесты, куда складывать код, на каком языке комментарии. Это
  # три-четыре хода `ls` и `cat` перед началом работы — и каждый раз одни и те
  # же выводы, потому что история между запусками не живёт.
  #
  # Ищутся два имени: AGENTS.md (складывающееся межинструментальное соглашение)
  # и .mini_agent.md (если в проекте уже лежит AGENTS.md для другого агента, а
  # этому нужно сказать своё). Первое найденное побеждает — склейка двух
  # файлов дала бы противоречивые указания без способа их развести.
  class ProjectContext
    FILENAMES = %w[AGENTS.md .mini_agent.md].freeze

    # Потолок в 32 КБ: файл больше — это уже не описание проекта, а его
    # документация, и она вытеснит из контекстного окна саму задачу.
    # Обрезается по границе строки, чтобы не оборвать фразу на середине.
    MAX_SIZE = 32_000

    def self.load(dir = Dir.pwd)
      new(dir).load
    end

    def initialize(dir = Dir.pwd)
      @dir = dir
    end

    # Возвращает содержимое файла или nil, если его нет.
    def load
      path = find
      return nil unless path

      content = read(path)
      return nil if content.nil? || content.strip.empty?

      truncate(content)
    end

    # Имя найденного файла — для сообщения пользователю о том, что контекст
    # подхвачен. Молчаливое изменение поведения агента хуже лишней строки
    # в выводе: иначе непонятно, почему он вдруг знает про `make spec`.
    def filename
      path = find
      path && File.basename(path)
    end

    private

    def find
      @find ||= FILENAMES.lazy.map { |name| File.join(@dir, name) }.find { |path| File.file?(path) }
    end

    # Нечитаемый файл — не повод падать: агент прекрасно работает и без
    # описания проекта, а разбираться с правами посреди задачи незачем.
    def read(path)
      File.read(path)
    rescue SystemCallError, IOError
      nil
    end

    # scrub — потому что byteslice режет по байтам и может разрубить
    # многобайтовый символ; отбрасывание последней строки убирает обрывок,
    # но полагаться на это в файле без переводов строк нельзя.
    def truncate(content)
      return content if content.bytesize <= MAX_SIZE

      kept = content.byteslice(0, MAX_SIZE).to_s.scrub("").lines[0..-2].to_a.join
      kept + Messages::CONTEXT_TRUNCATED
    end
  end
end
