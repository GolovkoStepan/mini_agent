# frozen_string_literal: true

module MiniAgent
  module Tools
    # Общее у трёх файловых инструментов: путь, охрана, обработка отказов
    # файловой системы.
    #
    # Инструменты заведены не ради удобства. Запись файла через heredoc в
    # `bash` — это генерация длинного текста внутри аргумента команды, то есть
    # ровно то место, где небольшая модель ломается: незакрытый разделитель,
    # съеденные кавычки, подставленная переменная вместо текста. Хуже того,
    # ломается она молча — `bash` возвращает код 0, модель докладывает об
    # успехе, а в файле лежит половина. Здесь текст приходит отдельным полем
    # JSON и до shell не доходит вовсе.
    #
    # Второе, что даёт разделение: охрана знает точно, читает операция или
    # пишет, а не угадывает это разбором строки (см. CommandGuard#verdict_for
    # и границы ReadOnly). Режим планирования от этого перестаёт отказывать
    # чтению по недоразумению.
    #
    # Наследование, а не примесь и не три отдельных класса: у трёх операций
    # общий не только путь, но и весь порядок — проверить аргумент, спросить
    # охрану, выполнить, объяснить отказ. Разница между ними ровно в одном
    # методе (perform) и в двух ответах о себе.
    class FileTool
      def initialize(guard:, cwd: nil)
        @guard = guard
        @cwd = cwd
      end

      # Всегда возвращает строку: ошибка файловой системы — это тоже результат,
      # который модель должна прочитать и обработать, а не исключение,
      # роняющее цикл агента. Тот же контракт, что у Tools::Bash#call.
      def call(arguments)
        path = arguments["path"].to_s.strip
        return Messages::Tool::FILE_NO_PATH if path.empty?

        full = resolve(path)
        outside = outside_cwd?(full)

        case @guard.verdict_for(format(action, path: path), read_only: read_only?, outside_cwd: outside)
        when :cancelled then outside ? Messages::Tool::OUTSIDE_CWD_CANCELLED : Messages::CANCELLED
        when :planning then Messages::PLAN_REFUSED
        else perform(full, path, arguments)
        end
      rescue SystemCallError, IOError => e
        format(Messages::Tool::FILE_FAILED, message: e.message)
      end

      private

      # Тот же каталог, что уходит в chdir: у ProcessRunner. Разойдись они —
      # `ls` показывал бы один каталог, а read_file читал бы из другого,
      # и заметить это можно было бы только по содержимому файлов.
      def resolve(path) = File.expand_path(path, @cwd || Dir.pwd)

      # Денилист для файловой операции: у неё опасность — это путь, а путей
      # CommandGuard::DANGEROUS_PATTERNS не разбирает. Найдено оценочными
      # задачами: модель перепечатала длинный абсолютный путь с ошибкой,
      # записала файл в получившийся каталог, там же его перечитала, там же
      # проверила — и отчиталась успехом. Проверка внутри выдуманного дерева
      # сходится сама с собой, поэтому изнутри ошибка невидима; заметен только
      # сам выход за каталог, и спрашивать про него надо при любой политике.
      #
      # Чтение сюда не входит намеренно: заглянуть в чужой файл — обычное дело
      # (промпт агента, конфиг, соседний проект), и вопрос на каждый такой
      # read_file превратился бы в шум, за которым не видно записи.
      #
      # expand_path, а не realpath: у write_file файла ещё нет, и realpath
      # упал бы на нём Errno::ENOENT. Символьная ссылка мимо каталога этой
      # проверкой, стало быть, не ловится — песочницей она не является, как
      # и оба списка CommandGuard.
      def outside_cwd?(full)
        return false if read_only?

        base = File.expand_path(@cwd || Dir.pwd)
        full != base && !full.start_with?("#{base}#{File::SEPARATOR}")
      end

      # Читаем как UTF-8 и заменяем негодные байты на U+FFFD — на той же
      # границе и по той же причине, что ProcessRunner делает это с выводом
      # команд: испорченная строка иначе доезжает до сборки тела запроса и
      # роняет агента JSON::GeneratorError'ом (поймано живьём на `head -c
      # 30 /bin/ls`). Чинить это позже поздно — она успевает разойтись
      # по истории и журналу.
      def read(full) = File.read(full, encoding: "UTF-8").scrub("�")

      # Ошибки, которые называются отдельно от общего FILE_FAILED: их модель
      # должна не просто увидеть, а понять, что делать дальше.
      def missing(path) = format(Messages::Tool::FILE_MISSING, path: path)

      def directory_given(path) = format(Messages::Tool::FILE_IS_DIRECTORY, path: path)
    end
  end
end
