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

    attr_reader :project_context, :transcript

    def build
      Conversation.new(project_context: @project_context, transcript: @transcript)
    end
  end
end
