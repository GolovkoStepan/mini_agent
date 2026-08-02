# frozen_string_literal: true

require_relative "mini_agent/version"
require_relative "mini_agent/messages"
require_relative "mini_agent/color"
require_relative "mini_agent/config"
require_relative "mini_agent/conversation"
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
require_relative "mini_agent/command_guard"
require_relative "mini_agent/tools/bash"
require_relative "mini_agent/tool_registry"
require_relative "mini_agent/ui"
require_relative "mini_agent/error_response"
require_relative "mini_agent/models_request"
require_relative "mini_agent/llm_client"
require_relative "mini_agent/agent"
require_relative "mini_agent/models_command"
require_relative "mini_agent/cli"
