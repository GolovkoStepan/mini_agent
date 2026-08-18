# frozen_string_literal: true

module MiniAgent
  # Создание описания проекта (/init): агент изучает каталог и пишет AGENTS.md.
  #
  # Работа идёт через обычный Agent#run, а не отдельным запросом, как в
  # Compactor. Разница вынужденная: свернуть диалог можно одним ответом, а
  # чтобы описать проект, его надо сначала прочитать — то есть нужен полный
  # цикл ходов с bash. Отсюда и следствие, с которым приходится мириться:
  # файл пишет модель командой, и гарантировать факт записи нельзя. Поэтому
  # результат проверяется после — по наличию файла на диске, а не по словам
  # модели о том, что она его создала.
  class Initializer
    def initialize(agent:, config:, ui:, prompt: nil)
      @agent = agent
      @config = config
      @ui = ui
      @prompt = prompt || Prompt.new
    end

    # Возвращает историю: команда ведёт обычный диалог, и его сообщения
    # остаются в ней, как после любой задачи.
    #
    # Именно ту, что вернул run, а не ту, что передали: изучение проекта —
    # длинная задача с чтением файлов, и окно на ней кончается чаще всего.
    # Автоматическое сворачивание заменяет историю новой, и прежняя после
    # этого — уже не история сессии.
    def call(conversation)
      return conversation unless confirm_overwrite?

      result = @agent.run(format(Messages::INIT_REQUEST, filename: target_name), conversation: conversation)
      report
      result
    end

    private

    # Рабочий каталог агента, а не тот, откуда его запустили: с --cwd это
    # разные места, и написать описание не туда — значит не найти его при
    # следующем запуске.
    def dir = @config.cwd || Dir.pwd

    # Пишем всегда в AGENTS.md, даже если нашлось .mini_agent.md: второе имя
    # существует для случая «AGENTS.md занят другим агентом», и создавать его
    # самим значило бы решать за пользователя чужой конфликт.
    def target_name = ProjectContext::FILENAMES.first
    def target_path = File.join(dir, target_name)

    # Существующее описание — не мусор: его мог писать человек. Спрашиваем
    # тем же способом, что и про опасную команду, и по той же причине.
    def confirm_overwrite?
      existing = ProjectContext.new(dir).filename
      return true unless existing

      @ui.warn(format(Messages::INIT_EXISTS, name: existing, size: size_of(existing)))
      return true if @prompt.confirm?(Messages::INIT_OVERWRITE)

      @ui.puts(Messages::INIT_CANCELLED)
      false
    end

    def size_of(name)
      Plural.with(File.size(File.join(dir, name)), *Messages::BYTES)
    rescue SystemCallError
      Messages::INIT_SIZE_UNKNOWN
    end

    # Проверяется файл на диске, а не ответ модели: та охотно рапортует
    # об успехе, не выполнив записи, — и это тот случай, когда верить
    # словам нельзя, потому что проверка стоит один вызов File.file?.
    def report
      return @ui.error(format(Messages::INIT_MISSING, name: target_name)) unless File.file?(target_path)

      @ui.puts(format(Messages::INIT_DONE, name: target_name, size: size_of(target_name)))
      @ui.puts(Messages::INIT_TAKES_EFFECT)
    end
  end
end
