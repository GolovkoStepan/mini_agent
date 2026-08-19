# frozen_string_literal: true

module MiniAgent
  module Tools
    # Точечная правка: заменить один кусок текста другим.
    #
    # Главное здесь — не удобство, а то, что правка ЛИБО применяется целиком,
    # ЛИБО не применяется вовсе и об этом сказано вслух. `sed -i` и правка
    # через heredoc обе умеют сделать наполовину и вернуть код 0; модель после
    # такого докладывает об успехе, а в файле лежит то, чего никто не писал.
    #
    # Отсюда требование единственности: найденное дважды — это отказ, а не
    # выбор первого попавшегося. Первое попавшееся невозможно проверить по
    # результату, и ошибка вылезет через десяток ходов в чужом месте.
    class EditFile < FileTool
      NAME = "edit_file"

      SCHEMA = {
        "type" => "function",
        "function" => {
          "name" => NAME,
          "description" => "Replace one exact fragment of a file with another. " \
                           "`old_text` must appear exactly once: include the surrounding lines " \
                           "if it does not. Use this instead of `sed -i` for editing files.",
          "parameters" => {
            "type" => "object",
            "properties" => {
              "path" => {
                "type" => "string",
                "description" => "Path to the file, absolute or relative to the working directory."
              },
              "old_text" => {
                "type" => "string",
                "description" => "The exact text to replace, copied from the file, whitespace included."
              },
              "new_text" => {
                "type" => "string",
                "description" => "The replacement text. Empty string deletes the fragment."
              }
            },
            "required" => %w[path old_text new_text]
          }
        }
      }.freeze

      def name = NAME

      def schema = SCHEMA

      private

      def read_only? = false

      def action = "edit_file %<path>s"

      def perform(full, path, arguments)
        old_text = arguments["old_text"].to_s
        return Messages::Tool::EDIT_NO_OLD_TEXT if old_text.empty?
        return missing(path) unless File.exist?(full)
        return directory_given(path) if File.directory?(full)

        # Здесь, в отличие от чтения, файл берётся как есть, без scrub:
        # прочитанный с заменой негодных байтов на U+FFFD и записанный
        # обратно, он потерял бы их насовсем. Читать так можно — там ничего
        # не портится, — а править нельзя, поэтому недвоичность проверяется.
        content = File.read(full, encoding: "UTF-8")
        return format(Messages::Tool::FILE_NOT_TEXT, path: path) unless content.valid_encoding?

        replace(full, path, content, old_text, arguments["new_text"].to_s)
      end

      def replace(full, path, content, old_text, new_text)
        count = content.scan(old_text).size
        return format(Messages::Tool::EDIT_NOT_FOUND, path: path) if count.zero?
        if count > 1
          return format(Messages::Tool::EDIT_AMBIGUOUS, path: path,
                                                        count: Plural.with(count, *Messages::TIMES))
        end

        # sub с блоком, а не со строкой: в строке замены Ruby разбирает \1, \0
        # и \\ как обратные ссылки, и текст, где они встретились, записался бы
        # в файл искажённым. В коде это обычные знаки — регулярные выражения,
        # Windows-пути, экранирование в строках.
        File.write(full, content.sub(old_text) { new_text })
        format(Messages::Tool::EDIT_DONE, path: path,
                                          removed: Plural.with(old_text.lines.size, *Messages::LINES),
                                          added: Plural.with(new_text.lines.size, *Messages::LINES))
      end
    end
  end
end
