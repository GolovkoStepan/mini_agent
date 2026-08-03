# frozen_string_literal: true

module MiniAgent
  # Из чего собирается история диалога: описание проекта и журнал.
  #
  # Существует ради одной точки сборки. Conversation заводится в двух местах —
  # в Agent при первой задаче и в Repl по команде /clear, — и каждое новое
  # поле приходилось добавлять в оба. Описание проекта этот путь уже прошло:
  # после /clear агент забывал про AGENTS.md до конца сессии, и починка была
  # именно в том, чтобы протащить его во второе место. Журнал повторил бы
  # ту же ошибку, причём молча — запись просто оборвалась бы на первой очистке.
  class History
    def initialize(project_context: nil, transcript: nil)
      @project_context = project_context
      @transcript = transcript
    end

    attr_reader :transcript

    # Описание проекта записываемо ради /init: команда создаёт AGENTS.md
    # посреди сессии, а History собрана на старте и о новом файле не знает.
    # Применяется оно при следующей сборке — то есть по /clear или /compact;
    # переписывать текущую историю на месте значило бы её выбросить.
    attr_accessor :project_context

    def build
      Conversation.new(project_context: @project_context, transcript: @transcript)
    end
  end
end
