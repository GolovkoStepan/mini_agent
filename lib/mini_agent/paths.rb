# frozen_string_literal: true

module MiniAgent
  # Пути из настроек: развернуть и убедиться, что каталог существует.
  #
  # Выделено из Config восьмым срабатыванием Metrics/ClassLength, и порог опять
  # указал верно: у Config задача — свести опции, окружение и умолчания в одно
  # значение, здесь же начинается файловая система. Проверка стоит до запуска
  # намеренно: опечатка в --cwd иначе всплывает посреди работы невнятной
  # ошибкой от Open3, уже после запроса к модели, за который заплачено.
  module Paths
    module_function

    # Каталог, в котором агент выполняет команды (--cwd).
    def directory(value)
      path = expand(value)
      return nil if path.nil?
      raise ConfigError, format(Messages::CWD_NOT_FOUND, path: path) unless File.directory?(path)

      path
    end

    # Файл журнала (--log). Существования самого файла не требуем — его создаст
    # Transcript, — а вот каталог обязан быть: писать иначе будет некуда.
    def file(value)
      path = expand(value)
      return nil if path.nil?

      dir = File.dirname(path)
      raise ConfigError, format(Messages::LOG_DIR_NOT_FOUND, path: dir) unless File.directory?(dir)

      path
    end

    # Развёрнутый путь — чтобы `.` и `~/проект` попадали в вывод в понятном
    # человеку виде. Разворачивается относительно каталога запуска, а не --cwd,
    # и для журнала это существенно: `--log session.jsonl` человек пишет там,
    # где стоит сам, и искать файл пойдёт туда же.
    def expand(value)
      return nil if value.nil? || value.to_s.empty?

      File.expand_path(value.to_s)
    end
  end
end
