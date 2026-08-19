# frozen_string_literal: true

module MiniAgent
  module Tools
    # Запись файла целиком: создание нового или полная замена существующего.
    class WriteFile < FileTool
      NAME = "write_file"

      SCHEMA = {
        "type" => "function",
        "function" => {
          "name" => NAME,
          "description" => "Write text to a file, creating it or replacing it entirely. " \
                           "Always use this instead of `cat > file` or a heredoc: the text goes " \
                           "straight to disk, so quoting and delimiters cannot corrupt it.",
          "parameters" => {
            "type" => "object",
            "properties" => {
              "path" => {
                "type" => "string",
                "description" => "Path to the file, absolute or relative to the working directory."
              },
              "content" => {
                "type" => "string",
                "description" => "The full contents of the file. The previous contents are lost."
              }
            },
            "required" => %w[path content]
          }
        }
      }.freeze

      def name = NAME

      def schema = SCHEMA

      private

      def read_only? = false

      def action = "write_file %<path>s"

      def perform(full, path, arguments)
        # Каталог не создаётся сам: молчаливый mkdir_p превращает опечатку
        # в пути в новое дерево каталогов, и модель докладывает об успехе,
        # записав файл не туда. Пусть лучше не найдётся — это видно сразу.
        parent = File.dirname(full)
        return format(Messages::Tool::DIR_MISSING, path: File.dirname(path)) unless File.directory?(parent)
        return directory_given(path) if File.directory?(full)

        existed = File.exist?(full)
        content = arguments["content"].to_s
        File.write(full, content)
        report(path, content, existed)
      end

      # Отчёт называет и размер, и то, был ли файл до этого. Числа здесь не
      # для красоты: они единственный способ для модели заметить, что вместо
      # файла на 200 строк записалось 3, — а «перезаписан» против «создан»
      # не даёт выдать замену чужого файла за создание своего.
      def report(path, content, existed)
        text = existed ? Messages::Tool::FILE_REPLACED : Messages::Tool::FILE_CREATED
        format(text, path: path,
                     lines: Plural.with(content.lines.size, *Messages::LINES),
                     chars: Plural.with(content.length, *Messages::CHARS))
      end
    end
  end
end
