# frozen_string_literal: true

module MiniAgent
  # Все тексты, которые видит пользователь, собраны здесь, чтобы не быть
  # размазанными по классам. Форматные строки применяются через format/%.
  #
  # Тексты разделены на два слоя, и это разделение существенно:
  #
  #   Messages::Tool — строки, уходящие РЕЗУЛЬТАТОМ ИНСТРУМЕНТА В МОДЕЛЬ.
  #   Это не интерфейс: оформление здесь модель читает как часть данных.
  #
  #   Остальные константы — вывод В ТЕРМИНАЛ, его оформление свободно
  #   меняется вместе с UI и на поведение модели не влияет.
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

    # Строки, которые получает МОДЕЛЬ, а не человек: результат инструмента и
    # сообщения об ошибках его вызова. Менять их — значит менять вход модели,
    # поэтому оформление здесь живёт отдельно от оформления терминала.
    module Tool
      EMPTY_COMMAND = "❌ Ошибка: пустая команда."
      EXECUTION_TIMEOUT = "⏱️ Ошибка: превышено время ожидания (%<timeout>s сек)."
      EXECUTION_FAILED = "❌ Ошибка выполнения: %<message>s"
      CANCELLED = "⛔ Выполнение отменено пользователем."
      EXIT_CODE = "Код выхода: %<code>d"
      STDERR_SECTION = "\nSTDERR:\n%<stderr>s"
      TRUNCATED_SUFFIX = "\n... (truncated)"
      UNKNOWN_TOOL = "Ошибка: неизвестный инструмент '%<name>s'"
      TOOL_FAILED = "Ошибка вызова инструмента %<name>s: %<message>s"
      ARGS_PARSE_ERROR = "Ошибка разбора аргументов: %<message>s. Получено: %<raw>s"
    end

    # Псевдонимы: слой разделён, но обращаться можно по-прежнему коротко.
    EMPTY_COMMAND = Tool::EMPTY_COMMAND
    EXECUTION_TIMEOUT = Tool::EXECUTION_TIMEOUT
    EXECUTION_FAILED = Tool::EXECUTION_FAILED
    CANCELLED = Tool::CANCELLED
    EXIT_CODE = Tool::EXIT_CODE
    STDERR_SECTION = Tool::STDERR_SECTION
    TRUNCATED_SUFFIX = Tool::TRUNCATED_SUFFIX
    UNKNOWN_TOOL = Tool::UNKNOWN_TOOL
    TOOL_FAILED = Tool::TOOL_FAILED
    ARGS_PARSE_ERROR = Tool::ARGS_PARSE_ERROR

    # Разбор строки кода выхода обратно из результата инструмента: UI
    # показывает код отдельной пометкой и только при ошибке. Образец стоит
    # рядом с самим форматом намеренно — иначе правка одного молча ломает
    # другой, и пометка тихо перестанет появляться.
    EXIT_CODE_PATTERN = /\AКод выхода: (\d+)\n/

    # --- Безопасность команд ---
    DANGEROUS_COMMAND = "Опасная команда: %<command>s"
    DANGEROUS_COMMAND_ALLOWED = "Потенциально опасная команда (ALLOW_UNSAFE=true): %<command>s"
    CONFIRM_PROMPT = "Продолжить выполнение? (y/N): "

    # --- Взаимодействие с LLM ---
    THINKING = "Думаю…"
    HTTP_ERROR = "HTTP %<code>s (попытка %<attempt>d)"
    # Ошибка запроса, а не сервера: повторять нечего, сообщаем без номера
    # попытки — его наличие подразумевало бы, что будут следующие.
    HTTP_FATAL = "HTTP %<code>s — запрос отклонён, повтор не поможет"
    INVALID_CHOICES = "Некорректный ответ: поле choices отсутствует или пусто"
    EMPTY_MESSAGE = "Пустой message в ответе"
    LLM_FAILED = "Не удалось получить ответ от LLM после %<count>d попыток: %<error>s"
    NETWORK_ERROR = "Сетевая ошибка: %<message>s"
    UNKNOWN_ERROR = "Неизвестная ошибка: %<message>s"
    INVALID_JSON = "Некорректный JSON в ответе: %<message>s"
    NOT_CONNECTED = "HTTP-соединение не установлено: вызовите LLMClient#start с блоком."

    # --- Цикл агента ---
    # Номер хода живёт только в строке спиннера и исчезает вместе с ней:
    # это внутренняя бухгалтерия агента, в логе работы она не нужна.
    TURN = "ход %<number>d/%<total>d"
    EXIT_CODE_LABEL = "код выхода %<code>d"
    OUTPUT_ELLIPSIS = "… +%<count>d строк"
    LLM_CONNECTION_FAILED = "Ошибка связи с LLM: %<message>s"
    # Соединение не открылось вообще — агент не стартовал. Показываем адрес
    # и способ его сменить: значение по умолчанию указывает на чужой сервер,
    # и без подсказки непонятно, откуда взялся этот хост.
    CONNECT_FAILED = "Не удалось подключиться к LLM: %<url>s"
    CONNECT_REASON = "  %<message>s"
    CONNECT_HINT = "  Проверьте, что сервер запущен, либо укажите другой адрес: --base-url URL или LLM_BASE_URL."
    # Отдельный случай: адрес разобрать не удалось. Совет «проверьте, что
    # сервер запущен» здесь был бы ложным следом.
    INVALID_URL = "Некорректный адрес LLM: %<url>s"
    INVALID_URL_HINT = "  Ожидается вид http://хост:порт/v1"
    EMPTY_RESPONSE = "Модель вернула пустой ответ без вызовов инструментов. Завершение."
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
    OPT_LIST_MODELS = "Показать модели, загруженные на сервере"
    OPT_HELP = "Показать справку"
    OPT_VERSION = "Показать версию"
    INTERACTIVE_HEADER = "Mini Agent (интерактивный режим)"
    INTERACTIVE_HINT = "Введите задачу или 'exit' для выхода."
    PROMPT_SIGN = "> "
    GOODBYE = "До свидания!"
    INTERRUPTED = "\nВыход по Ctrl+C"
    # --- Список моделей ---
    MODELS_HEADER = "Модели на %<url>s:"
    # Звёздочка помечает выбранную модель: ради этого сравнения команду
    # обычно и запускают.
    MODEL_SELECTED = "  * %<name>s"
    MODEL_PLAIN = "    %<name>s"
    NO_MODELS = "На %<url>s не загружено ни одной модели."

    NO_TASK_HEADER = "Mini Agent v%<version>s"
    NO_TASK_HINT = "Не указана задача. Используйте -i для интерактивного режима"
    NO_TASK_HINT2 = "или передайте задачу как аргумент: mini_agent <задача>"
  end
end
