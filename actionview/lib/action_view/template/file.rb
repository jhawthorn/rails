module ActionView #:nodoc:
  # = Action View File Template
  class Template #:nodoc:
    class File #:nodoc:
      attr_accessor :type

      def initialize(filename)
        @filename = filename.to_s
        extname = ::File.extname(filename).delete(".")
        @format = Template::Types[extname]&.symbol || :text
      end

      def identifier
        @filename
      end

      def render(*args)
        ::File.read(@filename)
      end

      def format
        @format
      end

      def formats; Array(format); end
      deprecate :formats
    end
  end
end
