module ActionController
  class ControllerResolver
    def initialize
      @cache = Concurrent::Map.new
    end

    def call(name)
      @cache.compute_if_absent(name) do
        resolve(name)
      end
    end

    def clear
      @cache.clear
    end

    private
      def resolve(name)
        controller_param = name.underscore
        const_name = controller_param.camelize << "Controller"
        begin
          ActiveSupport::Dependencies.constantize(const_name)
        rescue NameError => error
          if error.missing_name == const_name || const_name.start_with?("#{error.missing_name}::")
            raise ActionDispatch::MissingController.new(error.message, error.name)
          else
            raise
          end
        end
      end
  end
end
