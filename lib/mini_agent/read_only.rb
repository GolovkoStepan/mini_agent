# frozen_string_literal: true

module MiniAgent
  # Ответ на один вопрос: эта команда заведомо только читает?
  #
  # Обратная сторона CommandGuard::DANGEROUS_PATTERNS. Тот перечисляет
  # заведомо плохое и всё остальное пропускает; здесь перечислено заведомо
  # безобидное, а всё остальное идёт на подтверждение. Ошибка денилиста —
  # пропустить разрушительное, ошибка этого списка — спросить лишний раз.
  # Второе дешевле, поэтому список намеренно короткий и растёт неохотно.
  #
  # ГРАНИЦЫ. Песочницей это тоже не является: разбирается строка, а не
  # синтаксическое дерево shell, и флаги команд не проверяются вовсе —
  # `git diff --output=файл` пишет файл и всё равно считается читающим.
  # Задача списка — сократить число незаметных записей, а не поставить
  # границу безопасности. Границу ставит только изоляция (см. README).
  module ReadOnly
    # Критерий включения: у команды нет режима записи, включаемого флагом.
    # Поэтому здесь нет `sort` (-o), `sed` (-i), `find` (-delete, -exec),
    # `tee`, `xargs` и `env` — последние три выполняют чужую команду,
    # то есть пускают мимо списка что угодно.
    COMMANDS = %w[
      ls pwd cat head tail wc nl tac rev
      file stat du df tree readlink realpath basename dirname
      grep egrep fgrep rg ag ack fd locate
      diff cmp
      echo printf
      date whoami id groups hostname uname uptime printenv
      which type ps
      jq xxd od strings
      cut tr column
      shasum md5 md5sum sha1sum sha256sum
    ].freeze

    # У git почти каждая подкоманда умеет писать, поэтому проверяется она,
    # а не сам git. Нет `branch` (-d удаляет), `tag`, `remote` и `config`:
    # все они читают в одной форме и пишут в другой, а форму мы не разбираем.
    GIT_SUBCOMMANDS = %w[status log diff show ls-files blame rev-parse describe shortlog].freeze

    # Конструкции, при которых разбор по словам перестаёт что-либо значить:
    # подстановка команды (`` ` ``, `$(`), подстановка процесса и любое
    # перенаправление. Ни одна из них не встречается в честном чтении,
    # поэтому проще отказать целиком, чем пытаться их разобрать.
    UNPARSEABLE = /[`<>]|\$\(/

    # Разделители команд. Строка режется по ним, и читающей считается только
    # та, у которой читают ВСЕ части: `ls | head` — да, `ls | tee файл` — нет.
    #
    # Резать наивно, не разбирая кавычек, здесь безопасно: разделитель внутри
    # кавычек даёт лишний обрывок вроде `b" файл`, чьё первое слово в список
    # не попадёт, — то есть ошибка всегда в сторону лишнего вопроса. Обратной
    # ошибки быть не может: настоящая команда начинается сразу за настоящим
    # разделителем, а тот всегда попадает в число мест разреза.
    SEPARATORS = /\|\||&&|[|;\n]/

    def self.command?(command)
      text = command.to_s
      return false if text.strip.empty?
      return false if UNPARSEABLE.match?(text)

      parts = text.split(SEPARATORS).reject { |part| part.strip.empty? }
      return false if parts.empty?

      parts.all? { |part| reader?(part) }
    end

    # Одиночный `&` проверяется по всей части, а не по первому слову:
    # `&&` к этому месту уже съеден разрезом, и оставшийся амперсанд —
    # это фоновый запуск, где вторая команда стоит после первой
    # (`ls & rm -rf /`), а первое слово выглядит совершенно невинно.
    def self.reader?(part)
      return false if part.include?("&")

      words = part.split
      return false if words.empty?
      return true if words.first == "git" && GIT_SUBCOMMANDS.include?(words[1])

      COMMANDS.include?(words.first)
    end
    private_class_method :reader?
  end
end
