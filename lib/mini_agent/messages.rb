# frozen_string_literal: true

module MiniAgent
  # Все тексты, которые видит пользователь, собраны здесь, чтобы не быть
  # размазанными по классам. Форматные строки применяются через format/%.
  module Messages
    SYSTEM_PROMPT = <<~PROMPT
      You are a coding agent. Your job is to help the user with programming tasks.

      You have access to ONE tool: `bash` — which executes shell commands and returns stdout/stderr.

      Workflow:
      1. Plan what needs to be done.
      2. Use `bash` to read files, run commands, write code, etc.
      3. After gathering enough information or completing the task, give your final answer in natural language.
      4. To finish, reply with a regular message (no tool call).

      Be concise. Explain what you're doing before each command.
    PROMPT

    # Сообщение, которое подставляется в историю при достижении лимита ходов.
    STOP_MAX_TURNS = "Stop: maximum turns reached. Summarize current progress."

    # --- Безопасность команд ---
    DANGEROUS_COMMAND = "⚠️  Опасная команда: %<command>s"
    DANGEROUS_COMMAND_ALLOWED = "⚠️  Потенциально опасная команда (ALLOW_UNSAFE=true): %<command>s"
    CONFIRM_PROMPT = "Продолжить выполнение? (y/N): "
    CANCELLED = "⛔ Выполнение отменено пользователем."

    # --- Выполнение команд ---
    EMPTY_COMMAND = "❌ Ошибка: пустая команда."
    EXECUTION_TIMEOUT = "⏱️ Ошибка: превышено время ожидания (%<timeout>s сек)."
    EXECUTION_FAILED = "❌ Ошибка выполнения: %<message>s"
    EXIT_CODE = "Код выхода: %<code>d"
    STDERR_SECTION = "\nSTDERR:\n%<stderr>s"
    TRUNCATED_SUFFIX = "\n... (truncated)"

    # --- Инструменты ---
    UNKNOWN_TOOL = "Ошибка: неизвестный инструмент '%<name>s'"
    TOOL_FAILED = "Ошибка вызова инструмента %<name>s: %<message>s"
    ARGS_PARSE_ERROR = "Ошибка разбора аргументов: %<message>s. Получено: %<raw>s"

    # --- Взаимодействие с LLM ---
    THINKING = "🧠 Думаю... "
    HTTP_ERROR = "⚠️  HTTP %<code>s (попытка %<attempt>d)"
    INVALID_CHOICES = "⚠️  Некорректный ответ: поле choices отсутствует или пусто"
    EMPTY_MESSAGE = "⚠️  Пустой message в ответе"
    LLM_FAILED = "Не удалось получить ответ от LLM после %<count>d попыток: %<error>s"
    NETWORK_ERROR = "Сетевая ошибка: %<message>s"
    UNKNOWN_ERROR = "Неизвестная ошибка: %<message>s"
    INVALID_JSON = "Некорректный JSON в ответе: %<message>s"
    NOT_CONNECTED = "HTTP-соединение не установлено: вызовите LLMClient#start с блоком."

    # --- Цикл агента ---
    TURN = "Ход %<number>d"
    ASSISTANT = "Ассистент:"
    SUMMARY = "Итог:"
    TOOL_CALL = "Вызов инструмента: "
    COMMAND_LABEL = "   📝 Команда: %<command>s"
    ARGS_LABEL = "   Аргументы: %<args>s"
    RESULT_LABEL = "   📤 Результат:"
    OUTPUT_HEADER = "   ┌─ Вывод ─────────────"
    OUTPUT_HEADER_TRUNCATED = "   ┌─ Вывод (обрезано) ─"
    OUTPUT_FOOTER = "   └──────────────────────"
    OUTPUT_ELLIPSIS = "   │ ... (показаны первые %<shown>d строк из %<total>d) ..."
    LLM_CONNECTION_FAILED = "❌ Ошибка связи с LLM: %<message>s"
    EMPTY_RESPONSE = "⚠️  Модель вернула пустой ответ без вызовов инструментов. Завершение."
    AGENT_DONE = "Агент успешно завершил работу!"
    MAX_TURNS_REACHED = "Достигнуто максимальное число ходов (%<count>d). Остановка."
    SUMMARY_FAILED = "Не удалось получить итоговый ответ: %<message>s"

    # --- CLI ---
    BANNER = "Использование: mini_agent [опции] [задача]"
    OPT_INTERACTIVE = "Интерактивный режим"
    OPT_MAX_TURNS = "Максимальное число ходов"
    OPT_RETRY_COUNT = "Число попыток при ошибке сети"
    OPT_RETRY_DELAY = "Задержка между попытками (сек)"
    OPT_ALLOW_UNSAFE = "Разрешить опасные команды без подтверждения"
    OPT_BASE_URL = "Базовый URL LLM-сервера"
    OPT_MODEL = "Имя модели"
    OPT_HELP = "Показать справку"
    OPT_VERSION = "Показать версию"
    INTERACTIVE_HEADER = "🚀 Coding Agent (интерактивный режим)"
    INTERACTIVE_HINT = "Введите задачу или 'exit' для выхода."
    GOODBYE = "До свидания!"
    INTERRUPTED = "\n👋 Выход по Ctrl+C"
    NO_TASK_HEADER = "🚀 Coding Agent v%<version>s"
    NO_TASK_HINT = "Не указана задача. Используйте -i для интерактивного режима"
    NO_TASK_HINT2 = "или передайте задачу как аргумент: mini_agent <задача>"
  end
end
