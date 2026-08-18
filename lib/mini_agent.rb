# frozen_string_literal: true

require_relative "mini_agent/version"
require_relative "mini_agent/plural"
require_relative "mini_agent/messages"
require_relative "mini_agent/color"
require_relative "mini_agent/paths"
require_relative "mini_agent/config"
require_relative "mini_agent/usage"
require_relative "mini_agent/transcript"
require_relative "mini_agent/conversation"
require_relative "mini_agent/history"
require_relative "mini_agent/window"
require_relative "mini_agent/context_report"
require_relative "mini_agent/project_context"

module MiniAgent
  class Error < StandardError; end

  # Команда не уложилась в отведённое время и была принудительно убита.
  class TimeoutError < Error; end

  # Не удалось получить корректный ответ от LLM после всех попыток.
  class LLMError < Error; end

  # Настройки заданы неверно: например, указан несуществующий каталог.
  # Проверяется до запуска, чтобы ошибка не всплыла посреди работы.
  class ConfigError < Error; end
end

require_relative "mini_agent/process_runner"
require_relative "mini_agent/prompt"
require_relative "mini_agent/read_only"
require_relative "mini_agent/plan_mode"
require_relative "mini_agent/command_guard"
require_relative "mini_agent/tools/bash"
require_relative "mini_agent/tool_registry"
require_relative "mini_agent/tool_call_runner"
require_relative "mini_agent/context_view"
require_relative "mini_agent/spinner"
require_relative "mini_agent/ui"
require_relative "mini_agent/chat_payload"
require_relative "mini_agent/error_response"
require_relative "mini_agent/chat_response"
require_relative "mini_agent/stream_parser"
require_relative "mini_agent/stream_request"
require_relative "mini_agent/models_request"
require_relative "mini_agent/window_probe"
require_relative "mini_agent/llm_client"
require_relative "mini_agent/compactor"
require_relative "mini_agent/auto_compactor"
require_relative "mini_agent/initializer"
require_relative "mini_agent/planner"
require_relative "mini_agent/agent"
require_relative "mini_agent/agent_builder"
require_relative "mini_agent/line_reader"
require_relative "mini_agent/slash_commands"
require_relative "mini_agent/repl"
require_relative "mini_agent/models_command"
require_relative "mini_agent/cli"
