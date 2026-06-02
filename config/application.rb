require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TestDeepgram2
  class Application < Rails::Application
    # Load .env in development so we don't have to export variables manually.
    # Must run before any initializer that reads ENV.
    config.before_configuration do
      if Rails.env.development?
        env_file = Rails.root.join(".env")
        if env_file.exist?
          env_file.each_line do |line|
            next if line.strip.empty? || line.start_with?("#")
            key, value = line.chomp.split("=", 2)
            ENV[key] ||= value
          end
        end
      end
    end

    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
