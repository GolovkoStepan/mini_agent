# frozen_string_literal: true

module MiniAgent
  module Tools
    # Чтение файла целиком.
    #
    # Номеров строк не добавляем, хотя они напрашиваются: edit_file ищет
    # текст дословно, и модель, увидевшая файл с номерами, вставила бы их
    # в old_text — правка не нашлась бы, а причина осталась бы невидимой.
    # Одна форма текста на чтение и на правку.
    class ReadFile < FileTool
      NAME = "read_file"

      # Потолок на то, что вообще берётся в память. Не то же самое, что
      # усечение результата в ToolCallRunner: то бережёт контекстное окно
      # и режет уже прочитанное, а здесь речь о том, чтобы не втянуть
      # гигабайтный образ целиком ради первых двух тысяч знаков.
      MAX_BYTES = 1 << 20

      SCHEMA = {
        "type" => "function",
        "function" => {
          "name" => NAME,
          "description" => "Read a text file and return its contents. " \
                           "Prefer this over `cat`: the result is the file itself, with no shell in between.",
          "parameters" => {
            "type" => "object",
            "properties" => {
              "path" => {
                "type" => "string",
                "description" => "Path to the file, absolute or relative to the working directory."
              }
            },
            "required" => ["path"]
          }
        }
      }.freeze

      def name = NAME

      def schema = SCHEMA

      private

      def read_only? = true

      def action = "read_file %<path>s"

      def perform(full, path, _arguments)
        return missing(path) unless File.exist?(full)
        return directory_given(path) if File.directory?(full)

        size = File.size(full)
        return format(Messages::Tool::FILE_TOO_BIG, path: path, size: size, limit: MAX_BYTES) if size > MAX_BYTES

        content = read(full)
        # Пустой файл существует, и сказать об этом надо словами: пустая
        # строка в ответе неотличима от «инструмент ничего не вернул», и
        # модель принимается искать несуществующую ошибку.
        content.empty? ? format(Messages::Tool::FILE_EMPTY, path: path) : content
      end
    end
  end
end
